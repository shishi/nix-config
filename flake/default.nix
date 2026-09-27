# flake-parts モジュール集約
{ inputs, self, ... }:
{
  imports = [
    ./treefmt.nix
    ./devshells.nix
    ./packages.nix
    ./hosts.nix
    ./checks.nix
    ./apps
    ./templates.nix
  ];

  perSystem =
    { system, ... }:
    {
      # overlays + allowUnfree 適用済み pkgs(全ターゲット共通の唯一の真実。
      # NixOS ホストへは nixpkgs.pkgs で注入する)
      _module.args.pkgs = import inputs.nixpkgs {
        inherit system;
        config = {
          allowUnfree = true;
          android_sdk.accept_license = true;
        };
        overlays = [
          self.overlays.default
          inputs.neovim-nightly-overlay.overlays.default
          # 上流 CI 済みの package を既存の pkgs.llm-agents 名前空間へ公開する。
          # shared-nixpkgs はこの flake の nixpkgs で再構築するため cache が外れる。
          (_final: _prev: { llm-agents = inputs.llm-agents.packages.${system}; })
          # nightly overlay が neovim-unwrapped を定義したあとに被せる必要がある
          (import ../overlays/neovim-desktop.nix)
        ];
      };
    };

  flake.overlays.default = _final: prev: {
    yaskkserv2 = inputs.yaskkserv2.packages.${prev.stdenv.hostPlatform.system}.yaskkserv2;
  };
}
