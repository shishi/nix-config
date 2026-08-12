{
  description = "Personal Nix configuration: WSL Ubuntu (standalone HM) + NixOS hosts";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    neovim-nightly-overlay.url = "github:nix-community/neovim-nightly-overlay";
    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    llm-agents = {
      url = "github:numtide/llm-agents.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nix-index-database = {
      url = "github:nix-community/nix-index-database";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # ruby の供給元(パッチ単位のバージョン指定 = .ruby-version 追従に必要。
    # nixpkgs はマイナー粒度しか持たない)。
    # 意図的に nixpkgs を follows しない: 上流の pin(nixos-25.05)でビルドされた
    # 成果物のみが nixpkgs-ruby.cachix.org にあるため、follows すると全 ruby が
    # ソースビルドに落ちる。上流は安定ブランチ追跡なのでセキュリティ backport は入る。
    nixpkgs-ruby.url = "github:bobvanderlinden/nixpkgs-ruby";
    plasma-manager = {
      url = "github:nix-community/plasma-manager";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.home-manager.follows = "home-manager";
    };
    nixos-wsl = {
      url = "github:nix-community/NixOS-WSL";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nixos-anywhere = {
      url = "github:nix-community/nixos-anywhere";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  # Nix の制約で nixConfig はリテラル必須。値は shared/nix-caches.nix と
  # 同一であること(checks.nix-caches-sync が検証)。
  nixConfig = {
    extra-trusted-public-keys = [
      "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
      "niks3.numtide.com-1:DTx8wZduET09hRmMtKdQDxNNthLQETkc/yaX7M4qK0g="
      "nixpkgs-ruby.cachix.org-1:vrcdi50fTolOxWCZZkw0jakOnUI1T19oYJ+PRYdK4SM="
    ];
    extra-substituters = [
      "https://nix-community.cachix.org"
      "https://cache.numtide.com"
      "https://nixpkgs-ruby.cachix.org"
    ];
    accept-flake-config = true;
  };

  outputs =
    inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      imports = [
        ./flake
        inputs.treefmt-nix.flakeModule
      ];
      systems = [ "x86_64-linux" ];
    };
}
