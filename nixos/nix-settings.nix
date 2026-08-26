{ ... }:
{
  nix.settings = {
    experimental-features = [
      "nix-command"
      "flakes"
    ];
    trusted-users = [ "shishi" ];
  }
  // (import ../shared/nix-caches.nix).forNixSettings;
}
