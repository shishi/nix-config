{
  config,
  lib,
  pkgs,
  ...
}:
let
  shishiHome = config.home-manager.users.shishi or { };
  computerUseEnabled = shishiHome.programs.codexDesktopLinux.computerUseUi.enable or false;
  hasKdePortal = builtins.any (
    portal: portal.outPath == pkgs.kdePackages.xdg-desktop-portal-kde.outPath
  ) config.xdg.portal.extraPortals;
  hasKdePortalConfig = builtins.any (
    package: package.outPath == pkgs.kdePackages.plasma-workspace.outPath
  ) config.xdg.portal.configPackages;
  usesPackagedKdePortalConfig = !(config.xdg.portal.config ? kde);
in
{
  imports = [ ./wayland.nix ];

  services.displayManager.sddm.enable = true;
  services.desktopManager.plasma6.enable = true;

  # オプション名の gnome は nixpkgs の歴史的な名前空間で、GNOME Shell は導入しない。
  # AT-SPI の汎用 D-Bus サービスとクライアントパッケージを Computer Use のため明示する。
  services.gnome.at-spi2-core.enable = true;

  # Home Manager の dconf モジュールは、NixOS 側の D-Bus サービスも必要とする。
  programs.dconf.enable = true;

  # スクリーンショットは XDG Desktop Portal 経由で取得する。Plasma からの推移的な
  # 有効化だけに依存せず、Computer Use の実行要件として明示する。
  xdg.portal.enable = true;

  # KDE の RemoteDesktop Portal は、ポインター入力と組になるスクリーンキャスト元を
  # PipeWire へ公開する。セッションマネージャーも含めて明示する。
  services.pipewire = {
    enable = true;
    wireplumber.enable = true;
  };

  assertions = lib.optionals computerUseEnabled [
    {
      assertion = config.services.desktopManager.plasma6.enable;
      message = "Codex Desktop Computer Use requires Plasma and KWin";
    }
    {
      assertion = config.services.gnome.at-spi2-core.enable;
      message = "Codex Desktop Computer Use requires the AT-SPI D-Bus service";
    }
    {
      assertion = config.xdg.portal.enable;
      message = "Codex Desktop Computer Use requires XDG Desktop Portal";
    }
    {
      assertion = config.services.pipewire.enable;
      message = "Codex Desktop Computer Use requires PipeWire for portal input";
    }
    {
      assertion = config.services.pipewire.wireplumber.enable;
      message = "Codex Desktop Computer Use requires WirePlumber for portal input";
    }
    {
      # Plasma のモジュールがバックエンドと経路設定を宣言する。ここでも追加すると
      # listOf が同じパッケージを重複結合するため、契約で存在を固定する。
      assertion = hasKdePortal;
      message = "Codex Desktop Computer Use requires the KDE desktop portal backend";
    }
    {
      assertion = hasKdePortalConfig;
      message = "Codex Desktop Computer Use requires the KDE portal routing configuration";
    }
    {
      # 明示した config.kde は configPackages より優先される。部分的な上書きでも
      # plasma-workspace の default=kde が隠れるため、パッケージ側を正本に固定する。
      assertion = usesPackagedKdePortalConfig;
      message = "Codex Desktop Computer Use requires the packaged KDE portal routing configuration";
    }
    {
      assertion = shishiHome.dconf.enable or false;
      message = "Codex Desktop Computer Use requires persistent dconf settings";
    }
    {
      assertion = config.programs.dconf.enable;
      message = "Codex Desktop Computer Use requires NixOS dconf support";
    }
    {
      assertion =
        shishiHome.dconf.settings."org/gnome/desktop/interface"."toolkit-accessibility" or false;
      message = "Codex Desktop Computer Use requires persistent toolkit accessibility";
    }
  ];

  # SDDM の greeter は自分でロケールを決めない。display-manager.service を
  # 起動した時点の PID1 の環境を受け継ぐだけで、unit にも sddm.conf にも
  # ロケールの宣言が無い。つまりログイン画面の言語と書式は
  # 「最後にこのサービスを起動したときの /etc/locale.conf」という暗黙の状態に
  # なっている。NixOS は display-manager を X-RestartIfChanged=false にしていて
  # nixos-rebuild switch では再起動しないので、ロケールを変えても greeter だけ
  # 古い世代のまま取り残される(実測: 起動済み sddm の environ が
  # LANG=ja_JP.UTF-8、同時点の systemd manager 環境は LANG=en_US.UTF-8)。
  # unit へ書き出して、greeter のロケールを暗黙の継承ではなく宣言で決める。
  #
  # LANG だけでなく extraLocaleSettings ごと渡すのは、LANG 単独では宣言として
  # 穴が残るため。gettext / Qt は LC_ALL > LC_MESSAGES > LANG の順に見るので、
  # 将来 extraLocaleSettings にそのどちらかが入れば LANG は表示言語に効かなくなる。
  # LC_TIME 側にも「古い世代が居座る」経路がそのまま残ってしまう。
  #
  # 値を直書きせず i18n を参照するのは、nixos/locale.nix と greeter がずれる
  # 余地を残さないため。
  #
  # sddm の settings.General.GreeterEnvironment に書く案は却下した。
  # nixpkgs の sddm モジュールは Wayland + kwin のとき同じキーへ
  # QT_WAYLAND_SHELL_INTEGRATION=layer-shell を入れており、settings は
  # recursiveUpdate で文字列ごと上書きされる。書いた瞬間に layer-shell の
  # 指定を落とすうえ、モジュール内部の既定値を手元に写して二重管理になる。
  systemd.services.display-manager.environment = {
    LANG = config.i18n.defaultLocale;
  }
  // config.i18n.extraLocaleSettings;
}
