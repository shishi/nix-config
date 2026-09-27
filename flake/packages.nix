{ ... }:
{
  perSystem =
    { pkgs, ... }:
    {
      packages = { inherit (pkgs) yaskkserv2; };
    };
}
