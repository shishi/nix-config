{ self, ... }:
{
  perSystem =
    { pkgs, ... }:
    {
      packages = import ../pkgs { inherit pkgs; } // {
        # 鍵を焼き込んだ installer ISO。素の nixos-minimal と違い、起動しただけで
        # root へ鍵認証で入れるので nixos-anywhere をそのまま流せる。
        # flake.systems は x86_64-linux のみなので system 分岐は要らない。
        installer-iso = self.nixosConfigurations.installer.config.system.build.isoImage;
      };
    };
}
