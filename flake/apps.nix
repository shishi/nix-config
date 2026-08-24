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
      # secrets/ の検査。nixos-anywhere の前に必ず走らせる。
      check-install-secrets = pkgs.writeShellApplication {
        name = "check-install-secrets";
        runtimeInputs = with pkgs; [
          coreutils
          gnugrep
          gnused
        ];
        text = builtins.readFile ../scripts/check-install-secrets.sh;
      };
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

        # インストーラの pin(リハーサルと本番を同一 rev に。flake input 版を使用)。
        #
        # **素の nixos-anywhere は公認経路にしない。** secrets/ の検査を先に走らせる
        # ラッパ経由にする。README に「これを置け」と書くだけでは、読まないまま
        # 実行できてしまい、欠けたことに気づくのは初回起動後になる
        # (パスワードハッシュが無いと shadow が `!` になり、autoLogin で上がった
        # セッションのロックも RDP も通らない)。実行の瞬間に止める。
        nixos-anywhere = {
          type = "app";
          program = "${pkgs.writeShellScript "nixos-anywhere-checked" ''
            set -euo pipefail
            ${check-install-secrets}/bin/check-install-secrets
            exec ${inputs'.nixos-anywhere.packages.default}/bin/nixos-anywhere "$@"
          ''}";
        };

        # 検査だけを単独で回したいとき
        check-install-secrets = {
          type = "app";
          program = "${check-install-secrets}/bin/check-install-secrets";
        };

        setup-sudo-nopasswd = mkScriptApp "setup-sudo-nopasswd" ../scripts/setup-sudo-nopasswd.sh;
        setup-trusted-user = mkScriptApp "setup-trusted-user" ../scripts/setup-nix-trusted-user.sh;
        install-system-packages = mkScriptApp "install-system-packages" ../scripts/install-system-packages.sh;
      };
    };
}
