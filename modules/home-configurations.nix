# Home Manager configurations module for flake-parts
{
  self,
  config,
  inputs,
  lib,
  ...
}:
{
  flake = {
    homeConfigurations = {
      "shishi@ubuntu" = inputs.home-manager.lib.homeManagerConfiguration {
        pkgs = import inputs.nixpkgs {
          system = "x86_64-linux";
          config = {
            allowUnfree = true;
          };
          overlays = [
            (import "${self}/overlays/default.nix")
            inputs.fenix.overlays.default
            inputs.neovim-nightly-overlay.overlays.default
            inputs.llm-agents.overlays.default
          ];
        };

        modules = [
          "${self}/home-manager"
          {
            # カスタムライブラリをHome Managerに渡す
            _module.args = {
              myLib = import "${self}/lib" { };
            };
          }
        ];
      };
    };
  };
}
