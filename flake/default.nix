# flake-parts モジュール集約
{ inputs, self, ... }:
{
  imports = [
    ./treefmt.nix
    ./devshells.nix
    ./packages.nix
    ./hosts.nix
    ./checks.nix
    ./apps.nix
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
          # 第三者個人の flake なので overlay をそのまま噛ませない。この pkgs は
          # 全ターゲット共通なので、上流が次の版で openssh 等を上書きしたら
          # 無条件に全ホストへ入る。取り出す attr を 1 つに固定しておくと、
          # 名前が変わったときも黙って別物になるのではなく eval が落ちる。
          (final: prev: {
            inherit (inputs.chatgpt-desktop-app.overlays.default final prev) chatgpt-desktop-app;
          })
          # nightly overlay が neovim-unwrapped を定義したあとに被せる必要がある
          (import ../overlays/neovim-desktop.nix)
        ];
      };
    };

  flake.overlays.default = import ../overlays;
}
