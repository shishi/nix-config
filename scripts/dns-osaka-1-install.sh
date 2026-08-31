#!/usr/bin/env bash

set -eEuo pipefail
umask 077

die() {
  printf 'dns-osaka-1-install: %s\n' "$*" >&2
  exit 1
}

find_repo_root() {
  local current=$PWD
  while [ "$current" != / ]; do
    if [ -f "$current/flake.nix" ]; then
      printf '%s\n' "$current"
      return
    fi
    current=$(dirname "$current")
  done
  die 'flake.nix が見つからない。リポジトリ内で実行すること'
}

select_tmpfs_root() {
  local candidate filesystem_type
  for candidate in "${XDG_RUNTIME_DIR:-}" /dev/shm; do
    [ -n "$candidate" ] || continue
    [ -d "$candidate" ] && [ -w "$candidate" ] || continue
    filesystem_type=$(findmnt -n -o FSTYPE -T "$candidate" 2>/dev/null || true)
    if [ "$filesystem_type" = tmpfs ]; then
      printf '%s\n' "$candidate"
      return
    fi
  done
  die '書き込み可能な tmpfs が見つからない'
}

cleanup() {
  local status=$?
  set +e
  if [ -n "${tmpdir:-}" ] && [ -d "$tmpdir" ]; then
    rm -rf -- "$tmpdir"
  fi
  trap - EXIT
  exit "$status"
}

[ "$#" -eq 0 ] || die 'このホスト専用ラッパーに引数は指定しないこと'

[ -n "${NIXOS_ANYWHERE_BIN:-}" ] || die 'NIXOS_ANYWHERE_BIN が無い'
[ -x "$NIXOS_ANYWHERE_BIN" ] || die 'nixos-anywhere を実行できない'

repo_root=$(find_repo_root)
cd "$repo_root"
known_hosts=${SSH_KNOWN_HOSTS_FILE:-$HOME/.ssh/known_hosts}
[ -f "$known_hosts" ] || die "SSH known_hosts が無い: $known_hosts"

nixos_anywhere_arguments=(
  --flake .#dns-osaka-1
  --target-host ubuntu@129.225.177.221
  --ssh-option "UserKnownHostsFile=$known_hosts"
  --ssh-option StrictHostKeyChecking=yes
)

bootstrap=secrets/dns-osaka-1/bootstrap.yaml
runtime=secrets/dns-osaka-1/runtime.yaml
management_key=${SOPS_AGE_KEY_FILE:-secrets/management-age-key.txt}

git ls-files --error-unmatch -- "$bootstrap" "$runtime" >/dev/null 2>&1 || \
  die 'dns-osaka-1 の暗号文がGitで追跡されていない'
[ -f "$management_key" ] || die '管理用age鍵が読めない'

tmpdir=$(mktemp -d "$(select_tmpfs_root)/dns-osaka-1-install.XXXXXXXX")
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

host_age_key="$tmpdir/dns-osaka-1-age-key.txt"
HOME="$tmpdir" XDG_CONFIG_HOME="$tmpdir/config" SOPS_AGE_KEY_FILE="$management_key" \
  sops --decrypt --output-type json "$bootstrap" | \
  jq -jer '."dns-osaka-1-age-key"' >"$host_age_key" || \
  die 'bootstrap.yamlからホストage鍵を取得できない'
chmod 600 "$host_age_key"
age-keygen -y "$host_age_key" >/dev/null 2>&1 || die 'ホストage鍵が不正'

SOPS_AGE_KEY_FILE="$host_age_key" sops --decrypt --output-type json "$runtime" | \
  jq -e '
    type == "object" and
    (keys == ["freshrss-api-password", "freshrss-api-url", "freshrss-api-username", "tailscale-oauth-secret"]) and
    (."tailscale-oauth-secret" | type == "string" and startswith("tskey-client-") and length > 20) and
    (."freshrss-api-url" | type == "string" and test("^https?://") and length > 10) and
    (."freshrss-api-username" | type == "string" and length > 0) and
    (."freshrss-api-password" | type == "string" and length > 0)
  ' >/dev/null || die 'runtime.yamlの値が未設定または不正'

extra_files="$tmpdir/extra-files"
install -d -m 700 "$extra_files/var/lib/sops-nix"
install -m 600 "$host_age_key" "$extra_files/var/lib/sops-nix/dns-osaka-1-age-key.txt"

"$NIXOS_ANYWHERE_BIN" \
  "${nixos_anywhere_arguments[@]}" \
  --extra-files "$extra_files" \
  --copy-host-keys \
  --phases kexec,disko,install,reboot
