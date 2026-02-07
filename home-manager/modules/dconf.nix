# GNOME/GTK設定 (dconf)
# GUI環境でのみ有効化 (myConfig.hasGui)
# 現在の設定をエクスポート: dconf2nix -o dconf-dump.nix
{
  config,
  pkgs,
  lib,
  ...
}:

{
  dconf = lib.mkIf config.myConfig.hasGui {
    enable = true;
    settings = {
      "org/gnome/desktop/input-sources" = {
        # 他の選択肢: "ctrl:swapcaps" "caps:escape" "altwin:swap_lalt_lwin"
        xkb-options = [ "ctrl:nocaps" ];
      };

      # キーリピート設定
      "org/gnome/desktop/peripherals/keyboard" = {
        delay = 200; # キーリピート開始までの遅延 (ms)
        repeat-interval = 30; # キーリピート間隔 (ms)
      };

      # ショートカットキー設定の例
      "org/gnome/settings-daemon/plugins/media-keys" = {
        # カスタムショートカット
        custom-keybindings = [
          "/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom0/"
          "/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom1/"
        ];
      };

      # ターミナル起動のショートカット
      "org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom0" = {
        binding = "<Control><Alt>t";
        command = "gnome-terminal";
        name = "Terminal";
      };

      # Guakeトグルのショートカット
      "org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom1" = {
        binding = "<Alt>i";
        command = "guake -t";
        name = "Toggle Guake";
      };

      # ウィンドウ管理のショートカット
      "org/gnome/desktop/wm/keybindings" = {
        # ウィンドウを閉じる
        close = [
          "<Alt>F4"
          "<Control>q"
        ];

        # ワークスペース切り替え
        switch-to-workspace-1 = [ "<Control>1" ];
        switch-to-workspace-2 = [ "<Control>2" ];
        switch-to-workspace-3 = [ "<Control>3" ];
        switch-to-workspace-4 = [ "<Control>4" ];

        # ウィンドウ最大化
        maximize = [ "<Control><Alt>Return" ];
      };

      # タッチパッド設定（ノートPC向け）
      "org/gnome/desktop/peripherals/touchpad" = {
        tap-to-click = true;
        two-finger-scrolling-enabled = true;
      };

      # スクリーンセーバーとロック設定
      "org/gnome/desktop/screensaver" = {
        # スクリーンセーバー起動までの時間（秒）
        idle-activation-enabled = true;
        lock-enabled = true;
        lock-delay = 0; # スクリーンセーバー後、即座にロック
      };

      # セッション設定
      "org/gnome/desktop/session" = {
        # アイドル状態と判定するまでの時間（秒）
        # 300 = 5分, 600 = 10分, 900 = 15分, 1800 = 30分, 3600 = 60分
        idle-delay = 3600; # 60分
      };

      # 電源管理設定
      "org/gnome/settings-daemon/plugins/power" = {
        # AC電源接続時の設定
        sleep-inactive-ac-timeout = 7200; # 120分（2時間）でスリープ
        sleep-inactive-ac-type = "suspend";

        # バッテリー駆動時の設定
        sleep-inactive-battery-timeout = 3600; # 60分でスリープ
        sleep-inactive-battery-type = "suspend";
      };
    };
  };

  home.packages = lib.optionals config.myConfig.hasGui [
    pkgs.dconf2nix
  ];
}
