# libskk の StickyShift ルール定義。
# home/skk/default.nix(実配置)と flake/checks.nix(挙動検査)の両方が
# ここを参照する。定義が 2 箇所にあると検査が実物とずれるため 1 箇所へまとめる。
{ lib }:
let
  digits = lib.stringToCharacters "0123456789";

  # 数字の直後では半角のまま出したい記号。
  # rom-kana は keymap より先に引かれるため、slash を含めても
  # 単独の slash(abbrev)は壊れない(実測で確認済み)。
  keepAscii = lib.stringToCharacters "-.,:/";

  # 数字の直後に来うるその他の文字。
  # ここに無い文字が来ると libskk は保留中の数字を破棄する。
  # 記号は ASCII 印字可能な非英数字 33 種(空白を含む)から
  # keepAscii の 5 種を除いた 28 種すべて。数を数えれば漏れに気づける。
  others = lib.stringToCharacters (
    "0123456789"
    + "abcdefghijklmnopqrstuvwxyz"
    + "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
    + " +*=()[]<>?!\"'#$%&@;\\^~_|{}`"
  );

  # カタカナ・半角カナの自動導出に任せると - が半角カナの長音になりうるので、
  # 4 要素すべてを明示する。
  keepEntry =
    d: s:
    lib.nameValuePair "${d}${s}" [
      ""
      "${d}${s}"
      "${d}${s}"
      "${d}${s}"
    ];

  # 第 1 要素(持ち越し)に後続文字を置き、数字だけを確定させる。
  # 既定表の bb -> [b, っ] と同じ仕組み。
  flushEntry =
    d: f:
    lib.nameValuePair "${d}${f}" [
      f
      d
      d
      d
    ];
in
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

  # 数字の直後の記号を半角のまま出す差分テーブル(950 エントリ)。
  # 内訳: 目標記号 5 種 x 10 数字 = 50、それ以外の後続文字 90 種 x 10 数字 = 900。
  #
  # 素朴に 0- だけを定義しても動かない。libskk はトライ木のマッチに失敗すると
  # 保留中のバッファを破棄する(実測: 1,000 が 1, に、123 が 3 になる)。
  # そこで持ち越しで <数字><後続文字> を網羅し、
  # 数字を確定して後続文字を引き継ぐことを明示する。
  romKana = lib.listToAttrs (
    lib.concatMap (
      d:
      (map (keepEntry d) keepAscii)
      ++ (map (flushEntry d) (lib.filter (f: !(lib.elem f keepAscii)) others))
    ) digits
  );
}
