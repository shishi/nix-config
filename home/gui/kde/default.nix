{
  config,
  pkgs,
  lib,
  inputs,
  ...
}:
let
  krdpDir = "${config.xdg.dataHome}/krdp";
  krdpCert = "${krdpDir}/server.crt";
  krdpCertKey = "${krdpDir}/server.key";

  # krdpserver は TLS 証明書を生成せず、無ければ起動を拒む
  # (src/Server.cpp が exists() を見て「required for the server to run!」)。
  # KCM 経由で作らせると有効期限が 1 日になるので、生成も期限もこちらで持つ。
  #
  # 判定は「使える鍵対か」で行う。証明書と鍵をそれぞれ単体で parse できるかだけを
  # 見ると、片方だけ差し替わった対応しないペアを「ある」と誤認する。両方 parse
  # できてしまうので二度と作り直されず、krdpserver は起動はして TLS で毎回失敗する。
  # 公開鍵の一致と有効期限まで見れば、その状態は次の起動で必ず作り直される。
  #
  # 生成は一時ファイルへ書いて mv で置く。途中で落ちても、残るのは判定に落ちる
  # 組み合わせなので次の起動で作り直される。
  #
  # コマンドはすべて store のパスで呼ぶ。writeShellScript は PATH を固定しない。
  krdpCertScript = pkgs.writeShellScript "krdp-certificate" ''
    set -eu
    cert="$1"
    key="$2"
    if certpub=$(${pkgs.openssl}/bin/openssl x509 -pubkey -noout -in "$cert" 2>/dev/null) \
      && ${pkgs.openssl}/bin/openssl x509 -checkend 0 -noout -in "$cert" 2>/dev/null \
      && keypub=$(${pkgs.openssl}/bin/openssl pkey -pubout -in "$key" 2>/dev/null) \
      && [ "$certpub" = "$keypub" ]; then
      exit 0
    fi
    ${pkgs.coreutils}/bin/mkdir -p -m 700 "$(${pkgs.coreutils}/bin/dirname "$cert")"
    tmpc="$cert.tmp.$$"
    tmpk="$key.tmp.$$"
    trap '${pkgs.coreutils}/bin/rm -f "$tmpc" "$tmpk"' EXIT
    (
      umask 077
      ${pkgs.openssl}/bin/openssl req -x509 -newkey rsa:4096 -nodes -days 3650 \
        -subj "/CN=krdp" -keyout "$tmpk" -out "$tmpc"
    )
    ${pkgs.coreutils}/bin/mv "$tmpk" "$key"
    ${pkgs.coreutils}/bin/mv "$tmpc" "$cert"
  '';

in
{
  imports = [ inputs.plasma-manager.homeModules.plasma-manager ];

  config = lib.mkIf (config.my.desktopSession == "kde") {
    home.packages = with pkgs; [
      kdePackages.yakuake
      kdePackages.kzones
    ];

    programs.plasma = {
      enable = true;

      # KRdp の設定。--address だけは krdpserverrc に対応キーが無いので
      # unit 側のコマンドラインで渡す。
      #
      # SystemUserEnabled は「krdpserver を走らせている本人のシステムパスワードで
      # 認証する」の意味で、repo に秘密を置かないための選択。無効にすると
      # 資格情報が 1 つも無くなり krdpserver は起動に失敗する。
      configFile."krdpserverrc" = {
        General.ListenPort = 3389;
        General.Certificate = krdpCert;
        General.CertificateKey = krdpCertKey;
        General.SystemUserEnabled = true;
      };

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

        # autoLogin は起動時のパスワード入力を消す。LUKS が TPM で自動解錠される
        # 構成では、それが物理アクセスに対する最後の資格情報要求点になっている。
        # 消したぶんをここで戻す。
        #
        # kscreenlockerrc の Daemon.LockOnStart に落ちる。ロックを掛けるのは
        # ロッカー自身で、自分の起動時に lock(EstablishLock::Immediate) を呼ぶ
        # (kscreenlocker の ksldapp.cpp)。外から DBus で頼む形にすると、
        # バス名が登録されるまで待つ必要が出て、待ち・再試行・順序制約が要る。
        #
        # passwordRequired を宣言するのは、ロック画面が出ることと解除に
        # パスワードが要ることが別だから。既定は真だが構成で決まっていないと、
        # KCM で外した値が rc に残ったままになる(plasma-manager は
        # overrideConfig = false のとき、宣言していないキーを消さない)。
        # 猶予は requirePassword が偽のときだけ働く(ksldapp.cpp の
        # m_inGraceTime = !m_requirePassword)ので実質無効だが、0 を書いて
        # 既定値への依存を消す。
        #
        # **rc は書き換え可能な実ファイルなので、手で LockOnStart=false に
        # されると次の activation まで戻らない。** 構成から消さなくても外れる。
        lockOnStartup = true;
        passwordRequired = true;
        passwordRequiredDelay = 0;
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

    # KRdp は動作中の KWin セッションに寄生する。同梱の
    # share/systemd/user/app-org.kde.krdpserver.service は NixOS の generateUnits が
    # etc/ と lib/ しか走査しないため拾われず、拾えたとしても引数を一切渡さないので
    # Portal 経路・0.0.0.0 bind・証明書パス空になり起動しない。自分で書く。
    #
    # NixOS 側の systemd.user.* にしないのは、そちらだと SDDM greeter を含む
    # 全ユーザーに unit が配られるため。
    #
    # 証明書の用意を別 unit にせず ExecStartPre に置くのは、別 unit だと
    # Type=oneshot + RemainAfterExit が一度 active になったきり再実行されず、
    # 稼働中に証明書が失われたときに krdpserver だけが再起動を繰り返して
    # 復帰しないため。ExecStartPre なら再起動のたびに検証が走る。
    # 妥当なら即 exit 0 なので、繰り返しても安い。
    #
    # --address は指定しない(既定の 0.0.0.0)。以前は 127.0.0.1 に絞って SSH
    # トンネル前提にしていた。
    #
    # **PAM 認証がネットワークに出ることは受け入れている。破られると、そこから
    # NOPASSWD の sudo で root まで届く**(nixos/sudo.nix)。守りは TLS と PAM に
    # 加えて、到達範囲を送信元で絞っていること —— hosts/jupiter/default.nix の
    # networking.firewall.extraCommands が RFC1918 と Tailscale の CGNAT 範囲だけを
    # 通す。**allowedTCPPorts は使っていない**(全インタフェースで開くため)。
    #
    # --username を渡すと krdpserverrc の SystemUserEnabled が読まれなくなる。
    # --plasma を落とすと Portal 経路になり、初回接続時に画面上での許可が要る。
    systemd.user.services.krdpserver = {
      Unit = {
        Description = "KRDP server for the running Plasma session";
        After = [ "plasma-core.target" ];
        PartOf = [ "plasma-workspace.target" ];
      };
      Service = {
        Type = "exec";
        ExecStartPre = "${krdpCertScript} ${krdpCert} ${krdpCertKey}";
        ExecStart = "${pkgs.kdePackages.krdp}/bin/krdpserver --plasma";
        Restart = "on-failure";
        RestartSec = 3;
      };
      Install.WantedBy = [ "plasma-workspace.target" ];
    };

  };
}
