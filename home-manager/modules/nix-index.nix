{
  inputs,
  ...
}:

{
  # nix-index-database が提供する homeModule を読みこむ
  # (事前ビルド済みの nix-index データベースを利用できる)
  imports = [
    inputs.nix-index-database.homeModules.nix-index
  ];

  # nix-index を有効化
  # command-not-found ハンドラを置きかえ、未インストールコマンド入力時に
  # それを含むパッケージを提示してくれる
  # 注意: home.packages に nix-index を入れると wrapper と競合するため入れない
  programs.nix-index.enable = true;

  # comma (`,`) を有効化
  # `, <command>` で未インストールのコマンドを一時的に実行できる
  programs.nix-index-database.comma.enable = true;
}
