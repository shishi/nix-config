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
in
{
  config = lib.mkIf config.my.skk.enable {
    home.packages = [ pkgs.yaskkserv2 ];

    # libskk StickyShift ルール(旧 install-system-packages.sh の heredoc から移管 — 宣言化)
    xdg.configFile."libskk/rules/StickyShift/metadata.json".text = builtins.toJSON {
      name = "Sticky Shift";
      description = "Enable Sticky Shift";
    };
    xdg.configFile."libskk/rules/StickyShift/keymap/hiragana.json".text = builtins.toJSON {
      include = [ "default/hiragana" ];
      define.keymap.";" = "start-preedit-no-delete";
    };
    xdg.configFile."libskk/rules/StickyShift/keymap/katakana.json".text = builtins.toJSON {
      include = [ "default/katakana" ];
      define.keymap.";" = "start-preedit-no-delete";
    };

    # 辞書の取得・変換はアトミックに行う:
    # 一時ファイルへ DL → サイズ検証 → rename。変換も一時出力 → 成功時 rename。
    # 失敗時は不完全な生成物を残さない(「存在するから取得済み」の誤認で
    # 自動回復が永久に走らない状態を作らない)。ネットワーク不達は警告のみ(非致命)。
    home.activation.setupSkkDictionary = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      (
        set -eu
        mkdir -p ${skkDictDir}
        exec 9>"${skkDictDir}/.setup.lock"
        if ! ${pkgs.util-linux}/bin/flock -n 9; then
          echo "skk: another setup is running; skipping" >&2
          exit 0
        fi
        if [ ! -f ${skkDictL} ]; then
          tmp="$(${pkgs.coreutils}/bin/mktemp ${skkDictDir}/.jisyo.XXXXXX)"
          if ${pkgs.curl}/bin/curl -fL --max-time 300 -o "$tmp" \
            https://raw.githubusercontent.com/skk-dev/dict/master/SKK-JISYO.L; then
            # 実物は 10MB 超。1MB 未満は失敗とみなす
            if [ "$(${pkgs.coreutils}/bin/stat -c %s "$tmp")" -gt 1000000 ]; then
              ${pkgs.coreutils}/bin/mv "$tmp" ${skkDictL}
            else
              ${pkgs.coreutils}/bin/rm -f "$tmp"
              echo "skk: downloaded dictionary too small; will retry on next switch" >&2
            fi
          else
            ${pkgs.coreutils}/bin/rm -f "$tmp"
            echo "skk: dictionary download failed (offline?); will retry on next switch" >&2
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
            ${pkgs.coreutils}/bin/rm -f "$tmp"
            echo "skk: dictionary conversion failed; will retry on next switch" >&2
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
        ExecStart = "${pkgs.yaskkserv2}/bin/yaskkserv2 --port 1178 --google-japanese-input=last --google-suggest --google-cache-filename=${yaskkservCache} ${yaskkservDict}";
        Restart = "always";
        RestartSec = 3;
      };
      Install.WantedBy = [ "default.target" ];
    };
  };
}
