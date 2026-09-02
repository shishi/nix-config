{ ... }:
{
  imports = [ ./wayland.nix ];

  services.displayManager.gdm.enable = true;
  services.desktopManager.gnome.enable = true;
}
