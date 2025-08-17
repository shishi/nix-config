# flake-partsモジュールの基本的な例
#
# flake-partsは、flakeの設定を整理・モジュール化するための仕組みです。
# このファイルはflake.nixのimportsで読み込まれます。
{
  self,
  config,
  inputs,
  ...
}:

{
  imports = [
    ./home-configurations.nix
    ./shells.nix
    ./packages.nix
  ];

  # # perSystem: 各システム（linux、darwin等）ごとの設定
  # perSystem = { system, pkgs, ... }: {
  #   # 1. フォーマッター設定
  #   # `nix fmt`コマンドで使用されるフォーマッター
  #   formatter = pkgs.nixpkgs-fmt;

  #   # 2. カスタムアプリケーション
  #   # `nix run .#hello`で実行できるコマンドを定義
  #   apps.hello = {
  #     type = "app";
  #     program = "${pkgs.writeShellScript "hello" ''
  #       echo "Hello from flake-parts module!"
  #       echo "Current system: ${system}"
  #     ''}";
  #   };

  #   # 3. 開発シェルの追加設定
  #   # flake.nixで定義されたdevShellsに追加のツールを提供
  #   devShells.example = pkgs.mkShell {
  #     packages = with pkgs; [
  #       hello
  #       cowsay
  #     ];

  #     shellHook = ''
  #       echo "Welcome to example dev shell!"
  #       echo "Try running: hello | cowsay"
  #     '';
  #   };
  # };

  # # flake: flake全体に影響する設定
  # flake = {
  #   # このモジュールが提供するオプション設定
  #   # 他のモジュールから参照できる値を定義
  #   config = {
  #     projectName = "my-nix-config";
  #     version = "0.1.0";
  #   };
  # };
}
