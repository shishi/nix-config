{
  description = "Personal Nix configuration with flake-parts and home-manager";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    
    flake-parts.url = "github:hercules-ci/flake-parts";
    
    # システムを自動検出するためのユーティリティ
    systems.url = "github:nix-systems/default";
  };

  outputs = inputs@{ flake-parts, systems, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      imports = [
        ./modules
      ];
      
      # システムを外部定義から取得
      systems = import systems;
      
      perSystem = { config, self', inputs', pkgs, system, ... }: {
        # カスタムパッケージ
        packages = import ./pkgs { inherit pkgs; };
        
        # オーバーレイ
        overlayAttrs = import ./overlays/default.nix;
        
        # 開発シェル
        devShells = import ./shells { inherit pkgs; };
      };
      
      flake = {
        # Home Manager設定
        homeConfigurations = {
          "shishi@ubuntu" = inputs.home-manager.lib.homeManagerConfiguration {
            pkgs = inputs.nixpkgs.legacyPackages.${builtins.currentSystem};
            modules = [ ./home-manager ];
            
            # 複数マシンに対応する場合：
            # 1. ホスト名で分岐: if builtins.getEnv "HOSTNAME" == "machine1" then ...
            # 2. flake outputsで複数定義: homeConfigurations."user@machine1", "user@machine2"
            # 3. 共通設定をモジュール化して、マシン固有の設定だけ分離
          };
        };
        
        # グローバルオーバーレイ
        overlays.default = import ./overlays/default.nix;
      };
    };
}