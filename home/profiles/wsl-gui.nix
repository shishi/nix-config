# セッションレス GUI 環境(WSLg 等)の再利用プロファイル。
# GNOME 系パッケージと dconf は置かない(gnome-shell 不在で拡張はロード
# されず、ホットキーも成立しないことを実測済み)。
{ ... }:
{
  my.gui.enable = true;
  my.desktopSession = null;
}
