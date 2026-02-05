# カスタムパッケージの定義
# nix-update で自動更新するために、ここに全パッケージを集約する
#
# 使い方:
# - 新しいパッケージは pkgs/<name>/default.nix に作成
# - このファイルに追加すれば自動で overlays と packages output に公開される
# - nix run .#update で自動更新される
{
  pkgs,
  lib,
}:

{
  git-wt = pkgs.callPackage ./git-wt { };

  # 新しいパッケージを追加する例:
  # my-tool = pkgs.callPackage ./my-tool { };
}
