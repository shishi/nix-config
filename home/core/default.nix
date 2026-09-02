# 全ホスト共通の home 基盤。ここに置けるのは、すべての home 構成が
# 同じ値で使うものだけ(nixos/default.nix と同じ規約)。
# 並び順はリスト型設定(home.packages 等)の連結順に影響するため変更しない。
{
  imports = [
    ./packages.nix
    ./shell.nix
    ./direnv.nix
    ./nix-tools.nix
    ./rust.nix
    ./herdr.nix
  ];
}
