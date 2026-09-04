# 全 NixOS ホスト共通の基盤。ここに置けるのは、サーバーを含む
# すべての NixOS ホストが同じ値で使うものだけ。
# ワークステーション向けは optional/ に置き、使うホストが名前で import する。
{ pkgs, ... }:
{
  imports = [
    ./nix-settings.nix
    ./users.nix
    ./locale.nix
    ./sudo.nix
    ./ssh.nix
  ];

  environment.systemPackages = [
    pkgs.bind.dnsutils
    pkgs.neovim
  ];

  environment.variables = {
    EDITOR = "nvim";
    VISUAL = "nvim";
  };
}
