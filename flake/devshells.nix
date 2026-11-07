{ ... }:
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
    };
}
