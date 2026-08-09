{
  inputs,
  pkgs,
  ...
}:
{
  # nix 専用ドメインの集約。
  # programs.nh は standalone ホスト専用のため hosts/ubuntu-wsl 側で有効化する
  # (統合 NixOS ホストで HM 側 nh を有効にすると nh home switch が
  #  system 世代の外に home 世代を作る第 2 経路になるため)。
  imports = [ inputs.nix-index-database.homeModules.nix-index ];

  programs.nix-index.enable = true;
  programs.nix-index-database.comma.enable = true;

  home.packages = with pkgs; [
    nix-output-monitor
    nix-search-cli
    nix-update
    nixd
    nixfmt
  ];

  nix = {
    package = pkgs.nix;
    settings = {
      experimental-features = [
        "nix-command"
        "flakes"
      ];
      trusted-users = [ "shishi" ];
    }
    // (import ../../shared/nix-caches.nix).forNixSettings;
  };
}
