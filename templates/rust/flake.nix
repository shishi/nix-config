{
  description = "A Rust project with flake-parts";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    systems.url = "github:nix-systems/default";
    fenix = {
      url = "github:nix-community/fenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    inputs@{ flake-parts, systems, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
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
        let
          # Fenixを使用したRustツールチェイン
          rust = inputs.fenix.packages.${system}.stable.withComponents [
            "cargo"
            "clippy"
            "rust-src"
            "rustc"
            "rustfmt"
          ];
        in
        {
          # 開発シェル
          devShells.default = pkgs.mkShell {
            packages = with pkgs; [
              rust
              rust-analyzer
              pkg-config

              # よく使う開発ツール
              cargo-watch
              cargo-edit
              cargo-outdated
            ];

            # 環境変数
            RUST_SRC_PATH = "${rust}/lib/rustlib/src/rust/library";

            shellHook = ''
              echo "Rust development environment"
              echo "rustc version: $(rustc --version)"
              echo "cargo version: $(cargo --version)"
            '';
          };

          # パッケージビルドの例
          # packages.default = pkgs.rustPlatform.buildRustPackage {
          #   pname = "my-rust-app";
          #   version = "0.1.0";
          #   src = ./.;
          #   cargoSha256 = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
          # };
        };
    };
}
