# flake-partsモジュールの例（無害）
{ self, config, ... }:

{
  perSystem = { system, pkgs, ... }: {
    # カスタムパッケージの例
    packages.hello-custom = pkgs.writeShellScriptBin "hello-custom" ''
      echo "Hello from custom flake-parts module!"
    '';
    
    # カスタムアプリの例
    apps.update-system = {
      type = "app";
      program = "${pkgs.writeShellScript "update-system" ''
        echo "Updating Nix flake..."
        nix flake update
      ''}";
    };
  };
}