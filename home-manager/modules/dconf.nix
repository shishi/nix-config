{
  config,
  pkgs,
  lib,
  myLib,
  ...
}:

{
  # dconf設定 (GNOME/GTK設定)
  # GUI環境でのみ有効化
  dconf = lib.mkIf (myLib.hasGui { inherit pkgs lib; }) {
    enable = true;
    settings = {
      # キーボードレイアウト設定
      "org/gnome/desktop/input-sources" = {
        # Caps LockをCtrlに変更
        xkb-options = [ "ctrl:nocaps" ];

        # その他の便利なオプション例（コメントアウト）:
        # xkb-options = [
        #   "ctrl:nocaps"        # Caps Lock → Ctrl
        #   "ctrl:swapcaps"      # Caps Lock ⇔ Ctrl 入れ替え
        #   "caps:escape"        # Caps Lock → Escape
        #   "caps:ctrl_modifier" # Caps Lockを追加のCtrlキーとして使用
        #   "altwin:swap_lalt_lwin" # Alt ⇔ Super 入れ替え
        # ];
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
        ];
      };

      # ターミナル起動のショートカット
      "org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom0" = {
        binding = "<Control><Alt>t";
        command = "gnome-terminal";
        name = "Terminal";
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
    };
  };

  # dconf2nixツールをインストール（設定のエクスポート用）
  home.packages = lib.optionals (myLib.hasGui { inherit pkgs lib; }) [
    pkgs.dconf2nix
  ];
}
