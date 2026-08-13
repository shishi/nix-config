# libskk の StickyShift ルール定義。
# home/skk/default.nix(実配置)と flake/checks.nix(挙動検査)の両方が
# ここを参照する。定義が 2 箇所にあると検査が実物とずれるため 1 箇所へまとめる。
{ lib }:
{
  metadata = {
    name = "Sticky Shift";
    description = "Enable Sticky Shift";
  };

  # セミコロンで変換を開始する(Shift を押しっぱなしにしない)。
  keymapHiragana = {
    include = [ "default/hiragana" ];
    define.keymap.";" = "start-preedit-no-delete";
  };

  keymapKatakana = {
    include = [ "default/katakana" ];
    define.keymap.";" = "start-preedit-no-delete";
  };
}
