# ホスト非依存の app。どのマシンでも同じ意味を持つ。
# provision 対象ホストの対(<host>-secrets / <host>-install)は ./default.nix。
{ self, ... }:
{
  perSystem =
    { pkgs, self', ... }:
    let
      check-env = pkgs.writeShellApplication {
        name = "check-env";
        runtimeInputs = with pkgs; [
          # fish 不在時の resolve() fallback が bash -lc を実行する
          bash
          coreutils
          gnugrep
          iproute2
          getent
          glibc.bin
        ];
        text = builtins.readFile ../../scripts/check-env.sh;
      };
      # sudo / apt / systemctl などホスト側 system tool を駆動する script 用。
      # 依存は意図的に固定しない(nixpkgs の sudo は setuid を持たず動かない)。
      mkScriptApp = name: script: {
        type = "app";
        program = "${pkgs.writeShellScript name ''
          exec ${pkgs.bash}/bin/bash ${script} "$@"
        ''}";
      };
    in
    {
      apps = {
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
              text = builtins.readFile ../../scripts/bootstrap.sh;
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
                nix-update
              ];
              text = builtins.readFile ../../scripts/update.sh;
            }
          }/bin/update";
        };
        default = self'.apps.update;

        setup-sudo-nopasswd = mkScriptApp "setup-sudo-nopasswd" ../../scripts/setup-sudo-nopasswd.sh;
        setup-trusted-user = mkScriptApp "setup-trusted-user" ../../scripts/setup-nix-trusted-user.sh;
        install-system-packages = mkScriptApp "install-system-packages" ../../scripts/install-system-packages.sh;
      };
    };
}
