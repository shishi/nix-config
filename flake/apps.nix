{ self, ... }:
{
  perSystem =
    {
      pkgs,
      self',
      inputs',
      ...
    }:
    let
      check-env = pkgs.writeShellApplication {
        name = "check-env";
        runtimeInputs = with pkgs; [
          coreutils
          gnugrep
          iproute2
          getent
          glibc.bin
        ];
        text = builtins.readFile ../scripts/check-env.sh;
      };
      mkScriptApp = name: script: {
        type = "app";
        program = "${pkgs.writeShellScript name ''
          exec ${pkgs.bash}/bin/bash ${script} "$@"
        ''}";
      };
      verifiedNixosAnywhere = inputs'.nixos-anywhere.packages.default.overrideAttrs (old: {
        postPatch = (old.postPatch or "") + ''
          substituteInPlace src/nixos-anywhere.sh \
            --replace-fail \
              'declare -a sshArgs=("-o" "IdentitiesOnly=yes" "-i" "$tempDir/nixos-anywhere" "-o" "UserKnownHostsFile=/dev/null" "-o" "StrictHostKeyChecking=no")' \
              'declare -a sshArgs=("-o" "IdentitiesOnly=yes" "-i" "$tempDir/nixos-anywhere")'
        '';
      });

      # ホスト非依存の app。どのマシンでも同じ意味を持つ。
      genericApps = {
        # standalone の公認適用経路(一本化)。
        # 契約クリティカル check-env → 直接 activation → 成功記録。
        # 素の `nh home switch` はガードを迂回するため使わない
        switch = {
          type = "app";
          program = "${pkgs.writeShellScript "switch" ''
            set -euo pipefail
            if [ "''${1:-}" != "--force" ]; then
              ${check-env}/bin/check-env --critical
            fi
            ${self.homeConfigurations."shishi".activationPackage}/activate
            state_dir="$HOME/.local/state/nix-config"
            mkdir -p "$state_dir"
            printf '%s %s\n' "$(hostname)" "${
              self.rev or self.dirtyRev or "unknown"
            }" > "$state_dir/last-applied"
            echo "switch: applied and recorded"
          ''}";
        };

        check-env = {
          type = "app";
          program = "${check-env}/bin/check-env";
        };

        # rust-bootstrap: HM 側と同一実体(home/core/rust.nix と同じ script + tools 既定値)
        rust-bootstrap = {
          type = "app";
          program = "${self.homeConfigurations."shishi".config.home.path}/bin/rust-bootstrap";
        };

        # 新規マシンの初期設営(clone → dotfiles setup → nix 適用 → 鍵の案内)。
        # public repo なので鍵の無いマシンからも直接叩ける:
        #   nix run github:shishi/nix-config#bootstrap
        bootstrap = {
          type = "app";
          program = "${
            pkgs.writeShellApplication {
              name = "bootstrap";
              runtimeInputs = with pkgs; [
                git
                openssh
                coreutils
                gnugrep
                bash
              ];
              text = builtins.readFile ../scripts/bootstrap.sh;
            }
          }/bin/bootstrap";
        };

        update = {
          type = "app";
          program = "${
            pkgs.writeShellApplication {
              name = "update";
              runtimeInputs = with pkgs; [
                git
                nix
                jq
                nix-update
                nix-output-monitor
              ];
              text = builtins.readFile ../scripts/update.sh;
            }
          }/bin/update";
        };
        default = self'.apps.update;

        setup-sudo-nopasswd = mkScriptApp "setup-sudo-nopasswd" ../scripts/setup-sudo-nopasswd.sh;
        setup-trusted-user = mkScriptApp "setup-trusted-user" ../scripts/setup-nix-trusted-user.sh;
        install-system-packages = mkScriptApp "install-system-packages" ../scripts/install-system-packages.sh;
      };

      # provision 対象ホストの対の契約: 各ホストは <host>-secrets / <host>-install を
      # この名前で公開し、workflow 本体は scripts/<host>-secrets.sh /
      # scripts/<host>-install.sh が所有する(app 名と script パスはホスト名から導出)。
      # ホストごとのデータは runtimeInputs だけ。汎用 dispatcher は作らない(.handoff.md)。
      # nixosConfigurations の全ホストが対象ではない(synth-* は eval 専用、
      # nixos-wsl は import 導入)ため、対象は下の呼び出しで明示的に宣言する。
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
                text = builtins.readFile (../scripts + "/${host}-secrets.sh");
              }
            }/bin/${host}-secrets";
          };
          # インストーラの pin(リハーサルと本番を同一 rev に。flake input 版を使用)。
          # bootstrap.yaml を tmpfs で復号し、phase ごとに必要な秘密だけを配送する。
          "${host}-install" = {
            type = "app";
            program = "${
              pkgs.writeShellApplication {
                name = "${host}-install";
                runtimeInputs = installInputs;
                text = ''
                  export NIXOS_ANYWHERE_BIN=${verifiedNixosAnywhere}/bin/nixos-anywhere
                  ${builtins.readFile (../scripts + "/${host}-install.sh")}
                '';
              }
            }/bin/${host}-install";
          };
        };

      hostApps =
        mkProvisioningApps "jupiter" {
          secretsInputs = with pkgs; [
            age
            coreutils
            diffutils
            findutils
            git
            gnugrep
            gnupg
            jq
            openssh
            sops
            util-linux
          ];
          installInputs = with pkgs; [
            age
            coreutils
            findutils
            git
            gnugrep
            gnupg
            jq
            openssh
            sops
            util-linux
            whois
          ];
        }
        // mkProvisioningApps "dns-osaka-1" {
          secretsInputs = with pkgs; [
            age
            coreutils
            findutils
            git
            jq
            sops
            util-linux
          ];
          installInputs = with pkgs; [
            age
            coreutils
            findutils
            git
            jq
            sops
            util-linux
          ];
        };
    in
    {
      apps = genericApps // hostApps;
    };
}
