{ ... }:
{
  imports = [ ./wayland.nix ];

  services.displayManager.sddm.enable = true;
  services.desktopManager.plasma6.enable = true;
}
