{ config, pkgs, ... }:

{
  programs.git = {
    enable = true;
    userName = "Your Name";
    userEmail = "your.email@example.com";
    
    aliases = {
      co = "checkout";
      ci = "commit";
      st = "status";
    };
    
    extraConfig = {
      init.defaultBranch = "main";
      pull.rebase = true;
    };
  };
}