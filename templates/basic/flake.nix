{
  description = "A basic flake with flake-parts";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    systems.url = "github:nix-systems/default";
    treefmt-nix.url = "github:numtide/treefmt-nix";
  };

  outputs =
    inputs@{ flake-parts, systems, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      imports = [
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
          # treefmtの設定
          treefmt = {
            # treefmt-nixプロジェクト設定
            projectRootFile = "flake.nix";

            # 各言語のフォーマッター設定
            programs = {
              # Nixファイル
              nixpkgs-fmt.enable = true;

              # その他の言語の例（必要に応じて有効化）
              # prettier = {
              #   enable = true;
              #   includes = ["*.js" "*.ts" "*.json" "*.md"];
              # };
              # rustfmt.enable = true;
              # gofmt.enable = true;
              # black.enable = true;
              # shfmt.enable = true;
            };
          };

          # 開発シェル
          devShells.default = pkgs.mkShell {
            packages = with pkgs; [
              # 開発ツールをここに追加
              # treefmtは自動的に含まれる
            ];

            shellHook = ''
              echo "Welcome to the development shell!"
              echo "Run 'treefmt' to format all files"
            '';
          };

          # パッケージ定義の例
          # packages.default = pkgs.hello;

          # アプリケーションの例
          # apps.default = {
          #   type = "app";
          #   program = "${pkgs.hello}/bin/hello";
          # };
        };
    };
}
