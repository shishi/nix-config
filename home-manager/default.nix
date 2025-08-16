{
  config,
  pkgs,
  lib,
  myLib,
  ...
}:

{
  imports = [
    ./modules/dconf.nix
    ./modules/packages.nix
    ./modules/rust.nix
    ./modules/shell.nix
    ./modules/yaskkserv2.nix
    # ./modules/git.nix
    # ./modules/editor.nix
  ];

  home = {
    username = "shishi";
    homeDirectory = "/home/shishi";
    stateVersion = "24.05";

    sessionVariables = {
      EDITOR = "nvim";
      VISUAL = "nvim";
      PAGER = "less";
      LESS = "-R";
    };
  };

  programs.home-manager.enable = true;
}
