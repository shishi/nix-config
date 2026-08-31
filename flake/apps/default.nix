# flake app の集約。
# - 汎用 app: ./generic.nix(flake-parts module)
# - provision 対象ホストの対: このファイルが <host>.nix のデータから組み立てる
{ ... }:
{
  imports = [ ./generic.nix ];

  perSystem =
    { pkgs, inputs', ... }:
    let
      # インストーラの pin(リハーサルと本番を同一 rev に。flake input 版を使用)。
      # 固定中の nixos-anywhere 1.13.0 は host key 検証を無効化する SSH option を
      # 先行指定するため上流 script から除去し、各 host wrapper が渡す検証を有効にする。
      # ホスト間で共有するのはこの修正だけで、workflow は共有しない(.handoff.md)。
      verifiedNixosAnywhere = inputs'.nixos-anywhere.packages.default.overrideAttrs (old: {
        postPatch = (old.postPatch or "") + ''
          substituteInPlace src/nixos-anywhere.sh \
            --replace-fail \
              'declare -a sshArgs=("-o" "IdentitiesOnly=yes" "-i" "$tempDir/nixos-anywhere" "-o" "UserKnownHostsFile=/dev/null" "-o" "StrictHostKeyChecking=no")' \
              'declare -a sshArgs=("-o" "IdentitiesOnly=yes" "-i" "$tempDir/nixos-anywhere")'
        '';
      });

      # provision 対象ホストの対の契約: 各ホストは <host>-secrets / <host>-install を
      # この名前で公開し、workflow 本体は scripts/<host>-secrets.sh /
      # scripts/<host>-install.sh が所有する(app 名と script パスはホスト名から導出)。
      # ホストごとのデータは runtimeInputs だけ。汎用 dispatcher は作らない。
      mkProvisioningApps =
        host:
        { secretsInputs, installInputs }:
        {
          "${host}-secrets" = {
            type = "app";
            program = "${
              pkgs.writeShellApplication {
                name = "${host}-secrets";
                runtimeInputs = secretsInputs;
                text = builtins.readFile (../../scripts + "/${host}-secrets.sh");
              }
            }/bin/${host}-secrets";
          };
          # bootstrap.yaml を tmpfs で復号し、phase ごとに必要な秘密だけを配送する。
          "${host}-install" = {
            type = "app";
            program = "${
              pkgs.writeShellApplication {
                name = "${host}-install";
                runtimeInputs = installInputs;
                text = ''
                  export NIXOS_ANYWHERE_BIN=${verifiedNixosAnywhere}/bin/nixos-anywhere
                  ${builtins.readFile (../../scripts + "/${host}-install.sh")}
                '';
              }
            }/bin/${host}-install";
          };
        };

      # provision 対象ホストの明示的な宣言(ホスト追加は <host>.nix + この 1 行)。
      # nixosConfigurations の全ホストが対象ではない(synth-* は eval 専用、
      # nixos-wsl は import 導入)。
      provisionedHosts = {
        jupiter = import ./jupiter.nix { inherit pkgs; };
        dns-osaka-1 = import ./dns-osaka-1.nix { inherit pkgs; };
      };
    in
    {
      apps = pkgs.lib.concatMapAttrs mkProvisioningApps provisionedHosts;
    };
}
