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
  nixConfig = {
    trusted-public-keys = [
      "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
      "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
    ];

    substituters = [
      "https://cache.nixos.org"
      "https://nix-community.cachix.org"
    ];
  };

  outputs =
    inputs@{ flake-parts, systems, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      imports = [
        ./modules
        inputs.treefmt-nix.flakeModule
      ];

      systems = import systems;

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
              inputs.fenix.overlays.default
            ];
          };

          packages = import ./pkgs { inherit pkgs; };
          devShells = import ./shells { inherit pkgs; };

          # treefmtの設定
          treefmt = {
            projectRootFile = "flake.nix";
            programs = {
              nixfmt-rfc-style.enable = true;
            };
          };

          apps = {
            install-system-packages = {
              type = "app";
              program = "${pkgs.bash}/bin/bash ${./scripts/install-system-packages.sh}";
            };
          };

          # perSystem内でlegacyPackagesとしてhomeConfigurationを定義
          # これによりsystemが自動的に使用される
          legacyPackages.homeConfigurations = {
            "shishi@ubuntu" = inputs.home-manager.lib.homeManagerConfiguration {
              inherit pkgs;  # perSystemのpkgsを使用（systemが含まれている）
              modules = [
                ./home-manager
                {
                  # カスタムライブラリをHome Managerに渡す
                  _module.args = {
                    myLib = import ./lib {
                      inherit (inputs.nixpkgs) lib pkgs;
                    };
                  };
                }
              ];
            };
          };
        };

      flake = {
        # Home Manager設定（perSystemから集約）
        homeConfigurations = {
          # 各システムのhomeConfigurationsを統合
          "shishi@ubuntu" = self.legacyPackages.x86_64-linux.homeConfigurations."shishi@ubuntu" or
                            self.legacyPackages.aarch64-linux.homeConfigurations."shishi@ubuntu" or
                            throw "No homeConfiguration found for shishi@ubuntu";
            # Home Manager用のpkgs設定
            # ここはユーザー環境にインストールされるパッケージ用
            pkgs = import inputs.nixpkgs {
              system = "x86_64-linux"; # Explicitly set for Ubuntu
              config.allowUnfree = true;
              overlays = [
                (import ./overlays/default.nix)
                inputs.fenix.overlays.default
              ];
            };
            modules = [
              ./home-manager
              {
                # カスタムライブラリをHome Managerに渡す
                _module.args = {
                  myLib = import ./lib {
                    inherit (inputs.nixpkgs) lib;
                    pkgs = import inputs.nixpkgs {
                      system = "x86_64-linux"; # Explicitly set for Ubuntu
                      config.allowUnfree = true;
                      overlays = [
                        (import ./overlays/default.nix)
                        inputs.fenix.overlays.default
                      ];
                    };
                  };
                };
              }
            ];

            # 複数マシンに対応する場合：
            # 1. ホスト名で分岐: if builtins.getEnv "HOSTNAME" == "machine1" then ...
            # 2. flake outputsで複数定義: homeConfigurations."user@machine1", "user@machine2"
            # 3. 共通設定をモジュール化して、マシン固有の設定だけ分離
          };
        };

        # グローバルオーバーレイのエクスポート
        # 他のflakeがこのoverlayを使えるようにする
        # 例: 他の人が inputs.your-flake.overlays.default で利用可能
        overlays.default = import ./overlays/default.nix;
      };
    };
}
