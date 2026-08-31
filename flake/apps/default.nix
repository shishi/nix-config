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
      # 固定中の nixos-anywhere 1.13.0 は sshArgs の先頭で host key 検証を無効化する
      # (UserKnownHostsFile=/dev/null, StrictHostKeyChecking=no)。OpenSSH は同一
      # option の初出値を採用するため、後続の --ssh-option では上書きできない。
      # この 2 項目だけを除去し、検証の決定権を呼び出し側へ返す
      # (dns-osaka-1 wrapper は known_hosts 固定 + yes を明示、jupiter は ssh 既定)。
      # ホスト間で共有するのはこの修正だけで、workflow は共有しない。
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
      # 引数 secrets / install は生成する 2 app に 1:1 対応し、ホストが決められるのは
      # 各 app の runtimeInputs(script が PATH に持つコマンド群)だけ。
      # 汎用 dispatcher は作らない。
      mkProvisioningApps =
        host:
        { secrets, install }:
        {
          "${host}-secrets" = {
            type = "app";
            program = "${
              pkgs.writeShellApplication {
                name = "${host}-secrets";
                runtimeInputs = secrets.runtimeInputs;
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
                runtimeInputs = install.runtimeInputs;
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
