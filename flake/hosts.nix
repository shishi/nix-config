{
  inputs,
  self,
  withSystem,
  ...
}:
{
  flake.homeConfigurations = {
    # username-only キー: nh / home-manager が user@hostname 不一致時に
    # フォールバック解決する安定 ID(hostname 変更・WSL 複製に耐える)
    "shishi" = withSystem "x86_64-linux" (
      { pkgs, ... }:
      inputs.home-manager.lib.homeManagerConfiguration {
        inherit pkgs;
        extraSpecialArgs = { inherit inputs; };
        modules = [ ../hosts/ubuntu-wsl ];
      }
    );
  };
}
