# 既存パッケージの上書き・拡張用 overlay。pkgs/ のカスタムパッケージを注入する
final: prev: import ../pkgs { pkgs = prev; }
