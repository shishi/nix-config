{ inputs, ... }:
{
  imports = [
    inputs.home-manager.nixosModules.home-manager
    ../../nixos
    ../../nixos/bootstrap-reminder.nix
    ../../nixos/fonts.nix
    ../../nixos/home-manager.nix
    ../../nixos/wsl.nix
  ];
  networking.hostName = "nixos-wsl";
  system.stateVersion = "25.05";

  home-manager = {
    useGlobalPkgs = true;
    useUserPackages = true;
    extraSpecialArgs = { inherit inputs; };
    users.shishi.imports = [ ../../home ]; # gui=false / desktopSession=null(既定)
  };
}
