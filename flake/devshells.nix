{ inputs, ... }:
let
  mkCacheShell =
    pkgs:
    pkgs.mkShellNoCC {
      packages = [ (pkgs.python3.withPackages (ps: [ ps.boto3 ])) ];
    };
in
{
  perSystem =
    { pkgs, ... }:
    {
      devShells.default = pkgs.mkShell {
        buildInputs = with pkgs; [
          age
          coreutils
          findutils
          git
          gh
          gnugrep
          gnupg
          jq
          nixd
          nixfmt
          openssh
          (python3.withPackages (ps: [ ps.boto3 ]))
          sops
          util-linux
        ];
      };
      devShells.cache = mkCacheShell pkgs;
    };
  flake.devShells.aarch64-linux.cache = mkCacheShell (
    import inputs.nixpkgs { system = "aarch64-linux"; }
  );
}
