# herdr の agent integration(claude / codex)と herdr skill(Claude Code
# plugin)をこのマシンへ配備する。home-manager activation から呼ばれる想定
# (手動実行も可)。全経路で冪等・非致命。
#
# 期待する環境変数:
#   HERDR_NORMALIZE_HOOKS: herdr-normalize-hooks.py への path

# 並行実行(activation と手動実行等)を直列化する。待機上限 60 秒。
# lock が取れない・待機超過の場合はそのまま進む(取りこぼしは次回実行時の
# hook 有無チェックが自己修復する)
bootstrap_lock="${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/herdr-bootstrap-$(id -u).lock"
if ! { exec 9>"$bootstrap_lock" && flock -w 60 9; } 2>/dev/null; then
  echo "herdr-bootstrap: lock が取れないため直列化なしで進む" >&2
fi

changed=0
integ_status="$(herdr integration status 2>/dev/null || true)"
declare -A hook_config=(
  [claude]="$HOME/.claude/settings.json"
  [codex]="$HOME/.codex/hooks.json"
)
for target in claude codex; do
  # dotfiles 配備前に install を走らせると設定の実ファイルが作られ、
  # 後の symlink 配備と衝突するため、その target はスキップする
  if [ ! -e "${hook_config[$target]}" ]; then
    echo "herdr-bootstrap: ${hook_config[$target]} が無いため $target をスキップ(dotfiles 未配備)" >&2
    continue
  fi
  # status の current 判定は integration script の版しか見ない。設定側から
  # hook 登録が消えていても current のままなので、登録の有無は別に確認する
  needs_install=0
  if ! printf '%s\n' "$integ_status" | grep -q "^$target: current"; then
    needs_install=1
  elif ! grep -q "herdr-agent-state.sh" "${hook_config[$target]}" 2>/dev/null; then
    needs_install=1
  fi
  if [ "$needs_install" = 1 ]; then
    if herdr integration install "$target"; then
      changed=1
    else
      echo "herdr-bootstrap: $target integration の install に失敗" >&2
    fi
  fi
done

# install は自マシンの絶対パスで hook を登録するが、~/.claude/settings.json と
# ~/.codex/hooks.json は dotfiles でマシン間共有している。絶対パスのままだと
# 他マシンで「ファイルが無い」エラーになるため ~ 形式 1 エントリへ正規化する。
# 失敗しても後続(plugin install)は続ける
python3 "$HERDR_NORMALIZE_HOOKS" "$HOME/.claude/settings.json" \
  'bash ~/.claude/hooks/herdr-agent-state.sh session' ||
  echo "herdr-bootstrap: settings.json の正規化に失敗" >&2
python3 "$HERDR_NORMALIZE_HOOKS" "$HOME/.codex/hooks.json" \
  'bash ~/.codex/herdr-agent-state.sh session' --no-matcher ||
  echo "herdr-bootstrap: codex hooks.json の正規化に失敗" >&2

if [ "$changed" = 1 ]; then
  echo "herdr-bootstrap: integration を更新した。dotfiles の diff を確認して commit すること" >&2
fi

# herdr skill は Claude Code plugin。plugin の宣言元は settings.json の
# enabledPlugins(dotfiles 追跡)で、それを冪等に解決する installer が
# dotfiles にある。ここで独自に claude plugin install を叩くと
# 「false は触らない」という installer のポリシーを迂回してしまうため、
# 導入は installer へ委譲する
if [ -f "$HOME/.claude/install-plugins.sh" ]; then
  bash "$HOME/.claude/install-plugins.sh" ||
    echo "herdr-bootstrap: install-plugins.sh が失敗(herdr skill 未導入の可能性)" >&2
else
  echo "herdr-bootstrap: ~/.claude/install-plugins.sh が無いため skill 導入をスキップ(dotfiles 未配備)" >&2
fi
