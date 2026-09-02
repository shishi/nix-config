{ pkgs, ... }:
{
  # フォント実体はシステム側にも置く。home/core/packages.nix 側の宣言は残す
  # (WSL ホストは NixOS の fonts モジュールを使えないため)。
  # 同一 derivation なので nix store 上は共有され、ディスクは増えない。
  # システム側に置く理由は SDDM のログイン画面など home の外で描画される箇所に効かせるため。
  fonts.packages = with pkgs; [
    noto-fonts
    noto-fonts-cjk-sans
    noto-fonts-cjk-serif
    noto-fonts-color-emoji
    udev-gothic
    udev-gothic-nf
  ];

  # 総称ファミリ(sans-serif / serif / monospace / emoji)の解決順。
  fonts.fontconfig.defaultFonts = {
    sansSerif = [
      "Noto Sans"
      "Noto Sans CJK JP"
    ];
    serif = [
      "Noto Serif"
      "Noto Serif CJK JP"
    ];
    monospace = [
      "UDEV Gothic NF"
      "Noto Sans Mono CJK JP"
    ];
    emoji = [ "Noto Color Emoji" ];
  };

  # defaultFonts は総称ファミリの解決順しか決めず、グリフ単位のフォールバックには効かない。
  # 実測(VM)では U+76F4 が Noto Sans CJK KR に落ちていた。
  # ここで CJK の地域変種をすべてのパターンへ弱く追加し、フォールバックの探索順を
  # JP > SC > TC > HK > KR に固定する。
  # binding=weak なのでアプリが明示指定したファミリより後ろに入り、
  # 英数字は Noto Sans、日本語は CJK JP という並びが保たれる。
  #
  # JP 以外の 4 つは実際にはまず到達しない。5 変種は同一の OpenType Collection
  # (NotoSansCJK-VF.otf.ttc)を共有しており、fontconfig から見た文字集合は 5 つとも
  # 完全に同一(実測: fc-query の %{charset} が一致。違うのは字形だけ)。
  # JP に無くて KR にあるグリフというものが無いので、探索は JP で終わる。
  # それでも 5 つを書き並べるのは、どの変種が選ばれるかを fontconfig の実装依存
  # (同じ文字集合を持つ候補が並んだときの順序)にしないため。順序が宣言に書いて
  # あれば、fontconfig の版が変わっても読んだとおりの優先順位が残る。
  fonts.fontconfig.localConf = ''
    <?xml version="1.0"?>
    <!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">
    <fontconfig>
      <match target="pattern">
        <edit name="family" mode="append" binding="weak">
          <string>Noto Sans CJK JP</string>
          <string>Noto Sans CJK SC</string>
          <string>Noto Sans CJK TC</string>
          <string>Noto Sans CJK HK</string>
          <string>Noto Sans CJK KR</string>
        </edit>
      </match>
    </fontconfig>
  '';
}
