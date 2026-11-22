{ inputs, ... }:
{
  perSystem =
    { pkgs, ... }:
    {
      packages = {
        inherit (pkgs) brave yaskkserv2;
        heeler-host-helper = pkgs.callPackage ../pkgs/heeler-host-helper { src = inputs.heeler; };
        tunnel-client = pkgs.callPackage ../pkgs/tunnel-client { };
      };
    };
}
