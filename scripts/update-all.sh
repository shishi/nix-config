#!/usr/bin/env bash
# アトミック update: 一時 worktree で lock 更新 + パッケージ bump + 検証。
# 成功しても main へは進めない(ブランチ update/<date> に残す)。
# main への編入条件: earth 上で `nix run .#switch` が成功し
# ~/.local/state/nix-config/last-applied にその rev が記録された後、手動 merge。
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"
branch="update/$(date +%Y%m%d-%H%M)"
wt="$(mktemp -d)"
cleanup() { git worktree remove --force "$wt" 2>/dev/null || true; }
trap cleanup EXIT

git worktree add -b "$branch" "$wt" HEAD
cd "$wt"

echo "== flake update =="
nix flake update --commit-lock-file

echo "== custom package updates (yaskkserv2) =="
nix-update --flake yaskkserv2 --commit || echo "yaskkserv2: no update"

echo "== checks (可搬グラフ信号) =="
nix flake check

echo "== 合成 DE toplevel の実 build(main 編入ゲート。eval 緑でも realization が壊れるケースを検出)=="
nix build .#nixosConfigurations.synth-gnome.config.system.build.toplevel --no-link
nix build .#nixosConfigurations.synth-kde.config.system.build.toplevel --no-link

# 成功時も worktree は掃除する(ブランチは残る。残すと git switch が
# 'already used by worktree' で失敗する — Med-3 実測)
cd "$repo_root"
git worktree remove "$wt"
trap - EXIT

cat <<GUIDE
== OK: 更新は $branch に残しました(worktree は掃除済み)==
次の手順:
  1. git switch $branch && nix run .#switch   # earth で適用(成功時に last-applied へ rev 記録)
  2. rev 一致を機械検証してから merge:
     [ "\$(git rev-parse HEAD)" = "\$(cut -d' ' -f2 ~/.local/state/nix-config/last-applied)" ] \\
       && git switch main && git merge --ff-only $branch
GUIDE
