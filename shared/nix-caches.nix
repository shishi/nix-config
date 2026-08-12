# substituters / trusted-public-keys の唯一の真実。
# 写像もここに集約する(各消費者で手書きさせない — ドリフト防止)。
# 注意: flake.nix の nixConfig だけは Nix の制約でリテラル必須のため、
# checks.nix-caches-sync が本ファイルとの一致を機械検証する。
rec {
  substituters = [
    "https://cache.nixos.org"
    "https://nix-community.cachix.org"
    "https://cache.numtide.com"
    "https://nixpkgs-ruby.cachix.org"
  ];
  trustedPublicKeys = [
    "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
    "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
    "niks3.numtide.com-1:DTx8wZduET09hRmMtKdQDxNNthLQETkc/yaX7M4qK0g="
    "nixpkgs-ruby.cachix.org-1:vrcdi50fTolOxWCZZkw0jakOnUI1T19oYJ+PRYdK4SM="
  ];
  # HM / NixOS の nix.settings 用
  forNixSettings = {
    substituters = substituters;
    trusted-public-keys = trustedPublicKeys;
  };
}
