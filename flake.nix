{
  description = "Personal Nix configuration with flake-parts and home-manager";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    systems.url = "github:nix-systems/default";
    # nixpkgs-ruby.url = "github:bobvanderlinden/nixpkgs-ruby";

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
  };

  # nixConfig: Cachixなどのバイナリキャッシュ設定
  # この設定はflakeのトップレベルでのみ有効
  # 注意: これらの設定はtrusted-userのみが使用可能
  # trusted-userでない場合は --option を使用するか、以下のセットアップを実行:
  # echo "trusted-users = root $USER" | sudo tee -a /etc/nix/nix.conf && sudo systemctl restart nix-daemon
  nixConfig = {
    # 追加の公開鍵を許可（trusted-userでなくても使用可能）
    extra-trusted-public-keys = [
      "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
    ];

    # 追加のバイナリキャッシュを許可（trusted-userでなくても使用可能）
    extra-substituters = [
      "https://nix-community.cachix.org"
    ];

    # デフォルトのキャッシュ設定（trusted-userが必要）
    trusted-public-keys = [
      "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
      "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
    ];

    substituters = [
      "https://cache.nixos.org"
      "https://nix-community.cachix.org"
    ];

    # 警告を減らすための設定
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

        # グローバルオーバーレイのエクスポート
        # 他のflakeがこのoverlayを使えるようにする
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
            # perSystem内のpkgsカスタマイズ
            # ここは開発シェル（devShells）やカスタムパッケージ（packages）用
            # _module.args.pkgsでperSystem内のデフォルトpkgsを上書き
            _module.args.pkgs = import inputs.nixpkgs {
              inherit system;
              config = {
                allowUnfree = true;
              };
              overlays = [
                (import ./overlays/default.nix)
                inputs.neovim-nightly-overlay.overlays.default
                inputs.fenix.overlays.default
              ];
            };

            # treefmtの設定
            treefmt = {
              projectRootFile = "flake.nix";
              programs = {
                nixfmt-rfc-style.enable = true;
              };
            };

            apps = {
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
