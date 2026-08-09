{ lib, ... }:
{
  imports = [
    ./options.nix
    ./core/packages.nix
    ./core/shell.nix
    ./core/direnv.nix
    ./core/nix-tools.nix
    ./core/rust.nix
    ./skk
    ./gui
  ];

  home.username = "shishi";
  home.homeDirectory = "/home/shishi";
  home.stateVersion = "24.05"; # 全ホスト統一。変更は独立した明示的マイグレーションでのみ

  home.sessionVariables = {
    EDITOR = "nvim";
    VISUAL = "nvim";
    PAGER = "less";
    LESS = "-R";
  };

  # standalone ホスト(hosts/ubuntu-wsl)でのみ true にする(mkDefault で上書き可能に)
  programs.home-manager.enable = lib.mkDefault false;
}
