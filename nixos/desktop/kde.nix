{ config, ... }:
{
  imports = [ ./wayland.nix ];

  services.displayManager.sddm.enable = true;
  services.desktopManager.plasma6.enable = true;

  # Plasma が Portal と AT-SPI を提供する。Computer Use 用の映像経路だけ追加する。
  services.pipewire = {
    enable = true;
    wireplumber.enable = true;
  };

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
