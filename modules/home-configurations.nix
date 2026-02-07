# Home Manager configurations module for flake-parts
{
  self,
  config,
  inputs,
  lib,
  withSystem,
  ...
}:
{
  flake = {
    homeConfigurations = {
      "shishi@ubuntu" = withSystem "x86_64-linux" (
        { pkgs, ... }:
        inputs.home-manager.lib.homeManagerConfiguration {
          inherit pkgs;

          modules = [
            "${self}/home-manager"
            # サーバー用configの場合: { myConfig.hasGui = false; } を追加
          ];
        }
      );

      # --- Mac追加時のスケルトン ---
      # "shishi@mac" = withSystem "aarch64-darwin" (
      #   { pkgs, ... }:
      #   inputs.home-manager.lib.homeManagerConfiguration {
      #     inherit pkgs;
      #
      #     modules = [
      #       "${self}/home-manager"
      #       { myConfig.hasGui = true; }
      #     ];
      #   }
      # );

      # --- NixOS追加時のスケルトン ---
      # "shishi@nixos" = withSystem "x86_64-linux" (
      #   { pkgs, ... }:
      #   inputs.home-manager.lib.homeManagerConfiguration {
      #     inherit pkgs;
      #
      #     modules = [
      #       "${self}/home-manager"
      #     ];
      #   }
      # );
    };
  };
}
