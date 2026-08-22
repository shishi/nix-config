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
      # XMODIFIERS は XWayland アプリ向けに残る(environment.variables に
      # @im=fcitx が入る)。GTK_IM_MODULE と QT_IM_MODULE は未設定になる。
      #
      # X11 セッションの desktop entry は plasma6 module が生成するので、
      # sessionData.desktops に plasmax11.desktop が存在する。
      # kdePackages.plasma-workspace 自身に share/xsessions が無いことを見て
      # 「この構成に X11 は無い」と結論しないこと。
      #
      # 未検証: X11 セッションを選んだときに何が使われるか。この構成は
      # QT_IM_MODULE を設定しないので、X11 を使う予定ができたら先に実機で
      # 打って確かめること。
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

      # 現行の ~/.config/fcitx5/conf/skk.conf(GUI 由来)を既定値として宣言する。
      # 唯一の挙動変更は InitialInputMode で、Hiragana から Latin へ。
      # 起動直後は英数で始めたい(日本語を打つときだけ切り替える)ため。
      # 有効値は Hiragana と Latin の 2 つ(fcitx5-skk のバイナリシンボルで確認)。
      #
      # 書き出し先は /etc/xdg/fcitx5/conf/skk.conf なので、ユーザーが GUI で
      # 変えれば ~/.config 側が勝つ。裏返しとして、既存機ではユーザー側ファイルが
      # 既にあるためここの変更は届かない(効かせるには一度消す)。
      settings.addons.skk = {
        globalSection = {
          Rule = "StickyShift";
          PunctuationStyle = "Japanese";
          InitialInputMode = "Latin";
          PageSize = 7;
          "Candidate Layout" = "Vertical";
          EggLikeNewLine = "True";
          ShowAnnotation = "True";
          CandidateChooseKey = "ABC (a,b,c,...)";
          NTriggersToShowCandWin = 2;
        };
        sections = {
          CandidatesPageUpKey."0" = "Page_Up";
          CandidatesPageDownKey."0" = "Next";
          CursorUp."0" = "Up";
          CursorDown."0" = "Down";
        };
      };
    };
  };
}
