{
  config,
  pkgs,
  lib,
  inputs,
  ...
}:
{
  imports = [ inputs.plasma-manager.homeModules.plasma-manager ];

  config = lib.mkIf (config.my.desktopSession == "kde") {
    home.packages = [ pkgs.kdePackages.yakuake ];

    programs.plasma = {
      enable = true;

      # クロス DE 契約(確定不変): Caps→Ctrl、キーリピート
      input.keyboard = {
        options = [ "ctrl:nocaps" ];
        repeatDelay = 200;
        repeatRate = 33; # ≒ 1000ms / 30ms interval
      };

      # KDE キーバインド(#16 裁定: GNOME 対応物を移植)
      shortcuts = {
        kwin = {
          "Window Close" = [
            "Alt+F4"
            "Ctrl+Q"
          ];
          "Switch to Desktop 1" = "Ctrl+1";
          "Switch to Desktop 2" = "Ctrl+2";
          "Switch to Desktop 3" = "Ctrl+3";
          "Switch to Desktop 4" = "Ctrl+4";
          "Window Maximize" = "Ctrl+Alt+Return";
        };
        "yakuake"."toggle-window-state" = "Alt+I";
        "services/org.wezfurlong.wezterm.desktop"._launch = "Ctrl+Alt+T";
      };

      # 暫定(per-host 初期値。実機確認後にクロス DE 契約へ昇格)
      kscreenlocker = {
        autoLock = true;
        timeout = 60; # 分
        lockOnResume = true;
      };
      powerdevil.AC = {
        autoSuspend.action = "sleep";
        autoSuspend.idleTimeout = 7200;
      };
      powerdevil.battery = {
        autoSuspend.action = "sleep";
        autoSuspend.idleTimeout = 3600;
      };
    };
  };
}
