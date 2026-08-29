#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"
if [ -n "$(git status --porcelain)" ]; then
  echo "update: 未コミットの変更があるため中止した。commit または退避してから再実行すること" >&2
  exit 1
fi

echo "== flake inputs =="
nix flake update

echo "== custom package: yaskkserv2 =="
nix-update --flake yaskkserv2

echo "== checks =="
nix flake check

echo "update: 更新と検査が完了した。差分を確認してcommitすること"
git status --short
