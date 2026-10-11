{
  description = "Personal Nix configuration: WSL Ubuntu (standalone HM) + NixOS hosts";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    # Slate の実行環境を開発用 flake.lock と揃える。アプリ本体は作業ツリーを使う。
    nixpkgs-slate.url = "github:NixOS/nixpkgs/ac6b2166e7a9375683b8e98f860f273222337b16";
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
    # 上流 CI と同じ nixpkgs pin を使い、Numtide の binary cache を利用する。
    # follows すると derivation が変わり、Codex 等が source build に落ちる。
    llm-agents.url = "github:numtide/llm-agents.nix";
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
    yaskkserv2 = {
      url = "github:wachikun/yaskkserv2/master";
      inputs.nixpkgs.follows = "nixpkgs";
    };
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
    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # Lanzaboote v1.1.0 の pin は非推奨の stdenv 属性を参照する。
    # 独立した input にして通常の flake update でも修正版を追跡する。
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    lanzaboote = {
      url = "github:nix-community/lanzaboote/v1.1.0";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.rust-overlay.follows = "rust-overlay";
    };
    # ChatGPT Desktop。OpenAI の署名済み APT metadata から version 付き .deb を
    # 固定する第三者 distribution。旧 wrapper の /latest/ URL は上流更新のたびに
    # 同じ lock が別内容を指して固定 hash と衝突したため使わない。
    # 用途を確認した Linux 拡張だけを有効にし、独自 usage reporting は
    # home/optional/gui/default.nix で無効化する。lock 更新時は、この第三者 wrapper の
    # diff と有効機能の権限・挙動を確認すること。
    codex-desktop-linux = {
      url = "github:ilysenko/codex-desktop-linux";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  # cache の信頼は .envrc の direnv allow 境界で明示的に承認する。
  # Nix の制約で nixConfig はリテラル必須。値は shared/nix-caches.nix と
  # 同一であること(checks.flake-config-boundary が検証)。
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
