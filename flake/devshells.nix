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
          gnugrep
          gnupg
          jq
          nixd
          nixfmt
          openssh
          sops
          util-linux
        ];
      };
    };
}
