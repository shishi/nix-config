{
  inputs,
  lib,
  config,
  ...
}:
let
  # DE の単一真実: この 1 変数から system 側 import と HM 側フラグを導出する
  desktop = "kde"; # ヒアリング #22 裁定
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
  ];

  networking.hostName = "jupiter";
  system.stateVersion = "25.05"; # ★Task 17 Gate 0: インストール直前にその時点の NixOS リリースへ確定(#6)

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

  # TPM2 自動解錠(systemd-cryptenroll)は systemd initrd が前提(High-5。
  # 無いと enroll しても起動時に解錠されず、遠隔無人再起動が不達)
  boot.initrd.systemd.enable = true;

  # initrd で NIC を認識させるためのドライバ。hardware-configuration.nix の
  # boot.initrd.availableKernelModules (nvme/xhci_pci/usb_storage/sd_mod) は
  # ストレージ・入力系のみで、NIC ドライバは含まれない。initrd でネットワーク
  # が要るのは下記の遠隔復旧(initrd SSH)のためで、これは NixOS の既定の
  # 想定外: nixos-generate-config が生成する availableKernelModules は
  # ストレージ・入力系が中心で、NIC ドライバは通常入らない。したがって実機で
  # hardware-configuration.nix を実物に置き換えても(インストール前ゲート 2)、
  # この宣言は自動的には得られず、実機のドライバ名をここへ追記する必要がある
  # (hardware-configuration.nix のインストール前ゲート 3 参照)。
  #
  # 実測(VM jupiter-anywhere-test, 2026-08-21):
  #   basename $(readlink /sys/class/net/enp0s3/device/driver)  # => e1000
  # この e1000 は VM の NIC のドライバであり、実機 jupiter の NIC ドライバ名は
  # 未確定。インストール時に同じ方法で確認し、実機のドライバ名をここへ追記
  # すること(既存の e1000 は消さない — availableKernelModules は「含まれて
  # いれば適用される」意味論で、余分なモジュールが含まれていても実機に害は
  # 無い。e1000 を消すと VM での検証経路(flake/checks.nix の e1000 check)が
  # 壊れる)。
  boot.initrd.availableKernelModules = [ "e1000" ];

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
  # 無く、initrd でリンクが上がっていなかったこと(NIC ドライバを追加した
  # 今回の修正で解消)。
  #
  # この「TCP 確立・banner 無し」という見え方は、VirtualBox の NAT がホスト側
  # で accept してからゲストへ転送する実装に起因する VM 固有のもの。実機で
  # NIC ドライバが欠けた場合はこの中間の accept が無いため、ARP 解決自体が
  # 失敗して接続拒否かタイムアウトになると考えられる(未確認)。
  #
  # initrd 向けに実 NIC 用の DHCP ネットワーク定義を自前で置いていない理由:
  # 実測(2026-08-21、この定義を一時的に外して
  # `nix eval .#nixosConfigurations.jupiter.config.boot.initrd.systemd.network.networks`
  # を確認)で、networking.useDHCP(既定 true。実測で有効を確認済み)由来の
  # nixpkgs デフォルト "99-ethernet-default-dhcp"(matchConfig.Type = "ether";
  # DHCP = "yes";)が既に同じ内容で initrd 側にも自動生成されていることを
  # 確認した。今回の VM 故障(initrd でリンクが上がらなかったこと)の原因は
  # NIC ドライバの欠落であり、この重複する自前定義の有無とは無関係だった。
  # 実測された故障に対応しない重複定義を残す理由が無いため、置かない。

  # これが無いと SSH で入る前に root デバイスの unit がタイムアウトし、
  # 復旧経路が「間に合わない」形で死ぬ。
  fileSystems."/".options = [ "x-systemd.device-timeout=infinity" ];

  # 自宅サーバー運用: SSH 常時 + Docker(unix socket のみ)
  services.openssh.enable = true;
  virtualisation.docker.enable = true; # ヒアリング #36

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
  users.users.shishi.extraGroups = [ "docker" ]; # non-root で docker run(受け入れゲート)

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
  # 消したぶんは home 側の krdp-lock-session.service が
  # セッション開始直後にロックして戻す。**autoLogin をここで有効にする以上、
  # あちらのロックは外せない。** 片方だけ消すと、起動もログインも RDP も
  # 成功したまま、物理アクセスに対する認証だけが 0 個になる。
  #
  # pam_kwallet はログインパスワードから鍵を導出するため autoLogin とは
  # 両立しない。KWallet はロック解除(kde PAM)のときに開く。
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
