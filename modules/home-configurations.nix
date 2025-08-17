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
            inputs.nixpkgs-ruby.overlays.default
            inputs.fenix.overlays.default
          ];
        };

        modules = [
          "${self}/home-manager"
          {
            # カスタムライブラリをHome Managerに渡す
            _module.args = {
              myLib = import "${self}/lib" {
                inherit (inputs.nixpkgs) lib;
                pkgs = import inputs.nixpkgs {
                  system = "x86_64-linux";
                };
              };
            };
          }
        ];
      };
    };
  };
}
