# flake-parts モジュール集約
# 新しいモジュールを追加する場合はここにimportを追加する
{
  imports = [
    ./apps.nix
    ./home-configurations.nix
    ./shells.nix
  ];
}
