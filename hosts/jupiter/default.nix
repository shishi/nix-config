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
    ../../nixos
    (../../nixos/desktop + "/${desktop}.nix")
    ./disko.nix
    ./hardware-configuration.nix
  ];

  networking.hostName = "jupiter";
  system.stateVersion = "25.05"; # ★Task 17 Gate 0: インストール直前にその時点の NixOS リリースへ確定(#6)

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # TPM2 自動解錠(systemd-cryptenroll)は systemd initrd が前提(High-5。
  # 無いと enroll しても起動時に解錠されず、遠隔無人再起動が不達)
  boot.initrd.systemd.enable = true;

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
