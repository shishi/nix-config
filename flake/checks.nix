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

      skkRules = import ../home/skk/rules.nix { inherit (pkgs) lib; };
      # libskk はルールを ~/.config/libskk/rules から読む。
      # home/skk/rules.nix と同じ定義でルールディレクトリを組み立てる。
      skkRuleDir = pkgs.runCommand "skk-test-rules" { } ''
        mkdir -p $out/StickyShift/rom-kana $out/StickyShift/keymap
        cp ${pkgs.writeText "metadata.json" (builtins.toJSON skkRules.metadata)} \
          $out/StickyShift/metadata.json
        cp ${pkgs.writeText "hiragana.json" (builtins.toJSON skkRules.keymapHiragana)} \
          $out/StickyShift/keymap/hiragana.json
        cp ${pkgs.writeText "katakana.json" (builtins.toJSON skkRules.keymapKatakana)} \
          $out/StickyShift/keymap/katakana.json
        cp ${
          pkgs.writeText "rom-kana.json" (
            builtins.toJSON {
              include = [ "default/default" ];
              define.rom-kana = skkRules.romKana;
            }
          )
        } $out/StickyShift/rom-kana/default.json
      '';
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
        # SDDM の greeter も同じ値で固定する。nixos/desktop/kde.nix が
        # display-manager.service の environment へ i18n を写しているが、
        # その写しが消えても system 側の宣言だけは通ってしまうので、
        # 宣言が実際に unit へ届いているかをここで突き合わせる。
        # 別 check に分けず相乗りさせたのは、期待値のリテラルを 1 箇所に保つため。
        # 分けると同じ 5 つの値が 2 箇所に並び、locale.nix を変えたときに
        # 片方だけ直して「greeter は system と同じ」の意味が壊れる余地が残る。
        locale-contract =
          let
            i18n = self.nixosConfigurations.jupiter.config.i18n;
            # unit ごと消えた場合も eval エラーではなく check の失敗として出したいので or {}。
            greeter =
              self.nixosConfigurations.jupiter.config.systemd.services.display-manager.environment or { };
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

            # greeter は system と同じ値であること。environment には PATH も入るが
            # 契約はロケールだけなので、キーを名指しで見る。
            check greeter.LANG "${greeter.LANG or ""}" "en_US.UTF-8"
            check greeter.LC_TIME "${greeter.LC_TIME or ""}" "en_DK.UTF-8"
            check greeter.LC_MONETARY "${greeter.LC_MONETARY or ""}" "ja_JP.UTF-8"
            check greeter.LC_PAPER "${greeter.LC_PAPER or ""}" "ja_JP.UTF-8"
            check greeter.LC_MEASUREMENT "${greeter.LC_MEASUREMENT or ""}" "ja_JP.UTF-8"
            [ "$ok" = 1 ] || exit 1
            touch $out
          '';

        # SKK の打鍵挙動の契約。libskk 同梱の CLI エミュレータ(bin/skk)に
        # キーイベント列を流し、確定出力と preedit を照合する。
        # GUI もセッションも要らないので nix flake check に乗る。
        #
        # 期待値の空文字は "" で書く。Nix のインデント文字列では '' が終端記号なので、
        # シェルの空文字を '' と書くとここで文字列が切れる。
        skk-rom-kana = pkgs.runCommand "skk-rom-kana" { nativeBuildInputs = [ pkgs.libskk ]; } ''
          export HOME=$TMPDIR
          export XDG_CONFIG_HOME=$TMPDIR/.config
          mkdir -p "$XDG_CONFIG_HOME/libskk"
          cp -r ${skkRuleDir} "$XDG_CONFIG_HOME/libskk/rules"
          chmod -R u+w "$XDG_CONFIG_HOME/libskk/rules"

          ok=1
          # 引数: 説明, キー列, 期待 output, 期待 preedit
          # 変数名に out を使わないこと: runCommand の $out(出力 store path)を
          # 上書きしてしまい、全ケースが通っても最後の touch $out が落ちる。
          case_() {
            got=$(printf '%s\n' "$2" | skk -r StickyShift 2>/dev/null | tail -1)
            gotOut=$(printf '%s' "$got" | ${pkgs.jq}/bin/jq -r '.output')
            gotPre=$(printf '%s' "$got" | ${pkgs.jq}/bin/jq -r '.preedit')
            if [ "$gotOut" != "$3" ] || [ "$gotPre" != "$4" ]; then
              echo "FAIL $1: keys=[$2]"
              echo "  expected output=[$3] preedit=[$4]"
              echo "  actual   output=[$gotOut] preedit=[$gotPre]"
              ok=0
            fi
          }

          # 目標: 数字の直後の記号を半角のまま出す
          case_ date    '2 0 2 6 minus 0 8 minus 1 2' '2026-08-1' '2'
          case_ decimal '3 period 1 4'                '3.1'       '4'
          case_ comma   '1 comma 0 0 0'               '1,00'      '0'
          case_ colon   '1 2 colon 3 0'               '12:3'      '0'
          case_ slash   '0 slash 5'                   '0/'        '5'

          # 回帰: 既存の入力を壊していない
          case_ digits  '1 2 3'         '12'     '3'
          case_ mixed   '1 a'           '1あ'    ""
          case_ kana    'a i u'         'あいう' ""
          case_ chouon  'k a minus'     'かー'   ""
          case_ plus    '1 plus 2'      '1+'     '2'
          case_ grave   '1 grave 2'     '1`'     '2'
          case_ abbrev  'slash a'       ""       '▽a'
          case_ sticky  'semicolon a i' ""       '▽あい'

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
