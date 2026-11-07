# substituters / trusted-public-keys の唯一の真実。
# 写像もここに集約する(各消費者で手書きさせない — ドリフト防止)。
# flake.nix の nixConfig はリテラル必須のため、
# checks.flake-config-boundary が本ファイルとの一致を検証する。
rec {
  ownSubstituter = "https://nix-cache.srevo.net";
  substituters = [
    "https://cache.nixos.org"
    "https://nix-community.cachix.org"
    "https://cache.numtide.com"
    ownSubstituter
    "https://nixpkgs-ruby.cachix.org"
  ];
  upstreamSubstituters = builtins.filter (url: url != ownSubstituter) substituters;
  trustedPublicKeys = [
    "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
    "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
    "niks3.numtide.com-1:DTx8wZduET09hRmMtKdQDxNNthLQETkc/yaX7M4qK0g="
    "nix-config-r2-1:0les2BkGLxYR8j0F3TazVPs2N0ki/SX9wb8Vdeny4+s="
    "nixpkgs-ruby.cachix.org-1:vrcdi50fTolOxWCZZkw0jakOnUI1T19oYJ+PRYdK4SM="
  ];
  # HM / NixOS の nix.settings 用
  forNixSettings = {
    always-allow-substitutes = true;
    substituters = substituters;
    trusted-public-keys = trustedPublicKeys;
  };
}
