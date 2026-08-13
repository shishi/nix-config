# neovim は移行期のため desktop entry を 2 つ同梱する:
#   nvim.desktop(旧来名)と org.neovim.nvim.desktop(freedesktop の reverse-DNS 規約)
# 中身は Name/Exec とも同一で NoDisplay も無いため、KDE のメニューに 2 個並ぶ。
# 新しい規約側を残して旧来名を落とす。
#
# この overlay は flake/default.nix で neovim-nightly-overlay の後ろに置く。
# 前に置くと nightly overlay が neovim-unwrapped を再定義して上書きが消える。
let
  dropLegacyEntry =
    drv:
    drv.overrideAttrs (old: {
      postInstall = (old.postInstall or "") + ''
        rm -f "$out/share/applications/nvim.desktop"
      '';
    });
in
final: prev: {
  neovim-unwrapped = dropLegacyEntry prev.neovim-unwrapped;

  # home/core/packages.nix が入れるのは neovim の方なので、こちらにも被せないと
  # メニューの重複は消えない。実測では nightly overlay の neovim は
  # neovim-unwrapped と同一 derivation(同一 store path)なので、
  # 同じ override をかけても新しい派生は増えない。
  #
  # `neovim = final.neovim-unwrapped;` と別名で潰さないのは、将来 upstream が
  # neovim を本物のラッパへ変えたとき、黙ってラッパを剥がしてしまうため。
  # overrideAttrs なら同じ状況で rm が空振りするだけで、メニューに 2 個並ぶという
  # 目に見える形で気づける。
  neovim = dropLegacyEntry prev.neovim;
}
