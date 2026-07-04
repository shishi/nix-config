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

    nix-index-database = {
      url = "github:nix-community/nix-index-database";
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
                # treefmt-nix で nixfmt-rfc-style は programs.nixfmt に統合された
                # (nixfmt 本体が RFC 166 スタイルを採用したため)
                nixfmt.enable = true;
              };
            };

            # カスタムパッケージ: nix build .#<pkg> / nix run .#update で更新
            # apps (update / setup-* / install-*) は modules/apps.nix で定義
            packages = import ./pkgs {
              inherit pkgs;
              lib = pkgs.lib;
            };
          };
      }
    );
}
