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

      # KRdp の設定。--address だけは krdpserverrc に対応キーが無く、渡すなら
      # unit 側のコマンドラインになるが、指定せず既定の 0.0.0.0 に bind させる
      # (理由は下の krdpserver unit のコメント参照)。
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

      # 既定ブラウザ。**KDE は xdg-mime とは別の経路で決める。**
      #
      # 実機(2026-08-23)では `xdg-settings get default-web-browser` も
      # `xdg-mime query default x-scheme-handler/https` も brave-browser.desktop を
      # 返すのに、ChatGPT Desktop からリンクを開くと Edge が起動した。KDE の
      # kioclient は kdeglobals の BrowserApplication を先に見て、未設定なら
      # ksycoca の関連付け順で選ぶ。brave と edge はどちらも .desktop を 2 つ
      # (brave-browser / com.brave.Browser、microsoft-edge / com.microsoft.Edge)
      # 持ち、InitialPreference はどれにも無いので、順位が何で決まるかは
      # 上流依存になる。**明示すれば依存しなくなる**ので明示する。
      #
      # mimeapps.list 側(XDG 経路)は home/gui/default.nix の xdg.mimeApps で
      # 宣言している。両方書くのは、どちらの経路で開かれるかがアプリ次第だから。
      configFile."kdeglobals".General.BrowserApplication = "brave-browser.desktop";

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

      # パネルを右へ。panels を宣言すると startup script が全パネルを除去して
      # 宣言どおり作り直すので、パネルで使うウィジェットはすべてここに並べる
      # 必要がある(appletsrc ファイル自体の削除は overrideConfig = true のときだけ)。
      # script は生成 JS の sha256 が前回実行時から変わったときだけ再実行される
      # (jupiter の ~/.local/share/plasma-manager/scripts/ で実測。2026-08-23)。
      # つまり GUI での追加は、宣言を変えた後の最初の Plasma セッション開始時に
      # 消える。宣言が同じ間はセッションをまたいで残り続ける。
      # kimpanel は fcitx5 の入力モード表示なので落とさない。
      panels = [
        {
          location = "right";
          widgets = [
            "org.kde.plasma.showdesktop"
            "org.kde.plasma.kickoff"
            "org.kde.plasma.pager"
            {
              # taskbar に固定するもの。並び順はこのリストの順。
              # .desktop の実名は実機で確認した(brave は brave-browser.desktop と
              # com.brave.Browser.desktop の 2 つを持つ。前者を使う)。
              #
              # 必ず applications: 形式で書く。GUI でピン留めすると
              # file:///nix/store/...-user-environment/... の絶対パスで記録され、
              # GC で旧パスが消えた時点でピンが死ぬ(wezterm を GUI で留めたら
              # この形で記録されていた。2026-08-23 実機)。Exec が絶対 store
              # パスの .desktop なら、死ぬまでの間も旧世代を起動し続ける
              # (wezterm の Exec は bare name なので PATH 解決で新世代が動く)。
              iconTasks.launchers = [
                "applications:systemsettings.desktop"
                "applications:org.kde.dolphin.desktop"
                "applications:org.wezfurlong.wezterm.desktop"
                "applications:brave-browser.desktop"
                "applications:chatgpt.desktop"
                "applications:claude-desktop.desktop"
              ];
            }
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

      # DE をまたいで共通にする入力設定: Caps→Ctrl、キーリピート
      input.keyboard = {
        options = [ "ctrl:nocaps" ];
        repeatDelay = 200;
        repeatRate = 33; # ≒ 1000ms / 30ms interval
      };

      # KDE キーバインド。GNOME 側で使っていた対応物を移植
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
    # --address は指定しない(既定の 0.0.0.0)。到達範囲は firewall 側で
    # 送信元により絞る(hosts/jupiter/default.nix)。
    #
    # **PAM 認証がネットワークに出ることは受け入れている。破られると、そこから
    # NOPASSWD の sudo で root まで届く**(nixos/sudo.nix)。守りは TLS と PAM に
    # 加えて、到達範囲を送信元で絞っていること —— hosts/jupiter/default.nix の
    # networking.firewall.extraCommands が RFC1918 と Tailscale の CGNAT 範囲だけを
    # 通す。**allowedTCPPorts は使っていない**(全インタフェースで開くため)。
    #
    # --username を渡すと krdpserverrc の SystemUserEnabled が読まれなくなる。
    #
    # **--plasma は使わない(Portal 経路を使う)。** KRdp 6.7.4 の
    # PlasmaScreencastV1Session::setClipboardData は `Q_UNUSED(data);` の空実装で、
    # clipboardDataChanged を emit するのも PortalSession だけ。つまり --plasma では
    # clipboard が両方向とも動かない(ソースで確認)。Portal 経路はテキストのみ
    # 転送する(PortalSession.cpp が「テキストだけコピーする」と明記)。
    #
    # Portal は初回接続時に画面上での許可を求める。その許可は
    # ~/.local/state/krdp-serverstaterc の restorationToken として保存され、以後は
    # 再利用されるので聞かれない。**この token は実機の前に立たなくても取れる** —
    # --plasma で動いている RDP 画面越しにダイアログを押せばよい
    # (実測 2026-08-22)。token が失効・不一致になった場合の代替は
    # xdg-desktop-portal-kde の mega-auth で、PermissionStore の
    # kde-authorized / remote-desktop に "yes" を書くとダイアログが出なくなる
    # (上流が headless 用に用意している口。remotedesktop.cpp の
    # isAppMegaAuthorized)。
    #
    # 復旧手段: krdpserver を --plasma 付きで起動し直せば、clipboard を失う
    # 代わりに許可なしで必ず動く。unit 実体は store への read-only symlink
    # なので直接編集はできない。SSH から:
    #   systemctl --user edit krdpserver
    # で drop-in を開き、次の 3 行を書いて保存する(値が空の
    # ExecStart= が既存の ExecStart を打ち消す。空行では打ち消せない):
    #   [Service]
    #   ExecStart=
    #   ExecStart=<systemctl cat krdpserver で見える現 ExecStart> --plasma
    # そのあと systemctl --user restart krdpserver
    # 恒久反映はこのファイルを直して rebuild。**drop-in は rebuild では
    # 消えない**(home-manager 管理外)ので、`systemctl --user revert
    # krdpserver` で drop-in を消してから restart する。消し忘れると
    # --plasma のまま走り続け、drop-in が固定した旧 store パスが GC された
    # 時点で unit 自体が起動しなくなる。
    #
    # ── ここから下は krdp-portal-permission unit の話 ──
    # Portal の RemoteDesktop を無人で使えるようにする。
    #
    # xdg-desktop-portal-kde は許可を出す前に PermissionStore の
    # kde-authorized / remote-desktop を引き、その app_id に "yes" があれば
    # ダイアログの分岐に入らず通知だけ出して続行する(remotedesktop.cpp の
    # isAppMegaAuthorized。上流のコメントに "Particularly useful for headless
    # setups and when the user is not physically at the machine" と書かれている、
    # そのための口)。
    #
    # **宣言で入れないと意味がない。** 手で 1 回叩く運用にすると、再インストール
    # した直後に「RDP が無いとダイアログを押せない / ダイアログを押さないと RDP が
    # 使えない」へ戻る。インストール時に自動で入る必要がある。
    #
    # app_id は org.kde.krdpserver(portal の debug ログで実測)。空文字は
    # app_id を持たないホストアプリ用の別枠なので、ここでは効かない。
    #
    # restorationToken には頼らない。実測ではダイアログを許可して保存されても
    # 次の接続の SelectDevices に載らず、載ったとしてもセッション毎に書き換わる
    # 値なので、新規インストール直後の 1 回目を無人で通す役に立たない。
    #
    # **これは「krdpserver が無確認で入力とスクリーンを掌握してよい」という許可**
    # である。RDP の口が PAM 認証で、その先が NOPASSWD の sudo であることと
    # 合わせて評価すること(nixos/sudo.nix)。
    systemd.user.services.krdp-portal-permission = {
      Unit = {
        Description = "Pre-authorize krdpserver for the RemoteDesktop portal";
        # krdpserver より先に走らせる。After=plasma-workspace.target を
        # 張ると、target が Wants する unit へ暗黙の After= が付く性質と
        # 衝突して循環になり、RDP が丸ごと起動しなくなる(実際に起きた)。
        # Before= 方向なら循環しないが krdpserver との相対順序を保証しない
        # ので、krdpserver.service へ直接張る。
        Before = [ "krdpserver.service" ];
      };
      Service = {
        Type = "oneshot";
        RemainAfterExit = true;
        # PermissionStore は D-Bus activatable なので、先に起動しておく必要はない。
        # シグネチャは sbssas (table, create, id, app, permissions)。busctl は
        # 型指定が短いと引数を配列長として読もうとして
        # "Failed to parse ... number of array entries" で落ちる。introspect で
        # 確定させてある。
        ExecStart = "${pkgs.systemd}/bin/busctl --user call org.freedesktop.impl.portal.PermissionStore /org/freedesktop/impl/portal/PermissionStore org.freedesktop.impl.portal.PermissionStore SetPermission sbssas kde-authorized true remote-desktop org.kde.krdpserver 1 yes";
      };
      Install.WantedBy = [ "plasma-workspace.target" ];
    };

    systemd.user.services.krdpserver = {
      Unit = {
        Description = "KRDP server for the running Plasma session";
        After = [ "plasma-core.target" ];
        PartOf = [ "plasma-workspace.target" ];
      };
      Service = {
        Type = "exec";
        ExecStartPre = "${krdpCertScript} ${krdpCert} ${krdpCertKey}";
        ExecStart = "${pkgs.kdePackages.krdp}/bin/krdpserver";
        Restart = "on-failure";
        RestartSec = 3;
      };
      Install.WantedBy = [ "plasma-workspace.target" ];
    };

  };
}
