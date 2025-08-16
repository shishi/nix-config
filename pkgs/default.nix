# カスタムパッケージの例
{ pkgs }:

{
  # シンプルなスクリプトパッケージの例
  # my-backup = pkgs.writeShellScriptBin "my-backup" ''
  #   #!/usr/bin/env bash
  #   echo "Backup script (placeholder)"
  #   # 実際のバックアップロジックをここに追加
  # '';

  # 将来的なパッケージビルドの例
  # my-app = pkgs.stdenv.mkDerivation {
  #   pname = "my-app";
  #   version = "1.0.0";
  #   src = ./my-app-src;
  #   buildInputs = with pkgs; [ gcc ];
  # };
}
