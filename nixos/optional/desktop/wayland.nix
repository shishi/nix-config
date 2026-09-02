# Wayland セッション共通の設定(gnome.nix / kde.nix の両方から import する)。
#
# Electron / Chromium 系は既定で X11 バックエンドを選ぶため、Wayland セッションでは
# XWayland 経由で動く。その経路の入力メソッドは GTK_IM_MODULE / QT_IM_MODULE に
# 依存するが、input-method.nix の waylandFrontend = true でこれらは設定していない
# (Wayland ネイティブのアプリでは併用すると候補ウィンドウが点滅するため)。
# 結果として Electron アプリだけ日本語入力が効かなくなる。
# VM リハーサルでの実測: Brave では Ctrl+Space が fcitx5 に届かず、続く Ctrl+J が
# ブラウザのショートカット(ダウンロード)として処理され、ローマ字がそのまま入った。
# 同じ操作を KWrite(Qt6 ネイティブ Wayland)で行うと変換まで通る。
#
# NIXOS_OZONE_WL は nixpkgs の Electron ラッパーが読み、Wayland バックエンドを
# 選ばせる。これでコンポジタの text-input プロトコル経由の入力に載る。
{ ... }:
{
  environment.sessionVariables.NIXOS_OZONE_WL = "1";
}
