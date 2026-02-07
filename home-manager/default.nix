{
  config,
  pkgs,
  lib,
  ...
}:

{
  imports = [
    ./modules/options.nix
    ./modules/dconf.nix
    ./modules/direnv.nix
    ./modules/packages.nix
    ./modules/rust.nix
    ./modules/shell.nix
    ./modules/yaskkserv2.nix
  ];

  home = {
    username = "shishi";
    homeDirectory = "/home/shishi";
    stateVersion = "24.05";

    sessionVariables = {
      EDITOR = "nvim";
      VISUAL = "nvim";
      PAGER = "less";
      LESS = "-R";
    };
  };

  nix = {
    package = pkgs.nix;
    settings = {
      experimental-features = [
        "nix-command"
        "flakes"
      ];
      trusted-users = [ "shishi" ];
      # バイナリキャッシュの設定はflake.nixのnixConfigと同じものを使用
      # これによりシステム全体で同じキャッシュが使用される
      substituters = [
        "https://cache.nixos.org"
        "https://nix-community.cachix.org"
      ];
      trusted-public-keys = [
        "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
        "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
      ];
    };
  };

  programs.home-manager.enable = true;
}
