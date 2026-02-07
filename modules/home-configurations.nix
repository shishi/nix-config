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
            {
              _module.args = {
                myLib = import "${self}/lib" { inherit pkgs; };
              # hasGui判定は myConfig.hasGui オプションで制御
              # サーバー用configの場合: { myConfig.hasGui = false; } を modules に追加
              };
            }
          ];
        }
      );
    };
  };
}
