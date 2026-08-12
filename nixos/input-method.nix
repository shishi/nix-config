{ pkgs, ... }:
{
  i18n.inputMethod = {
    enable = true;
    type = "fcitx5";
    fcitx5 = {
      addons = with pkgs; [
        fcitx5-skk
        qt6Packages.fcitx5-configtool
      ];

      # Plasma 6 の Wayland セッションは text-input-v2 / v3 を実装するため、
      # アプリはコンポジタ経由で入力メソッドと話せる。true にすると
      # GTK_IM_MODULE / QT_IM_MODULE を設定しなくなり、その経路に一本化される。
      # 両方を併用すると候補ウィンドウが点滅する既知の不具合があり、
      # fcitx5 自身が Plasma 上で診断ダイアログを出す(VM リハーサルで実測)。
      # XMODIFIERS は XWayland アプリ向けに残る(モジュール側が常に設定する)。
      # この構成の Plasma は Wayland 専用(実測: share/xsessions が存在しない)ため、
      # X11 セッションへ落ちて Qt の IM 経路を失う心配はない。
      # 未検証: Electron 系は NIXOS_OZONE_WL 未設定だと XWayland 経由になり、
      # XIM フォールバックで preedit の見え方が変わる可能性がある。
      waylandFrontend = true;

      # 入力メソッドの既定値。これが無いと初回ログイン時の fcitx5 は
      # keyboard-us だけの profile を書き、SKK は未選択のままになる
      # (VM リハーサルで実測: ~/.config/fcitx5/profile が未生成で SKK 不在)。
      # 書き出し先は /etc/xdg/fcitx5/profile なので、ユーザーが GUI で変更すれば
      # ~/.config 側が優先される。固定ではなく既定値の提供。
      # 裏返しとして、一度ユーザー profile ができると以後ここを変えても届かない
      # (直すなら ~/.config/fcitx5/profile を削除する)。
      # 入力メソッド名 skk は fcitx5-skk が置く inputmethod/skk.conf に対応する。
      settings.inputMethod = {
        "Groups/0" = {
          Name = "Default";
          "Default Layout" = "us";
          DefaultIM = "skk";
        };
        "Groups/0/Items/0".Name = "keyboard-us";
        "Groups/0/Items/1".Name = "skk";
        GroupOrder."0" = "Default";
      };
    };
  };
}
