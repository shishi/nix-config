{
  description = "Personal Nix configuration with flake-parts and home-manager";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    systems.url = "github:nix-systems/default";

    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    neovim-nightly-overlay = {
      url = "github:nix-community/neovim-nightly-overlay";
    };

    fenix = {
      url = "github:nix-community/fenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    llm-agents = {
      url = "github:numtide/llm-agents.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  # バイナリキャッシュ設定
  # trusted-userでない場合: nix run .#setup-trusted-user
  nixConfig = {
    # extra-*: trusted-userでなくても使用可能
    extra-trusted-public-keys = [
      "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
      "niks3.numtide.com-1:DTx8wZduET09hRmMtKdQDxNNthLQETkc/yaX7M4qK0g="
    ];

    extra-substituters = [
      "https://nix-community.cachix.org"
      "https://cache.numtide.com"
    ];

    # trusted-userが必要
    trusted-public-keys = [
      "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
      "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
      "niks3.numtide.com-1:DTx8wZduET09hRmMtKdQDxNNthLQETkc/yaX7M4qK0g="
    ];

    substituters = [
      "https://cache.nixos.org"
      "https://nix-community.cachix.org"
      "https://cache.numtide.com"
    ];

    accept-flake-config = true;
  };

  outputs =
    inputs@{
      flake-parts,
      systems,
      ...
    }:
    flake-parts.lib.mkFlake { inherit inputs; } (
      { self, ... }:
      {
        imports = [
          ./modules
          inputs.treefmt-nix.flakeModule
        ];

        systems = import systems;

        # overlayをflake出力としてエクスポート
        flake = {
          overlays.default = import ./overlays/default.nix;
        };

        perSystem =
          {
            config,
            self',
            inputs',
            pkgs,
            system,
            ...
          }:
          {
            # overlays適用済みのpkgsを全perSystemモジュールに提供
            _module.args.pkgs = import inputs.nixpkgs {
              inherit system;
              config = {
                allowUnfree = true;
              };
              overlays = [
                self.overlays.default
                inputs.neovim-nightly-overlay.overlays.default
                inputs.fenix.overlays.default
                inputs.llm-agents.overlays.default
              ];
            };

            # treefmtの設定
            treefmt = {
              projectRootFile = "flake.nix";
              programs = {
                nixfmt-rfc-style.enable = true;
              };
            };

            # カスタムパッケージ: nix build .#<pkg> / nix run .#update で更新
            packages = import ./pkgs {
              inherit pkgs;
              lib = pkgs.lib;
            };

            apps = {
              # nix run .#update: flake update + nix-update を一括実行
              update = {
                type = "app";
                program = "${pkgs.writeShellScript "update-all" ''
                  set -euo pipefail

                  GREEN='\033[0;32m'
                  YELLOW='\033[1;33m'
                  BLUE='\033[0;34m'
                  NC='\033[0m'

                  log_info() { echo -e "''${GREEN}[INFO]''${NC} $1"; }
                  log_warn() { echo -e "''${YELLOW}[WARN]''${NC} $1"; }
                  log_step() { echo -e "''${BLUE}[STEP]''${NC} $1"; }

                  FLAKE_ROOT="$(${pkgs.git}/bin/git rev-parse --show-toplevel 2>/dev/null || pwd)"
                  cd "$FLAKE_ROOT"

                  log_info "nix-config の更新を開始します"
                  log_info "Flake root: $FLAKE_ROOT"

                  # 1. nix flake update
                  log_step "nix flake update を実行中..."
                  ${pkgs.nix}/bin/nix flake update

                  # 2. nix-update でカスタムパッケージを更新
                  log_step "カスタムパッケージを取得中..."
                  SYSTEM="$(${pkgs.nix}/bin/nix eval --impure --raw --expr 'builtins.currentSystem')"
                  PACKAGES=$(${pkgs.nix}/bin/nix eval ".#packages.$SYSTEM" --apply 'builtins.attrNames' --json 2>/dev/null | ${pkgs.jq}/bin/jq -r '.[]')

                  if [ -z "$PACKAGES" ]; then
                    log_warn "カスタムパッケージが見つかりませんでした"
                  else
                    log_info "更新対象パッケージ: $PACKAGES"
                    for pkg in $PACKAGES; do
                      log_step "nix-update: $pkg を更新中..."
                      ${pkgs.nix-update}/bin/nix-update --flake "$pkg" --commit || log_warn "$pkg の更新をスキップしました"
                    done
                  fi

                  echo ""
                  log_info "========== 更新完了 =========="

                  # 変更の確認
                  if ! ${pkgs.git}/bin/git diff --quiet flake.lock 2>/dev/null; then
                    log_warn "flake.lock が更新されました"
                    ${pkgs.git}/bin/git diff --stat flake.lock || true
                  fi

                  echo ""
                  log_info "変更を適用するには: nix run home-manager/master -- switch --flake .#shishi@ubuntu"
                ''}";
              };
              setup-sudo-nopasswd = {
                type = "app";
                program = "${pkgs.writeShellScript "setup-sudo-nopasswd" ''
                  exec ${pkgs.bash}/bin/bash ${./scripts/setup-sudo-nopasswd.sh} "$@"
                ''}";
              };
              setup-trusted-user = {
                type = "app";
                program = "${pkgs.writeShellScript "setup-trusted-user" ''
                  exec ${pkgs.bash}/bin/bash ${./scripts/setup-nix-trusted-user.sh} "$@"
                ''}";
              };
              install-system-packages = {
                type = "app";
                program = "${pkgs.writeShellScript "install-system-packages" ''
                  exec ${pkgs.bash}/bin/bash ${./scripts/install-system-packages.sh} "$@"
                ''}";
              };
            };
          };
      }
    );
}
