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

  users.users.shishi.uid = 1000;

  system.stateVersion = "26.05";
}
