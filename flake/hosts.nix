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

  flake.nixosConfigurations =
    let
      mkNixos =
        modules:
        withSystem "x86_64-linux" (
          { pkgs, ... }:
          inputs.nixpkgs.lib.nixosSystem {
            specialArgs = { inherit inputs; };
            modules = [ { nixpkgs.pkgs = pkgs; } ] ++ modules; # pkgs 注入契約(allowUnfree/overlay の単一真実)
          }
        );
      mkNixosAarch64 =
        modules:
        inputs.nixpkgs.lib.nixosSystem {
          system = "aarch64-linux";
          specialArgs = { inherit inputs; };
          modules = modules;
        };
      # 合成 DE 評価ターゲット: dummy hardware で HM 統合込みの DE 配線を eval する
      mkSynth =
        desktop:
        mkNixos [
          ../nixos
          ../nixos/bootstrap-reminder.nix
          ../nixos/fonts.nix
          ../nixos/home-manager.nix
          (../nixos/desktop + "/${desktop}.nix")
          inputs.home-manager.nixosModules.home-manager
          {
            networking.hostName = "synth-${desktop}";
            system.stateVersion = "25.05";
            fileSystems."/" = {
              device = "none";
              fsType = "tmpfs";
            };
            boot.loader.grub.enable = false;
            home-manager = {
              useGlobalPkgs = true;
              useUserPackages = true;
              extraSpecialArgs = { inherit inputs; };
              users.shishi = {
                imports = [ ../home ];
                my.desktopSession = desktop;
              };
            };
          }
        ];
    in
    {
      dns-osaka-1 = mkNixosAarch64 [ ../hosts/dns-osaka-1 ];
      jupiter = mkNixos [ ../hosts/jupiter ];
      nixos-wsl = mkNixos [ ../hosts/nixos-wsl ];
      synth-gnome = mkSynth "gnome";
      synth-kde = mkSynth "kde";
    };
}
