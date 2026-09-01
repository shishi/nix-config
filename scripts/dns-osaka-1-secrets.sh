#!/usr/bin/env bash

set -eEuo pipefail
umask 077

die() {
  printf 'dns-osaka-1-secrets: %s\n' "$*" >&2
  exit 1
}

repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || die 'Gitリポジトリ内で実行すること'
exec 9>"$repo_root/secrets/dns-osaka-1/.dns-osaka-1-secrets.lock" || die 'lock を作成できない'
flock -n 9 || die '別の dns-osaka-1-secrets が実行中'
management_key=${SOPS_AGE_KEY_FILE:-$repo_root/secrets/management-age-key.txt}
[ -f "$management_key" ] || die '管理用age鍵が読めない'

runtime_root=${XDG_RUNTIME_DIR:-/dev/shm}
[ "$(findmnt -n -o FSTYPE -T "$runtime_root" 2>/dev/null)" = tmpfs ] || die 'tmpfsを利用できない'
tmpdir=$(mktemp -d "$runtime_root/dns-osaka-1-secrets.XXXXXXXX")

cleanup() {
  local status=$?
  set +e
  rm -rf -- "$tmpdir"
  trap - EXIT
  exit "$status"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

host_key="$tmpdir/dns-osaka-1-age-key.txt"
SOPS_AGE_KEY_FILE="$management_key" \
  sops --decrypt --output-type json "$repo_root/secrets/dns-osaka-1/bootstrap.yaml" | \
  jq -jer '."dns-osaka-1-age-key"' >"$host_key" || die 'ホストage鍵を取得できない'
chmod 600 "$host_key"
age-keygen -y "$host_key" >/dev/null 2>&1 || die 'ホストage鍵が不正'

# sops は .sops.yaml を cwd から上へ探すため、repo root で実行すると root の
# .sops.yaml(jupiter 用ルール)に当たり "no matching creation rules" になる(実測)。
# dns 用ルールを明示する。
SOPS_AGE_KEY_FILE="$host_key" sops --config "$repo_root/secrets/dns-osaka-1/.sops.yaml" \
  "$repo_root/secrets/dns-osaka-1/runtime.yaml"
