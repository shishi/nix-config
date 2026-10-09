{ ... }:
{
  perSystem =
    { pkgs, ... }:
    {
      packages = {
        inherit (pkgs) yaskkserv2;
        tunnel-client = pkgs.callPackage ../pkgs/tunnel-client { };
      };
    };
}
