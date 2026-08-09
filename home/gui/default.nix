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
    home.packages = with pkgs; [
      _1password-gui
      brave
      discord
      firefox
      flameshot
      google-chrome
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
