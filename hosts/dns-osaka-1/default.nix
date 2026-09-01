{
  inputs,
  ...
}:
{
  imports = [
    inputs.disko.nixosModules.disko
    ../../nixos
    ./disko.nix
    ./hardware-configuration.nix
    ./oci-agent.nix
    ./secrets.nix
    ./services.nix
  ];

  networking = {
    hostName = "dns-osaka-1";
    useDHCP = true;
  };

  boot.loader = {
    grub = {
      enable = true;
      device = "nodev";
      efiSupport = true;
      efiInstallAsRemovable = true;
    };
    efi.canTouchEfiVariables = false;
  };
  boot.kernelParams = [ "console=ttyAMA0,115200n8" ];

  services.openssh = {
    enable = true;
    openFirewall = true;
    settings.PermitRootLogin = "no";
  };

  # Docker(jupiter と同じ unix socket のみ。TCP 公開はしない)
  virtualisation.docker.enable = true;

  users.users.shishi.uid = 1000;
  users.users.shishi.extraGroups = [ "docker" ]; # non-root で docker run

  system.stateVersion = "26.05";
}
