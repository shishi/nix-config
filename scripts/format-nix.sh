#!/usr/bin/env bash
set -euo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."

files=()
while IFS= read -r -d '' file; do
  if [[ -f "$file" && ! -L "$file" ]]; then
    files+=("$file")
  fi
done < <(
  git diff --name-only -z --diff-filter=ACMR HEAD -- '*.nix'
  git ls-files --others --exclude-standard -z -- '*.nix'
)

if (( ${#files[@]} == 0 )); then
  exit 0
fi

if ! nix fmt --no-update-lock-file -- "${files[@]}" >&2; then
  echo 'Nix の自動整形に失敗しました。エラーを解消してから再実行してください。' >&2
  exit 2
fi
