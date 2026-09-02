{
  config,
  pkgs,
  lib,
  ...
}:
{
  config = lib.mkIf (config.my.desktopSession == "gnome") {
    home.packages = with pkgs; [
      gnome-screenshot
      gnomeExtensions.clipboard-indicator
      guake
      dconf2nix
    ];

    dconf = {
      enable = true;
      settings = {
        # クロス DE 契約(確定不変): Caps→Ctrl、キーリピート
        "org/gnome/desktop/input-sources".xkb-options = [ "ctrl:nocaps" ];
        "org/gnome/desktop/peripherals/keyboard" = {
          delay = lib.hm.gvariant.mkUint32 200;
          repeat-interval = lib.hm.gvariant.mkUint32 30;
        };

        "org/gnome/settings-daemon/plugins/media-keys".custom-keybindings = [
          "/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom0/"
          "/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom1/"
        ];
        # ターミナル起動は wezterm
        "org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom0" = {
          binding = "<Control><Alt>t";
          command = "wezterm";
          name = "Terminal";
        };
        "org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom1" = {
          binding = "<Alt>i";
          command = "guake -t";
          name = "Toggle Guake";
        };

        "org/gnome/desktop/wm/keybindings" = {
          close = [
            "<Alt>F4"
            "<Control>q"
          ];
          switch-to-workspace-1 = [ "<Control>1" ];
          switch-to-workspace-2 = [ "<Control>2" ];
          switch-to-workspace-3 = [ "<Control>3" ];
          switch-to-workspace-4 = [ "<Control>4" ];
          maximize = [ "<Control><Alt>Return" ];
        };

        "org/gnome/desktop/peripherals/touchpad" = {
          tap-to-click = true;
          two-finger-scrolling-enabled = true;
        };

        # 暫定(per-host 初期値。実機確認後にクロス DE 契約へ昇格)
        "org/gnome/desktop/screensaver" = {
          idle-activation-enabled = true;
          lock-enabled = true;
          lock-delay = lib.hm.gvariant.mkUint32 0;
        };
        "org/gnome/desktop/session".idle-delay = lib.hm.gvariant.mkUint32 3600;
        "org/gnome/settings-daemon/plugins/power" = {
          sleep-inactive-ac-timeout = 7200;
          sleep-inactive-ac-type = "suspend";
          sleep-inactive-battery-timeout = 3600;
          sleep-inactive-battery-type = "suspend";
        };
      };
    };
  };
}
