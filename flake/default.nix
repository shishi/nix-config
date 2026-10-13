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
          # 上流 CI が公開する Neovim 本体を使う。dev partition の依存構成は
          # packages.default と異なるため、キャッシュ済みの checks 側を参照する。
          (_final: _prev: {
            neovim = inputs.neovim-nightly-overlay.checks.${system}.neovim;
          })
          # 上流 CI 済みの package を既存の pkgs.llm-agents 名前空間へ公開する。
          # shared-nixpkgs はこの flake の nixpkgs で再構築するため cache が外れる。
          (_final: _prev: { llm-agents = inputs.llm-agents.packages.${system}; })
        ];
      };
    };

  flake.overlays.default = _final: prev: {
    yaskkserv2 = inputs.yaskkserv2.packages.${prev.stdenv.hostPlatform.system}.yaskkserv2;
  };
}
