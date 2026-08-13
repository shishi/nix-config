{ self, ... }:
{
  perSystem =
    { pkgs, ... }:
    let
      # eval のみ強制する check(drvPath を text に埋めると評価が走る)
      evalOnly =
        name: cfg:
        # unsafeDiscardStringContext が無いと drvPath の文字列コンテキストが
        # 全依存を持ち込み、`nix flake check` がフル realization してしまう(Med-1 実測)
        pkgs.writeText "${name}-eval" (
          builtins.unsafeDiscardStringContext cfg.config.system.build.toplevel.drvPath
        );
      caches = import ../shared/nix-caches.nix;
    in
    {
      checks = {
        # 可搬グラフ信号(ビルド)
        home-shishi = self.homeConfigurations."shishi".activationPackage;
        nixos-wsl-toplevel = self.nixosConfigurations.nixos-wsl.config.system.build.toplevel;

        # 合成 DE(eval。update の main 編入時は実 build — scripts/update.sh 参照)
        synth-gnome-eval = evalOnly "synth-gnome" self.nixosConfigurations.synth-gnome;
        synth-kde-eval = evalOnly "synth-kde" self.nixosConfigurations.synth-kde;

        # jupiter はスタブ hardware のため隔離名(「実機 OK」と誤読させない)。
        # 実 hardware-configuration.nix の commit 後に jupiter-toplevel として既定編入する
        jupiter-stub-eval = evalOnly "jupiter-stub" self.nixosConfigurations.jupiter;

        # ロケール契約: 表示は英語、書式は日本の慣習。
        locale-contract =
          let
            i18n = self.nixosConfigurations.jupiter.config.i18n;
          in
          pkgs.runCommand "locale-contract" { } ''
            ok=1
            check() {
              if [ "$2" != "$3" ]; then
                echo "$1: expected '$3' but got '$2'"
                ok=0
              fi
            }
            check defaultLocale "${i18n.defaultLocale}" "en_US.UTF-8"
            check LC_TIME "${i18n.extraLocaleSettings.LC_TIME or ""}" "en_DK.UTF-8"
            check LC_MONETARY "${i18n.extraLocaleSettings.LC_MONETARY or ""}" "ja_JP.UTF-8"
            check LC_PAPER "${i18n.extraLocaleSettings.LC_PAPER or ""}" "ja_JP.UTF-8"
            check LC_MEASUREMENT "${i18n.extraLocaleSettings.LC_MEASUREMENT or ""}" "ja_JP.UTF-8"
            [ "$ok" = 1 ] || exit 1
            touch $out
          '';

        # flake.nix の nixConfig(リテラル)と shared/nix-caches.nix の同期検証
        nix-caches-sync =
          pkgs.runCommand "nix-caches-sync"
            {
              flakeNix = builtins.readFile ../flake.nix;
              passAsFile = [ "flakeNix" ];
            }
            ''
              ok=1
              ${pkgs.lib.concatMapStringsSep "\n" (s: ''
                grep -qF "${s}" "$flakeNixPath" || { echo "missing in flake.nix nixConfig: ${s}"; ok=0; }
              '') (builtins.tail caches.substituters ++ builtins.tail caches.trustedPublicKeys)}
              [ "$ok" = 1 ] || exit 1
              touch $out
            '';
      };
    };
}
