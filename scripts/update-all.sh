#!/usr/bin/env bash
# nix run .#update の本体: flake update + カスタムパッケージ (nix-update) を一括実行する
# 必要ツール (git / nix / jq / nix-update) は writeShellApplication の runtimeInputs で
# PATH に注入されるため、ここでは絶対パスを埋め込まず素のコマンド名で参照する。
set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_step() { echo -e "${BLUE}[STEP]${NC} $1"; }

FLAKE_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$FLAKE_ROOT"

log_info "nix-config の更新を開始します"
log_info "Flake root: $FLAKE_ROOT"

# 1. nix flake update
log_step "nix flake update を実行中..."
nix flake update

# 2. nix-update でカスタムパッケージを更新
log_step "カスタムパッケージを取得中..."
SYSTEM="$(nix eval --impure --raw --expr 'builtins.currentSystem')"
# nix eval を先に変数へ捕捉する。flake 評価エラー時は command substitution の失敗が
# errexit を発火させてスクリプトごと停止させたいため (mapfile + process substitution
# だと eval 失敗が握りつぶされ「pkg 0 個」と誤認して全更新を黙ってスキップしてしまう)。
# 空配列 (カスタムパッケージ 0 個) は正常系として下で扱う。
packages_json="$(nix eval ".#packages.$SYSTEM" --apply 'builtins.attrNames' --json)"
mapfile -t packages < <(jq -r '.[]' <<<"$packages_json")

if [ "${#packages[@]}" -eq 0 ]; then
  log_warn "カスタムパッケージが見つかりませんでした"
else
  log_info "更新対象パッケージ: ${packages[*]}"
  for pkg in "${packages[@]}"; do
    log_step "nix-update: $pkg を更新中..."
    nix-update --flake "$pkg" --commit || log_warn "$pkg の更新をスキップしました"
  done
fi

echo ""
log_info "========== 更新完了 =========="

# 変更の確認
if ! git diff --quiet flake.lock 2>/dev/null; then
  log_warn "flake.lock が更新されました"
  git diff --stat flake.lock || true
fi

echo ""
log_info "変更を適用するには: nix run home-manager/master -- switch --flake .#shishi@ubuntu"
