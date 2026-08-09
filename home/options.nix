{ lib, config, ... }:
{
  options.my = {
    gui.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "GUI アプリを導入するか(WSLg 含む。DE セッションの有無とは別概念)";
    };

    desktopSession = lib.mkOption {
      type = lib.types.nullOr (
        lib.types.enum [
          "gnome"
          "kde"
        ]
      );
      default = null;
      description = "宣言的に管理する DE セッション。null = セッション無し";
    };

    shell = lib.mkOption {
      type = lib.types.enum [
        "fish"
        "bash"
      ];
      default = "fish";
      description = "ログインシェル(ヒアリング #8 裁定値)。検証と alias 移植先の導出に使う";
    };

    skk.enable = lib.mkEnableOption "yaskkserv2 SKK server stack";

    rust.cargoTools = lib.mkOption {
      type = lib.types.listOf (
        lib.types.submodule {
          options = {
            crate = lib.mkOption { type = lib.types.str; };
            bins = lib.mkOption { type = lib.types.listOf lib.types.str; };
          };
        }
      );
      default = [
        {
          crate = "cargo-watch";
          bins = [ "cargo-watch" ];
        }
        {
          crate = "cargo-edit";
          bins = [
            "cargo-add"
            "cargo-rm"
            "cargo-set-version"
            "cargo-upgrade"
          ];
        }
        {
          crate = "cargo-outdated";
          bins = [ "cargo-outdated" ];
        }
        {
          crate = "cargo-audit";
          bins = [ "cargo-audit" ];
        }
        {
          crate = "cargo-deny";
          bins = [ "cargo-deny" ];
        }
        {
          crate = "cargo-expand";
          bins = [ "cargo-expand" ];
        }
        {
          crate = "cargo-bloat";
          bins = [ "cargo-bloat" ];
        }
      ];
      description = "cargo-binstall で存在保証 + 撤去するツール(crate 名と提供バイナリ)";
    };
  };

  config.my.gui.enable = lib.mkDefault (config.my.desktopSession != null);
}
