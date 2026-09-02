{ inputs, ... }:
{
  imports = [
    inputs.home-manager.nixosModules.home-manager
    ../../nixos
    ../../nixos/optional/bootstrap-reminder.nix
    ../../nixos/optional/fonts.nix
    ../../nixos/optional/home-manager.nix
    ../../nixos/optional/wsl.nix
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
