# nix develop で使える開発シェル
# プロジェクト別シェルの追加: devShells.<name> = pkgs.mkShell { ... };
{ ... }:
{
  perSystem =
    { pkgs, ... }:
    {
      devShells.default = pkgs.mkShell {
        buildInputs = with pkgs; [
          nixd
          nixfmt
        ];
      };
    };
}
