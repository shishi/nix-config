{ config, pkgs, ... }:

{
  imports = [
    ./modules/shell.nix
    ./modules/git.nix
    ./modules/editor.nix
  ];

  home = {
    username = "shishi";
    homeDirectory = "/home/shishi";
    stateVersion = "24.05";
  };

  # Home Managerを有効化
  programs.home-manager.enable = true;
}