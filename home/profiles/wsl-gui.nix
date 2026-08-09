# セッションレス GUI 環境(WSLg 等)の再利用プロファイル。
# GNOME 系 4 パッケージと dconf は #21 裁定(2026-08-09)で削除確定
# (gnome-shell 不在で拡張ロード不能・ホットキー不成立の実測に基づく承認済み差分)。
{ ... }:
{
  my.gui.enable = true;
  my.desktopSession = null;
}
