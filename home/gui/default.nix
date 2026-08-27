{
  config,
  inputs,
  pkgs,
  lib,
  ...
}:
{
  imports = [
    ./gnome
    ./kde
    inputs.codex-desktop-linux.homeManagerModules.default
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

    # **force が要る。** KDE は「既定のアプリケーション」を GUI から変えると
    # これらのファイルを直接書き、home-manager は管理外のファイルを上書きしない。
    # 付けないと activation が "Existing file ... would be clobbered" で失敗する
    # (実機で実際に失敗し、home-manager-shishi.service が落ちて、この commit の
    # 変更が一切適用されなかった)。新規インストールでも、セッションが一度でも
    # 起動すれば同じ状態になる。
    #
    # 代償として、GUI で関連付けを変えても次の switch で戻る。panels と同じ扱いで、
    # 変えたいものは repo に書く。
    #
    # xdg.mimeApps は 2 箇所に同じ内容を書く(home-manager の
    # modules/misc/xdg/mime-apps.nix)。両方に force が要る。
    xdg.configFile."mimeapps.list".force = true;
    xdg.dataFile."applications/mimeapps.list".force = true;

    # OpenAI の公式 Linux package を NixOS 向けに包む community distribution。
    # package の再現性を優先して version 付き upstream URL を使う。
    # community 独自機能は必要になるまで有効にしない。
    programs.codexDesktopLinux = {
      enable = true;
      linuxFeatures = [ ];
    };

    # launcher は既定で 1 日 1 回、community の GoatCounter へ起動を通知する。
    # login session と systemd user 経由のどちらでも無効になるよう両方へ設定する。
    home.sessionVariables.CODEX_LINUX_DISABLE_USAGE_REPORTING = "1";
    systemd.user.sessionVariables.CODEX_LINUX_DISABLE_USAGE_REPORTING = "1";

    home.packages = with pkgs; [
      _1password-gui
      brave
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
