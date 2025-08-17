{
  config,
  pkgs,
  lib,
  myLib,
  ...
}:

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

      # GUI/CLI環境に応じたエディタ設定の例
      core.editor = myLib.guiCliConfig {
        gui = "code --wait"; # GUI環境ではVS Code
        cli = "nvim"; # CLI環境ではNeovim
      };
    };
  };
}
