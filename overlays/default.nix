# 既存パッケージの上書き・拡張用overlay
# pkgs/ のカスタムパッケージも自動でnixpkgsに追加される
# 使い方: この {} 内にオーバーライドを追加する
#
# 主なパターン:
#   overrideAttrs:  pkg = prev.pkg.overrideAttrs (old: { ... });
#   override:       pkg = prev.pkg.override { withX = true; };
#   バージョン固定: nodejs = prev.nodejs_18;
#   ラップ:         pkg = prev.symlinkJoin { name = "pkg"; paths = [ prev.pkg ]; ... };
final: prev:
let
  customPkgs = import ../pkgs { pkgs = prev; lib = prev.lib; };
in
customPkgs
// {
}
