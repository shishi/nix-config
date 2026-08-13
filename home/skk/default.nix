{
  config,
  pkgs,
  lib,
  ...
}:
let
  skkDictDir = "${config.home.homeDirectory}/skk";
  skkDictL = "${skkDictDir}/SKK-JISYO.L";
  yaskkservDict = "${skkDictDir}/yaskkserv2.dictionary";
  yaskkservCache = "${skkDictDir}/yaskkserv2.cache";
  skkUserDict = "${skkDictDir}/user.dict";
  skkRules = import ./rules.nix { inherit lib; };
in
{
  config = lib.mkIf config.my.skk.enable {
    home.packages = [ pkgs.yaskkserv2 ];

    # libskk StickyShift ルール(定義は home/skk/rules.nix)
    xdg.configFile."libskk/rules/StickyShift/metadata.json".text = builtins.toJSON skkRules.metadata;
    xdg.configFile."libskk/rules/StickyShift/keymap/hiragana.json".text =
      builtins.toJSON skkRules.keymapHiragana;
    xdg.configFile."libskk/rules/StickyShift/keymap/katakana.json".text =
      builtins.toJSON skkRules.keymapKatakana;

    # 数字の直後の記号を半角のまま出す(日付 2026-08-12・時刻 12:30・小数 3.14 など)。
    # 生成規則と背景は home/skk/rules.nix を参照。
    # 挙動は flake/checks.nix の skk-rom-kana が libskk 同梱の CLI で検証する。
    xdg.configFile."libskk/rules/StickyShift/rom-kana/default.json".text = builtins.toJSON {
      include = [ "default/default" ];
      define.rom-kana = skkRules.romKana;
    };

    # fcitx5-skk が引く辞書の一覧。fcitx5 は PkgData(~/.local/share/fcitx5)から
    # skk/dictionary_list を読む。この "ファイルが無ければ既定値" ではなく
    # 「無ければ辞書ゼロ」なので、宣言しないと変換自体が成立しない
    # (VM リハーサルで実測: dictionary_list もシステム辞書も存在しなかった)。
    # 並び順が引き当ての優先順位。
    #   1. ユーザー辞書(readwrite): 変換の学習と単語登録の保存先
    #   2. yaskkserv2(server): Google 日本語入力連携を含む主辞書
    #   3. SKK-JISYO.L(readonly): server 不在時でも変換できるための退避
    xdg.dataFile."fcitx5/skk/dictionary_list".text = ''
      type=file,file=${skkUserDict},mode=readwrite
      type=server,host=localhost,port=1178
      type=file,file=${skkDictL},mode=readonly,encoding=EUC-JP
    '';

    # 辞書の取得・変換はアトミックに行う:
    # 一時ファイルへ DL → サイズ検証 → rename。変換も一時出力 → 成功時 rename。
    # 失敗時は不完全な生成物を残さない(「存在するから取得済み」の誤認で
    # 自動回復が永久に走らない状態を作らない)。ネットワーク不達は警告のみ(非致命)。
    #
    # ダウンロードは短いバックオフでリトライする。統合ホストでは
    # nixos/home-manager.nix が network-online.target の後に順序付けするため、
    # ここで想定するのは一時的な DNS / CDN の失敗のみ。総予算 90 秒で打ち切る
    # (activation のタイムアウトを食い潰さないため)。
    home.activation.setupSkkDictionary = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      (
        set -eu
        mkdir -p ${skkDictDir}
        ${pkgs.coreutils}/bin/touch ${skkUserDict}
        exec 9>"${skkDictDir}/.setup.lock"
        if ! ${pkgs.util-linux}/bin/flock -n 9; then
          echo "skk: another setup is running; skipping" >&2
          exit 0
        fi
        if [ ! -f ${skkDictL} ]; then
          # 総予算 90 秒で打ち切る。activation は Type=oneshot の
          # home-manager-<user>.service 上で走り TimeoutStartUSec=5min、かつ
          # Before=systemd-user-sessions.service なので、ここで粘るとログインが遅れ、
          # タイムアウトすれば後続の DAG エントリが実行されず世代が半端に適用される。
          # 取れなければ諦めて手順を出すほうが安全(辞書は起動に必須ではない)。
          attempts=3
          n=1
          got=0
          deadline=$(($(${pkgs.coreutils}/bin/date +%s) + 90))
          while [ "$n" -le "$attempts" ] && [ "$(${pkgs.coreutils}/bin/date +%s)" -lt "$deadline" ]; do
            tmp="$(${pkgs.coreutils}/bin/mktemp ${skkDictDir}/.jisyo.XXXXXX)"
            # --speed-limit/--speed-time: 接続後にストールした転送を 15 秒で切る
            # (--connect-timeout だけでは接続確立後のストールを検出できない)
            if ${pkgs.curl}/bin/curl -fL --connect-timeout 10 --max-time 60 \
              --speed-limit 10000 --speed-time 15 -o "$tmp" \
              https://raw.githubusercontent.com/skk-dev/dict/master/SKK-JISYO.L; then
              # 実物は 10MB 超。1MB 未満は失敗とみなす
              if [ "$(${pkgs.coreutils}/bin/stat -c %s "$tmp")" -gt 1000000 ]; then
                ${pkgs.coreutils}/bin/mv "$tmp" ${skkDictL}
                got=1
                break
              fi
              ${pkgs.coreutils}/bin/rm -f "$tmp"
              echo "skk: downloaded dictionary too small (attempt $n/$attempts)" >&2
            else
              ${pkgs.coreutils}/bin/rm -f "$tmp"
              echo "skk: dictionary download failed (attempt $n/$attempts)" >&2
            fi
            n=$((n + 1))
            if [ "$n" -le "$attempts" ]; then
              ${pkgs.coreutils}/bin/sleep $(((n - 1) * 5))
            fi
          done
          if [ "$got" != 1 ]; then
            # 「次の switch で再試行」とは書かない: 構成に変化がないと systemd は
            # home-manager-<user>.service を再起動せず activation 自体が走らないため
            # (VM リハーサルで実測)。手で再実行する経路を示す。
            # 統合ホストの当該ユニットは system 側なので sudo が要る。
            echo "skk: could not fetch dictionary within budget." >&2
            echo "skk: retry with 'sudo systemctl restart home-manager-${config.home.username}.service' (NixOS) or 'nix run .#switch' (standalone)" >&2
          fi
        fi
        if [ -f ${skkDictL} ] && { [ ! -f ${yaskkservDict} ] || [ ${skkDictL} -nt ${yaskkservDict} ]; }; then
          tmp="$(${pkgs.coreutils}/bin/mktemp ${skkDictDir}/.dict.XXXXXX)"
          if ${pkgs.yaskkserv2}/bin/yaskkserv2_make_dictionary \
            --dictionary-filename="$tmp" ${skkDictL}; then
            ${pkgs.coreutils}/bin/mv "$tmp" ${yaskkservDict}
            # HM の activation は名前順で reloadSystemd(sd-switch)が本フックより
            # 先に走るため、辞書生成直後にユニットを明示起動する(これが無いと
            # 再 switch でも condition failed のまま起動しない — 2 巡目レビュー実測)
            ${pkgs.systemd}/bin/systemctl --user start yaskkserv2.service 2>/dev/null || true
          else
            # 変換は決定的な処理なのでリトライしない(同じ入力なら同じ結果)。
            # 壊れた SKK-JISYO.L を疑う場合は削除して activation をやり直す。
            ${pkgs.coreutils}/bin/rm -f "$tmp"
            echo "skk: dictionary conversion failed; remove ${skkDictL} and re-run activation to refetch" >&2
          fi
        fi
      ) || echo "skk: setup encountered an error (non-fatal)" >&2
    '';

    systemd.user.services.yaskkserv2 = {
      Unit = {
        Description = "Yet Another SKK server";
        After = [ "network.target" ];
        # 辞書未生成なら起動しない(crash-loop でなく「条件不成立」で可視化)
        ConditionPathExists = yaskkservDict;
      };
      Service = {
        Type = "simple";
        ExecStart = "${pkgs.yaskkserv2}/bin/yaskkserv2 --no-daemonize --port 1178 --google-japanese-input=last --google-suggest --google-cache-filename=${yaskkservCache} ${yaskkservDict}";
        Restart = "always";
        RestartSec = 3;
      };
      Install.WantedBy = [ "default.target" ];
    };
  };
}
