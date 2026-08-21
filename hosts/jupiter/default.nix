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
  # 届けられなかった。
  #
  # boot.initrd.network.enable は sshd を initrd で起動するだけで、systemd
  # initrd 自身にリンクを上げさせるわけではない(networkd はもう動いている
  # が、マッチする networks 定義が無ければ何もしない)。ここで実 NIC 向けの
  # DHCP 定義を明示的に置く。
  #
  # インターフェース名は書かない: この定義は VM (enp0s3) と実機 jupiter
  # (NIC 名は未確定) の両方で動く必要があり、かつ public repo なのでマシン
  # 固有情報を残さない方針がある。有線イーサネット全般に当たる
  # matchConfig.Type = "ether" を使う(nixpkgs 自身の
  # networking.useDHCP 由来のデフォルト網定義 "99-ethernet-default-dhcp" も
  # 同じ Type = "ether" で当てている)。
  #
  # networking.useDHCP (既定 true) が有効な間は、その nixpkgs デフォルトが
  # 実は initrd 側にも同じ内容を自動生成している。しかし本体側の
  # networking.useDHCP が将来(例: desktop 側で NetworkManager へ切替)
  # false になると、そのデフォルトは initrd からも一緒に消え、この遠隔復旧
  # 経路だけが誰も意図せず連動して死ぬ。ここで明示的に定義し、その依存を切る。
  boot.initrd.systemd.network.networks."30-initrd-remote-recovery-ethernet-dhcp" = {
    matchConfig.Type = "ether";
    DHCP = "yes";
  };

  # これが無いと SSH で入る前に root デバイスの unit がタイムアウトし、
  # 復旧経路が「間に合わない」形で死ぬ。
  fileSystems."/".options = [ "x-systemd.device-timeout=infinity" ];

  # 自宅サーバー運用: SSH 常時 + Docker(unix socket のみ)
  services.openssh.enable = true;
  virtualisation.docker.enable = true; # ヒアリング #36
  users.users.shishi.extraGroups = [ "docker" ]; # non-root で docker run(受け入れゲート)

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
