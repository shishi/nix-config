# 開発シェルの例
{ pkgs }:

{
  default = pkgs.mkShell {
    buildInputs = with pkgs; [
      # Nix開発ツール
      nil
      nixfmt
    ];

    shellHook = ''
      echo "Welcome to Nix development shell!"
    '';
  };

  # Python開発環境の例（将来用）
  # python = pkgs.mkShell {
  #   buildInputs = with pkgs; [
  #     python3
  #     python3Packages.pip
  #     python3Packages.virtualenv
  #   ];
  # };
}
