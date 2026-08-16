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
        #
        # 契約は 2 層に分かれている。system 側はリテラルと突き合わせて
        # ロケール方針そのものを固定し、greeter 側は期待値を i18n から導出して
        # 「写しが system と一致していること」だけを固定する。
        # こうすると方針のリテラルはこのファイルの 1 箇所にしか無いので、
        # locale.nix を変えたときに落ちるのは system 側の行だけになり、
        # 失敗メッセージが「方針を変えた」のか「写しがずれた」のかを区別できる。
        # 両側をリテラルで書くと同じ 5 つの値が 2 箇所に並び、片方だけ直して
        # 「greeter は system と同じ」の意味が壊れる余地が残る。
        #
        # 導出の副作用: extraLocaleSettings から例えば LC_TIME が消えると
        # greeter 側の期待値も "" になり、その行は空同士の比較で素通りする。
        # ただし同じ消失で system 側の LC_TIME が落ちるので、契約としては検出できる。
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
            # 方針の固定: 期待値はここにしか無いリテラル。
            check defaultLocale "${i18n.defaultLocale}" "en_US.UTF-8"
            check LC_TIME "${i18n.extraLocaleSettings.LC_TIME or ""}" "en_DK.UTF-8"
            check LC_MONETARY "${i18n.extraLocaleSettings.LC_MONETARY or ""}" "ja_JP.UTF-8"
            check LC_PAPER "${i18n.extraLocaleSettings.LC_PAPER or ""}" "ja_JP.UTF-8"
            check LC_MEASUREMENT "${i18n.extraLocaleSettings.LC_MEASUREMENT or ""}" "ja_JP.UTF-8"

            # 写しの一致の固定: 期待値は system 側の i18n から導出する。
            # environment には PATH も入るが契約はロケールだけなので、キーを名指しで見る。
            check greeter.LANG "${greeter.LANG or ""}" "${i18n.defaultLocale}"
            check greeter.LC_TIME "${greeter.LC_TIME or ""}" "${i18n.extraLocaleSettings.LC_TIME or ""}"
            check greeter.LC_MONETARY "${greeter.LC_MONETARY or ""}" "${
              i18n.extraLocaleSettings.LC_MONETARY or ""
            }"
            check greeter.LC_PAPER "${greeter.LC_PAPER or ""}" "${i18n.extraLocaleSettings.LC_PAPER or ""}"
            check greeter.LC_MEASUREMENT "${greeter.LC_MEASUREMENT or ""}" "${
              i18n.extraLocaleSettings.LC_MEASUREMENT or ""
            }"
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

        # rom-kana 差分テーブルの文字被覆。
        # skk-rom-kana が「打てば期待どおり出る」ことを代表例で見るのに対し、
        # こちらは「そもそも全部の文字が定義されているか」を網羅で見る。
        # 被覆に 1 文字でも穴があると、その文字を数字の直後に打った瞬間に
        # libskk が保留中の数字を破棄する(実際にバッククォートだけが抜けていた)。
        #
        # 期待値の 95 文字は rules.nix から取らずここへ独立に書く。
        # rules.nix 由来の値どうしを突き合わせても循環していて何も検査できない。
        # Nix にはコード値から文字を作る関数が無いので、ASCII 印字可能文字
        # (0x20 スペース 〜 0x7E チルダ)はリテラルで並べるほかない。
        #
        # 判定は Nix 側で済ませ、結果は passAsFile でファイルとして渡す
        # (nix-caches-sync と同じ渡し方)。問題文字には \ " ` $ が入りうるので、
        # シェルの引数やインデント文字列へ直接載せると別物に化ける
        # (バッククォートはコマンド置換になる)。
        skk-rom-kana-coverage =
          let
            inherit (pkgs) lib;
            inherit (skkRules.charSets) digits keepAscii others;

            expectedAscii = lib.stringToCharacters " !\"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~";

            # 問題文字は可能ならコード値を添えて出す。空白のように目で見えない
            # 文字を 0x20 と名指しするのが目的。
            #
            # charToInt は ASCII の表しか持たず、0x80 以上のバイトを渡すと
            # attribute missing で評価ごと死ぬ(実測。builtins.tryEval でも捕まらず、
            # lib.strings.asciiTable も export されていないので存在確認もできない)。
            # others へ非 ASCII が紛れると stringToCharacters がバイトへ分解して
            # この経路に入るため、expectedAscii への所属ではなく
            # リテラルに依存しない判定で入口を塞ぐ。
            # builtins.match は任意のバイトに対して null を返すだけで throw しない(実測)。
            isPrintableAscii = c: builtins.match "[ -~]" c != null;
            showChar =
              c:
              if isPrintableAscii c then
                "0x${lib.fixedWidthString 2 "0" (lib.toHexString (lib.strings.charToInt c))}[${c}]"
              else
                "[${c}]";
            show = lib.concatMapStringsSep " " showChar;

            covered = keepAscii ++ others;
            dupsIn = cs: lib.filter (c: lib.count (x: x == c) cs > 1) (lib.unique cs);

            missing = lib.filter (c: !(lib.elem c covered)) expectedAscii;
            extra = lib.filter (c: !(lib.elem c expectedAscii)) covered;
            overlap = lib.filter (c: lib.elem c others) keepAscii;

            # 期待値リテラルそのものの自己検査。他の判定はすべてこれを基準にするので、
            # ここが崩れると check は静かに嘘をつく。個数だけでなく
            # 「0x20 から 0x7E が順に並んでいる」ことまで見る。
            # && の右辺は遅延評価なので、非 ASCII 混入時に charToInt へは届かない。
            literalOk =
              lib.all isPrintableAscii expectedAscii
              && map lib.strings.charToInt expectedAscii == lib.range 32 126;

            # エントリ数は assert する定数ではなく導出値。digits の要素数 x 覆った
            # 文字数で、どちらの長さもここには書かない。romKana は listToAttrs が
            # 重複キーを畳むので、digits か covered に重複があればここが必ずずれる
            # (covered 側はどの文字かを上の行が名指しする)。
            #
            # ここが見るのはキーの本数だけで、綴り方は見ない。既存の skk-rom-kana
            # check は代表的な打鍵を 13 通り試すだけなので、950 キー全部の綴りを
            # 保証するものではない(例: キーを "${d}${s}" から "${s}${d}" へ
            # 入れ替えても本数は変わらず、どちらの check も通ってしまう)。
            expectedEntries = builtins.length digits * builtins.length covered;
            actualEntries = builtins.length (builtins.attrNames skkRules.romKana);

            # リテラルが壊れているときは他を並べない。missing / extra は壊れた基準
            # からの派生値で、rules.nix 側の問題に見えてしまう
            # (実測: リテラルから ~ を落とすと ~ が「印字可能外」と報告された)。
            problems =
              if !literalOk then
                [
                  "expectedAscii literal is corrupt: must be exactly 0x20..0x7E in order (other checks skipped)"
                ]
              else
                lib.optional (missing != [ ]) "not covered by keepAscii+others: ${show missing}"
                ++ lib.optional (extra != [ ]) "outside ASCII printable: ${show extra}"
                ++ lib.optional (overlap != [ ]) "in both keepAscii and others: ${show overlap}"
                ++ lib.optional (dupsIn keepAscii != [ ]) "duplicated within keepAscii: ${show (dupsIn keepAscii)}"
                ++ lib.optional (dupsIn others != [ ]) "duplicated within others: ${show (dupsIn others)}"
                ++ lib.optional (
                  expectedEntries != actualEntries
                ) "romKana entries: expected ${toString expectedEntries} but got ${toString actualEntries}";
          in
          pkgs.runCommand "skk-rom-kana-coverage"
            {
              report = lib.concatMapStrings (p: p + "\n") problems;
              passAsFile = [ "report" ];
            }
            ''
              if [ -s "$reportPath" ]; then
                echo "skk rom-kana coverage is broken:"
                # 各行は問題文字を生のまま含む。印字可能 ASCII には 0xNN が付くが、
                # 制御文字と非 ASCII バイトには付かない(上の showChar 参照)ので、
                # -A(= -vET)で可視化する。-v だけでは TAB と LF が素通しになり
                # (実測)、LF が混入すると報告が黙って複数行へ割れて読めなくなる。
                # -A なら TAB は ^I、非 ASCII は M-xx、行末は $ で見える。
                cat -A "$reportPath"
                exit 1
              fi
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
