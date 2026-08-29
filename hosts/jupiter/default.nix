{
  inputs,
  lib,
  config,
  ...
}:
let
  # DE の単一真実: この 1 変数から system 側 import と HM 側フラグを導出する
  desktop = "kde";
in
{
  imports = [
    inputs.disko.nixosModules.disko
    inputs.home-manager.nixosModules.home-manager
    inputs.lanzaboote.nixosModules.lanzaboote
    ../../nixos
    (../../nixos/desktop + "/${desktop}.nix")
    ../../nixos/input-method.nix
    ./disko.nix
    ./hardware-configuration.nix
    ./secrets.nix
  ];

  networking.hostName = "jupiter";
  system.stateVersion = "25.05"; # インストール時のリリース。以後は変更しない

  # lanzaboote が UKI を署名して systemd-boot を置き換える。
  # 鍵の生成と Setup Mode での enroll は宣言できないので runbook 側で行う
  # (docs/jupiter-secure-boot-runbook.md)。
  boot.loader.systemd-boot.enable = lib.mkForce false;
  boot.lanzaboote = {
    enable = true;
    # v1.0.0 以降 externalPath 型。Nix store パスを受け付けない。
    pkiBundle = "/var/lib/sbctl";
  };
  boot.loader.efi.canTouchEfiVariables = true;

  # Minisforum V3 の eDP パネルでは amdgpu の EDID 由来 custom brightness
  # curve が高輝度域を実際より暗くする。曲線を無効化して、パネルの
  # バックライト値を線形に扱う。
  boot.kernelParams = [ "amdgpu.dcdebugmask=0x40000" ];

  # Wi-Fi と USB Ethernet の併用時に、別インターフェースの IPv4 アドレスで
  # ARP 応答・通知して経路が揺れる ARP flux を防ぐ。
  boot.kernel.sysctl = {
    "net.ipv4.conf.all.arp_ignore" = 1;
    "net.ipv4.conf.default.arp_ignore" = 1;
    "net.ipv4.conf.all.arp_announce" = 2;
    "net.ipv4.conf.default.arp_announce" = 2;
  };

  # TPM2 自動解錠(systemd-cryptenroll)は systemd initrd が前提。
  # 無いと enroll しても起動時に解錠されず、遠隔無人再起動が不達になる
  boot.initrd.systemd.enable = true;

  # initrd で NIC を認識させるためのドライバ。nixos-generate-config が生成する
  # availableKernelModules はストレージ・入力系が中心で NIC ドライバを含まない
  # ため、hardware-configuration.nix を実機の実物にしても、ここは自動では
  # 得られない。だから手で宣言する。
  #
  # USB イーサのホストコントローラ(xhci_pci)は hardware-configuration.nix 側
  # から来る。再生成して置き換えたときは、それが残っていることを確認すること。
  #
  # **実機に有線 LAN ポートは無い**(Minisforum V3)。内蔵は Intel AX210 の
  # 無線のみで、initrd に無線を入れると wpa_supplicant と資格情報を initrd へ
  # 持ち込むことになる。そこまではしない。
  #
  # 代わりに **USB イーサネットアダプタを挿しっぱなしにする**前提を採る。
  # 「復旧が要るときに挿す」は成立しない — 復旧が要るのは TPM 解錠に失敗して
  # 遠隔にいるときで、その瞬間に挿す手はそこに無い。挿さっていなければ
  # initrd のリンクは上がらず、復旧手段は物理コンソールだけになる。
  #
  # アダプタの型番は固定しない。availableKernelModules は「含まれていれば
  # そのハードがあるとき適用される」意味論なので、よく使われるチップの集合を
  # 入れておく。**全部を覆ってはいない。** 足りないと遠隔復旧が静かに使えず、
  # それが分かるのは障害の最中である。余分に入っていても initrd が数 KB
  # 増えるだけで害は無い。実際に使うアダプタのドライバ名は
  #   basename $(readlink /sys/class/net/<iface>/device/driver)
  # で確認し、ここに無ければ追記する。
  #
  # e1000 は VM リハーサル用。消すと flake/checks.nix の boot-contract が落ちる。
  boot.initrd.availableKernelModules = [
    "e1000"
    "usbnet"
    "asix"
    "ax88179_178a"
    "r8152"
    "r8153_ecm"
    "cdc_ether"
    "cdc_ncm"
    "smsc95xx"
    "aqc111"
  ];

  # TPM 自動解錠が失敗したときの遠隔復旧。これが無いと、systemd initrd を
  # 入れた理由(遠隔無人再起動)が TPM の失敗でそのまま失われる。
  #
  # initrd.network.enable が無いと ssh.enable は no-op になる(nixpkgs の
  # initrd-ssh.nix が両方を要求する)。
  boot.initrd.network.enable = true;
  boot.initrd.network.ssh = {
    enable = true;
    # 本体 sshd と区別する。initrd 側だと分かった上で繋ぐため。
    port = 2222;
    # 鍵はマシン上で生成する。public repo なので実体をコミットしない。
    hostKeys = [ "/var/lib/initrd-ssh/ssh_host_ed25519_key" ];
    # cryptsetup-askpass は systemd initrd に存在せず、指定するとアサーションで
    # 失敗する。systemctl default が systemd-tty-ask-password-agent を fork する。
    #
    # 本体の authorizedKeys を流用して command= だけ足す。鍵をここに書き写すと、
    # 差し替えたとき片方だけ直して initrd から締め出される。
    authorizedKeys = map (
      k: ''command="systemctl default" ${k}''
    ) config.users.users.shishi.openssh.authorizedKeys.keys;
  };

  # 実測(VM, 2026-08-21): TPM 解錠を失敗させて initrd SSH を試したところ、
  # TCP は確立するのに banner が一切返らなかった。initrd の journal を見ると、
  # 上げていたのは lo だけで実 NIC (VM では enp0s3) は一度も構成されず DHCP も
  # 走っていなかった。sshd 自体は健全で 3 分間 listening していたが、ゲストに
  # IP が無いため VirtualBox の NAT がホスト側で accept した TCP をゲストへ
  # 届けられなかった。根本原因は上記 availableKernelModules に NIC ドライバが
  # 無く、initrd でリンクが上がっていなかったこと(availableKernelModules
  # への NIC ドライバ追加で解消)。
  #
  # この「TCP 確立・banner 無し」という見え方は、VirtualBox の NAT がホスト側
  # で accept してからゲストへ転送する実装に起因する VM 固有のもの。実機で
  # NIC ドライバが欠けた場合はこの中間の accept が無いため、ARP 解決自体が
  # 失敗して接続拒否かタイムアウトになると考えられる(未確認)。
  #
  # initrd 向けの DHCP 定義。**自前で置かないと IP が来ない。**
  #
  # 以前はこれを置いていなかった。networking.useDHCP(既定 true)由来の
  # nixpkgs デフォルト "99-ethernet-default-dhcp" が initrd 側にも自動生成
  # されるので任せられたため。networking.networkmanager.enable = true は
  # useDHCP を false にするので、その生成が止まる。
  #
  # 実測: NM 有効で
  # `nix eval .#nixosConfigurations.jupiter.config.boot.initrd.systemd.network.networks`
  # が `{}` になり、NM を mkForce false に戻すと
  # ["99-ethernet-default-dhcp" "99-wireless-client-dhcp"] が返る。
  #
  # 定義が無いと、ドライバが入っていてリンクが上がり sshd が listen していても
  # アドレスが付かない。外形は「NIC ドライバ欠落」のときと同じなので、
  # ドライバを足したことで切り分けが逆方向へ誘導される。
  #
  # 無線側(99-wireless-client-dhcp 相当)は置かない。initrd に
  # wpa_supplicant と資格情報を持ち込まない以上、一致しても接続できない。
  #
  # **この matchConfig に Name や Driver の制約を足さないこと。** [Match] は
  # AND なので、足すとマッチが狭まる。USB イーサは MAC がローカル管理アドレスだと
  # `enx…` ではなく `usb0` のままになることがあり、`en*` 系の制約から外れる。
  # boot-contract は Type と DHCP の値しか見ないので、この形は検出できない。
  #
  # 名前と中身は nixpkgs の既定と同じにする。Kind = "!*" は仮想インタフェース
  # (bridge / veth など)を除外する指定で、上流の定義に含まれている(実測:
  # NM を mkForce false に戻すと matchConfig が {Kind = "!*"; Type = "ether";})。
  # 同名なので、将来 useDHCP が true へ戻っても衝突せずマージされる。
  boot.initrd.systemd.network.networks."99-ethernet-default-dhcp" = {
    matchConfig = {
      Type = "ether";
      Kind = "!*";
    };
    networkConfig.DHCP = "yes";
  };

  # これが無いと SSH で入る前に root デバイスの unit がタイムアウトし、
  # 復旧経路が「間に合わない」形で死ぬ。
  fileSystems."/".options = [ "x-systemd.device-timeout=infinity" ];

  # **この機体に有線 LAN ポートは無い。** NetworkManager を入れないと、
  # 無線を AP へ接続させるものが誰も居らず、DHCP 以前にリンクが上がらない
  # (dhcpcd だけでは無線は繋がらない)。SSH も RDP も届かないので、
  # ここまでの構成すべてがこれに依存している。
  #
  # 有効化すると networking.useDHCP は false になり、
  # networking.wireless(wpa_supplicant)は NetworkManager 側が立てる。
  # Plasma の接続 UI(plasma-nm)は plasma6 module が既に入れている。
  #
  # 資格情報は NetworkManager が /etc/NetworkManager/system-connections/ に持つ。
  # public repo にも --extra-files にも出さない。コンソールで一度接続するだけ。
  # nixos/users.nix が shishi を networkmanager グループへ入れているのは
  # この宣言と対になっている。
  networking.networkmanager.enable = true;

  # 自宅サーバー運用: SSH 常時 + Docker(unix socket のみ)
  services.openssh.enable = true;
  virtualisation.docker.enable = true;

  # FHS 非互換の prebuilt バイナリへの備え。x86_64 glibc の prebuilt ELF は
  # /lib64/ld-linux-x86-64.so.2 を interpreter に持ち、NixOS にはそれが無いため
  # 「存在するのに No such file or directory」で落ちる。nix-ld はその位置に
  # 自身を置いて解決する。特定の消費者に紐づけず入れる。
  #
  # **外している側**: NixOS の既定は「interpreter が無い」ことで Nix 管理外の
  # 動的リンク ELF を事実上実行できなくしている。これを host 全体・全ユーザーに
  # 対して恒久的に外す。この host は常時 sshd を上げ、docker group のユーザーが
  # いる。攻撃面の評価をやり直すときはこの行から始める。
  #
  # **適用範囲は jupiter だけ**。standalone の home-manager 構成には効かない
  # (NixOS の option なので)。
  #
  # 32bit (/lib/ld-linux.so.2) と musl (/lib/ld-musl-*.so.1) は対象外。
  # environment.ldso32 は null のまま(実測)。同じ症状が出ても原因は別。
  #
  # 何が入るか (option 既定値・module 側の代入・listOf のマージ) は nixpkgs の版に
  # 依存する。追加のライブラリが要る事態になったら、その時点の実物を測ってから
  # programs.nix-ld.libraries を足す。
  programs.nix-ld.enable = true;
  users.users.shishi.extraGroups = [ "docker" ]; # non-root で docker run

  # Steam。unfree なので flake/default.nix の allowUnfree = true が前提。
  #
  # この 1 行が連れてくるもの(すべて eval で確認):
  # - steam と steam-run(FHS 環境。NixOS では Steam 自身が FHS を要求する)
  # - hardware.graphics.enable32Bit = true。32bit のゲームと Proton に要る。
  #   明示しなくても module 側が立てる
  # - hardware.steam-hardware.enable = true。コントローラ用の udev ルール
  #
  # **Steam は firewall の口を増やさない。** remotePlay / dedicatedServer /
  # localNetworkGameTransfers の openFirewall はいずれも既定 false(eval で確認)。
  # allowedTCPPorts は 22 だけで、これは services.openssh 由来。3389 は下の RDP の
  # 宣言で開けているが、Steam とは無関係。Remote Play や LAN 転送を使う段になったら、
  # そのとき明示的に開ける。
  #
  # 32bit の Vulkan ICD(radeon_icd.i686.json)は enable32Bit だけで入る。
  # hardware.graphics.extraPackages32 は要らない。ここが欠けると 64bit の
  # タイトルは動くのに 32bit タイトルだけが Vulkan デバイス 0 個で落ちる、
  # という切り分けにくい壊れ方をするので実際に見て確かめてある。
  #
  # 音声は plasma6 が立てる pipewire に乗る(alsa / pulse の互換も有効)。
  # Steam 側は音声について何も設定しない。
  #
  # gamescope と gamemode は入れない。option としては存在するが、
  # 要るという根拠がまだ無い。必要になってから測って足す。
  #
  # **未検証: ゲームが実際に動くこと。** VM には GPU が無いので、確かめてあるのは
  # ビルドとバイナリの存在とドライバの配置までである。実機で最初に見るのは
  # RADV が出るか(Ryzen 8840U の iGPU)。vulkan-tools は入れていないので
  # 一時的に持ってくる。**`nix run` では起動しない** — このパッケージは
  # bin/vulkan-tools を持たないため、引数から vulkaninfo は選ばれない。
  #
  #   nix shell nixpkgs#vulkan-tools -c vulkaninfo --summary

  # RDP。krdpserver は 0.0.0.0 に bind するので、到達範囲はここで決まる。
  #
  # 全インタフェースでは開かず、Tailscale の認証済み通信だけを通す。
  # 3389 への到達主体は tailnet 側の通信ポリシーで管理する。
  #
  # **この口の先には PAM 認証があり、その先は NOPASSWD の sudo がある**
  # (nixos/sudo.nix)。PAM を破られると追加認証なしで root まで届く。
  # 到達範囲を絞っているのはそのため。
  services.tailscale.enable = true;
  networking.firewall.interfaces.tailscale0.allowedTCPPorts = [ 3389 ];

  # Bluetooth。AX210 に内蔵されていて、カーネルは起動時に hci0 として認識し
  # Intel のファームウェア(intel/ibt-0041-0041.sfi)も読み込み済み。有効化して
  # いなかったのは宣言が無かったからで、ハードの問題ではない(実測)。
  # KDE 側の UI は plasma6 が bluedevil を入れるので追加の宣言は要らない。
  hardware.bluetooth.enable = true;

  # ── 生体認証: 顔(Howdy)+ 指紋(fprintd)──────────────────────
  #
  # ハード(実測 2026-08-23):
  # - IR カメラ = /dev/video2(Kingcome UVC 2b7e:c705 の interface 1.2。
  #   GREY 8-bit 640x360)。services.howdy の device_path 既定と一致するので
  #   settings は既定のまま使う。
  # - 指紋 = Goodix 27c6:6092。libfprint の goodixmoc(match-on-chip)が対応
  #   (libfprint の hwdb に usb:v27C6p6092 が載っていることを確認)。
  #
  # 効く先はロック画面と polkit の認証ダイアログ。SDDM は autoLogin なので
  # 実質出番が無い。sudo は NOPASSWD が auth フェーズを飛ばすため効かない
  # (account/session フェーズは通るので「PAM 全体が無関係」ではない。効かせる
  # 場合の手順は nixos/sudo.nix の選択肢 (d) に記録してある)。
  #
  # ロック画面の PAM 配線(生成される text を nix eval で確認済み 2026-08-23):
  # - "kde"(パスワード経路)= howdy(11500)→ pam_unix。指紋は乗らない。
  #   howdy の顔スキャン(timeout 4 秒 = settings.video.timeout の既定値。
  #   nixpkgs モジュール定義で確認)が
  #   パスワード照合の前に直列で入るため、実機の前に誰もいない RDP からの
  #   解除は最大 4 秒待ってからパスワードが照合される。
  # - "kde-fingerprint"(fprintd 11400 → howdy 11500 → pam_unix)は
  #   kscreenlocker がパスワード経路と並行して使う指紋専用の別サービスで、
  #   指紋待ちがパスワード入力を塞ぐことはない。
  #
  # control = "sufficient": 既定の "required"(nixpkgs モジュール定義で確認)は
  # 「顔 AND パスワード」の
  # 2 要素になる。sufficient なら顔・指紋のどれか 1 つで通り、失敗すれば
  # パスワードに落ちる。上流の注意書きどおり顔認証は写真で騙されうるが、
  # このカメラは IR(可視光の印刷物が写らない)であり、受け入れる。
  #
  # 顔モデルは /var/lib/howdy/models(nixpkgs がパッチ済み)、指紋は
  # /var/lib/fprint に保存される。生体データなので repo には入れない =
  # 再インストール後は登録し直す。登録は本人が実機の前で 1 回:
  #   sudo linux-enable-ir-emitter configure   # IR エミッタの点灯設定(対話)
  #   sudo howdy add                           # 顔の登録
  #   fprintd-enroll                           # 指紋の登録
  services.howdy = {
    enable = true;
    control = "sufficient";
  };
  # 別の USB カメラ類を挿したまま起動すると /dev/videoN の番号はずれうる。
  # 症状(顔認証が常時失敗し、各認証点に 4 秒待ちだけ残る)が出たら
  # services.howdy.settings.video.device_path に /dev/v4l/by-id/ の安定パスを
  # 指定する。
  services.linux-enable-ir-emitter.enable = true; # device 既定 "video2" が実機と一致
  services.fprintd.enable = true;

  # krdp(RDP)は PAM サービス "login" を使う(journal の
  # pam_unix(login:account): setuid failed が krdp 由来であることを実測)。
  # login に howdy と fprintd が乗ると、RDP 接続のたびに顔スキャン(上記の
  # 4 秒)と指紋待ちを直列で消化してからパスワード照合へ進み、
  # 接続が遅くなるだけなので外す。TTY ログインも巻き添えで生体認証なしに
  # なるが、使っていないので許容。SSH は鍵認証で PAM の auth スタックを
  # 通らないため元から影響しない。
  security.pam.services.login.howdy.enable = false;
  security.pam.services.login.fprintAuth = false;

  programs.steam.enable = true;

  # pipewire は plasma6 が既に立てているが、rtkit が無いとリアルタイム優先度を
  # 取れない。負荷が高いときに音が途切れる側に倒れる。増えるのは
  # rtkit-daemon 1 本で、polkit は既に有効、firewall の口も増えない。
  security.rtkit.enable = true;

  # 初回インストールで nixos-anywhere --extra-files に渡した鍵は、tar が
  # --no-same-owner で展開されるため所有者が root になる(mode だけが保存される)。
  # ユーザーの存在有無とは無関係で、--chown home/shishi <uid>:<gid> で直すしかない。
  # その <uid> を宣言しないと activation が動的に割り当てるため、手順に書く数字を
  # 構成の側から裏付けられない。ずれた場合の症状は 2 通りで紛らわしい:
  # uid がずれると鍵は「uid 1000」(= shishi ではない id)の所有になり shishi から
  # 読めない。home がずれると chown が宛先を外し、鍵は root 所有のまま別の場所に
  # 残る。どちらかを確かめるには ls -ln で数値 id を見る。
  # 共有モジュール側に置かないのは、nixos-wsl も ../../nixos を読むため。
  users.users.shishi.uid = 1000;

  # 初回ログイン用のパスワード。値は repo に置かず、SSH / GPG 鍵と同じ
  # nixos-anywhere --extra-files の経路でインストール時に置く。
  #
  # mutableUsers = true なので、これが効くのはユーザーが新規に作られるときだけで、
  # 以後 passwd で変えた値は switch しても戻らない(update-users-groups.pl が
  # 既存ユーザーの shadow を上書きするのは mutableUsers = false のときだけ)。
  # つまり initialPassword と同じ役割で、値だけが public repo から出る。
  #
  # ファイルが無いと activation は警告を出して続行し、新規に作られた
  # ユーザーの shadow は `!` になる(実測: passwd -S が L)。既知の文字列が
  # 残るよりは安全側だが、**どのパスワードも通らないので autoLogin で上がった
  # セッションのロックを解除できず、コンソールからも入れない**。
  # 復旧は SSH 鍵で入って `sudo passwd shishi`(sudo.nix によりパスワード不要)。
  # 手順書との対応は flake/checks.nix の install-keys-contract が固定する。
  users.users.shishi.hashedPasswordFile = "/var/lib/secrets/shishi-password-hash";

  # KRdp は動作中の KWin セッションに寄生するため、セッションが無い時間帯は
  # 遠隔から入れない。この機体は常にモニタを持つノート PC 型なので、
  # 画面を常時立ち上げたままにして遠隔の入口を確保する。
  #
  # **外している側**: LUKS が TPM で自動解錠される構成では、SDDM のログイン画面が
  # 起動後に残る唯一の資格情報要求点である。autoLogin はそれを消すため、
  # 持ち出された機体は電源を入れるだけでデスクトップが出ることになる。
  # 消したぶんは home 側の programs.plasma.kscreenlocker の
  # lockOnStartup と passwordRequired が戻す。**autoLogin をここで有効にする
  # 以上、あちらは外せない。** 片方だけ消すと、起動もログインも RDP も
  # 成功したまま、物理アクセスに対する認証だけが 0 個になる。
  #
  # **この対は check で固定していない。** autoLogin を触るときは手で両方を見る。
  # ロックが掛からなかったことは systemd にも journal にも残らないので、
  # 気づく手段は画面を見るか、`busctl --user call org.kde.screensaver
  # /ScreenSaver org.freedesktop.ScreenSaver GetActive` を叩くことだけである。
  #
  # pam_kwallet はログインパスワードから鍵を導出するため autoLogin とは
  # 両立しない。セッション開始直後の kwalletd6 はバス上で activatable のまま
  # である(実測)。ロック解除で開くかどうかは測っていない。
  services.displayManager.autoLogin = {
    enable = true;
    user = "shishi";
  };

  # RDP から見えているのは autoLogin で上がったセッションであり、そこで
  # ログアウトすると krdpserver も一緒に落ちる(PartOf=plasma-workspace.target)。
  # relogin が偽だと SDDM はグリーターで止まり、遠隔からは二度と入れない。
  # 「ログアウトしないこと」を手順で守らせる代わりに、構成で戻す。
  services.displayManager.sddm.autoLogin.relogin = true;

  # nh の 2 層配線契約: 統合ホストは NixOS 側 programs.nh を使う
  # (HM 側 programs.nh は standalone 専用 — nh home の第 2 適用経路防止)
  programs.nh = {
    enable = true;
    flake = "/home/shishi/dev/src/github.com/shishi/nix-config";
    clean = {
      enable = true;
      dates = "weekly";
      extraArgs = "--keep 5 --keep-since 4d";
    };
  };

  home-manager = {
    useGlobalPkgs = true;
    useUserPackages = true;
    # 共有 home/ は inputs に依存(nix-index-database 等)— 渡し忘れは即ビルド失敗
    extraSpecialArgs = { inherit inputs; };
    users.shishi = {
      imports = [ ../../home ];
      my.desktopSession = desktop;
      my.skk.enable = true;
      my.shell = "fish";
    };
  };

  # DE 不一致の防御(単一真実からの導出が壊された場合に備える)
  assertions = [
    {
      assertion = config.home-manager.users.shishi.my.desktopSession == desktop;
      message = "jupiter: HM desktopSession must match the host desktop variable";
    }
  ];
}
