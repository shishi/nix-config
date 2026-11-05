{ ... }:
{
  perSystem =
    { pkgs, ... }:
    {
      packages = {
        inherit (pkgs) brave yaskkserv2;
        tunnel-client = pkgs.callPackage ../pkgs/tunnel-client { };
      };
    };
}
