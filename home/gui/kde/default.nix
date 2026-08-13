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
    home.packages = with pkgs; [
      kdePackages.yakuake
      kdePackages.kzones
    ];

    programs.plasma = {
      enable = true;

      # Plasma は /etc/locale.conf とは別に plasma-localerc を見る。
      # NixOS 側(nixos/locale.nix)だけ変えても Plasma 配下のアプリに届かない
      # 可能性があるため、同じ値をここにも置いて曖昧さを消す。
      # Translations を書かないと、書式は英語だが UI は日本語のままになる。
      configFile."plasma-localerc" = {
        Formats.LANG = "en_US.UTF-8";
        Formats.LC_TIME = "en_DK.UTF-8";
        Formats.LC_MONETARY = "ja_JP.UTF-8";
        Formats.LC_MEASUREMENT = "ja_JP.UTF-8";
        Translations.LANGUAGE = "en_US";
      };

      # パネルを右へ。plasma-manager は panels が宣言されると
      # plasma-org.kde.plasma.desktop-appletsrc を削除してから作り直すので、
      # 使うウィジェットはすべてここに並べる必要がある(GUI での追加は次の switch で消える)。
      # kimpanel は fcitx5 の入力モード表示なので落とさない。
      panels = [
        {
          location = "right";
          widgets = [
            "org.kde.plasma.showdesktop"
            "org.kde.plasma.kickoff"
            "org.kde.plasma.pager"
            "org.kde.plasma.icontasks"
            "org.kde.plasma.marginsseparator"
            "org.kde.plasma.kimpanel"
            "org.kde.plasma.systemtray"
            {
              # LC_TIME=en_DK は glibc では %Y-%m-%d を返すが、Qt の en_DK は
              # CLDR 由来で dd/MM/y になる。Plasma のウィジェットは glibc ではなく
              # Qt のロケールを見るので、書式をロケール任せにすると時計だけ
              # 13/08/2026 と出てしまう。LC_TIME 自体はシェル・ログ側で意図どおり
              # 効いているので変えず、ウィジェットの書式だけ明示して打ち消す。
              #
              # 日付は isoDate ではなくカスタム指定にした。isoDate も yyyy-MM-dd を
              # 出すが、Qt の ISO 表現に委ねる分だけ「何が出るか」が上流依存になる。
              # 書式そのものを書けば読んだとおりの文字列が出る。
              digitalClock = {
                date.enable = true;
                date.format = {
                  custom = "yyyy-MM-dd";
                };
                # 24 時制であること自体はロケールに任せず固定する。ただし
                # 区切り文字までは直せない。Plasma のデジタル時計に時刻書式の
                # カスタム指定は無く、区切りはロケール由来のものが残るので、
                # 表示は en_DK の 11.33 のままになる(11:33 にはならない)。
                time.format = "24h";
              };
            }
          ];
        }
      ];

      # KZones: FancyZones 相当のゾーンタイリング。
      # KWin 組み込みのカスタムタイリングは Shift をハードコードしていて
      # 修飾キーを変えられない(KDE Bug 466269)。KZones は
      # zoneOverlayShowWhen=0(= ウィンドウを動かし始めたとき)なので
      # 修飾キー無しでドラッグするだけでゾーンが出る。
      #
      # ゾーンはパーセント指定(layoutsJson)なので画面 UUID に依存しない。
      # KWin 組み込みは Tiling/<仮想デスクトップ UUID>/<画面 UUID> に持つため
      # 機体をまたげないが、こちらは VM で決めたものを実機へ持ち込める。
      #
      # 組み込みのカスタムタイリング(Meta+T のゾーンエディタと Shift ドラッグ)は
      # 無効化しない。KZones が期待どおりでなかったときの退避経路として残す。
      configFile."kwinrc" = {
        Plugins.kzonesEnabled = true;
        "Script-kzones" = {
          # 上流の既定と同じ値だが、意図を宣言として残す
          # (既定が変わってもドラッグ即表示を維持するため)。
          zoneOverlayShowWhen = 0;
          enableZoneSelector = true;
          rememberWindowGeometries = true;
        };
      };

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

          # Meta+矢印 は KZones に持たせる。KWin 側の Quick Tile(画面半分への
          # スナップ)と衝突するので、空リストを渡して none にする。
          # plasma-manager は [] を "none" として書き出す。
          "Window Quick Tile Left" = [ ];
          "Window Quick Tile Right" = [ ];
          "Window Quick Tile Top" = [ ];
          "Window Quick Tile Bottom" = [ ];
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
