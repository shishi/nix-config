{
  config,
  pkgs,
  lib,
  ...
}:
{
  imports = [
    ./gnome
    ./kde
  ];

  # セッション不要・WSLg でも動く GUI 共通セット
  config = lib.mkIf config.my.gui.enable {
    # 既定ブラウザ(XDG 経路)。宣言が無いと mimeinfo.cache の走査順で決まり、
    # 何が既定になるかがパッケージの増減で変わる。実機では Edge が開く事故が
    # 起きた(KDE 経路の話は home/gui/kde/default.nix の BrowserApplication 参照)。
    # Edge も Chrome も入れてあるが、既定は Brave で固定する。
    xdg.mimeApps = {
      enable = true;
      defaultApplications = {
        "text/html" = [ "brave-browser.desktop" ];
        "x-scheme-handler/http" = [ "brave-browser.desktop" ];
        "x-scheme-handler/https" = [ "brave-browser.desktop" ];
        "x-scheme-handler/about" = [ "brave-browser.desktop" ];
        "x-scheme-handler/unknown" = [ "brave-browser.desktop" ];
      };
    };

    home.packages = with pkgs; [
      _1password-gui
      brave
      chatgpt-desktop-app
      discord
      firefox
      flameshot
      google-chrome
      llm-agents.claude-desktop
      localsend
      microsoft-edge
      slack
      tailscale-systray
      teamviewer
      vesktop
      vlc
      vscode
      wezterm
    ];
  };
}
