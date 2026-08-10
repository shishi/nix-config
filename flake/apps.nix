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
      preflight = pkgs.writeShellApplication {
        name = "preflight";
        runtimeInputs = with pkgs; [
          coreutils
          gnugrep
          iproute2
          getent
          glibc.bin
        ];
        text = builtins.readFile ../scripts/preflight.sh;
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
        # 契約クリティカル preflight → 直接 activation → 成功記録。
        # 素の `nh home switch` はガードを迂回するため非公認(#8(a) 裁定まで)
        switch = {
          type = "app";
          program = "${pkgs.writeShellScript "switch" ''
            set -euo pipefail
            if [ "''${1:-}" != "--force" ]; then
              ${preflight}/bin/preflight --critical
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

        preflight = {
          type = "app";
          program = "${preflight}/bin/preflight";
        };

        # rust-bootstrap: HM 側と同一実体(home/core/rust.nix と同じ script + tools 既定値)
        rust-bootstrap = {
          type = "app";
          program = "${self.homeConfigurations."shishi".config.home.path}/bin/rust-bootstrap";
        };

        update = {
          type = "app";
          program = "${
            pkgs.writeShellApplication {
              name = "update-all";
              runtimeInputs = with pkgs; [
                git
                nix
                jq
                nix-update
                nix-output-monitor
              ];
              text = builtins.readFile ../scripts/update-all.sh;
            }
          }/bin/update-all";
        };
        default = self'.apps.update;

        # インストーラの pin(リハーサルと本番を同一 rev に。flake input 版を使用)
        nixos-anywhere = {
          type = "app";
          program = "${inputs'.nixos-anywhere.packages.default}/bin/nixos-anywhere";
        };

        setup-sudo-nopasswd = mkScriptApp "setup-sudo-nopasswd" ../scripts/setup-sudo-nopasswd.sh;
        setup-trusted-user = mkScriptApp "setup-trusted-user" ../scripts/setup-nix-trusted-user.sh;
        install-system-packages = mkScriptApp "install-system-packages" ../scripts/install-system-packages.sh;
      };
    };
}
