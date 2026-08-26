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
    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    lanzaboote = {
      url = "github:nix-community/lanzaboote/v1.1.0";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # ChatGPT Desktop。取ってくる .deb は OpenAI 配布の公式ビルドだが、
    # **この flake 自体は第三者個人の wrapper** で、信頼の対象は別。
    # nixpkgs の chatgpt は macOS 専用なので、nixpkgs からは入れられない
    # (他の入手経路は未調査)。overlay は flake/default.nix で 1 attr に絞る。
    # ref=main が捕まえるのは既定ブランチの改名だけ(消えれば update が失敗する)。
    # owner/repo の transfer は GitHub の redirect で追随されるので検出できない。
    # 実際に版を固定しているのは lock の rev + narHash であり、それが効くのは
    # 次の nix flake update までである。update のたびに上流の diff を見ること。
    chatgpt-desktop-app = {
      url = "github:poeck/chatgpt-desktop-app-nix-flake?ref=main";
      inputs.nixpkgs.follows = "nixpkgs";
    };
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
