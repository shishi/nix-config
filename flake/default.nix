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
        config.allowUnfree = true;
        overlays = [
          self.overlays.default
          inputs.neovim-nightly-overlay.overlays.default
          inputs.llm-agents.overlays.shared-nixpkgs
          # nightly overlay が neovim-unwrapped を定義したあとに被せる必要がある
          (import ../overlays/neovim-desktop.nix)
        ];
      };
    };

  flake.overlays.default = import ../overlays;
}
