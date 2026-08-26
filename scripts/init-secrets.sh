#!/usr/bin/env bash

set -eEuo pipefail
umask 077

repo_root=""
tmpdir=""
management_age_key_file="${SOPS_AGE_KEY_FILE:-$HOME/.config/sops/age/keys.txt}"
ssh_private_key=""
gpg_signing_key=""
management_age_recipient=""
jupiter_age_recipient=""
installation_started=0
installation_committed=0
staged_sops_config=""
staged_bootstrap=""
staged_runtime=""

die() {
  printf 'init-secrets: %s\n' "$*" >&2
  exit 1
}

find_repo_root() {
  local current=$PWD

  while [ "$current" != / ]; do
    if [ -f "$current/flake.nix" ]; then
      printf '%s\n' "$current"
      return 0
    fi
    current=$(dirname "$current")
  done

  if [ -f /flake.nix ]; then
    printf '/\n'
    return 0
  fi

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
      return 0
    fi
  done

  die '書き込み可能な tmpfs (XDG_RUNTIME_DIR または /dev/shm) が見つからない'
}

require_source_keys() {
  ssh_private_key="$HOME/.ssh/id_ed25519"
  [ -f "$ssh_private_key" ] || die "SSH 秘密鍵が無い: $ssh_private_key"
  ssh-keygen -y -f "$ssh_private_key" >/dev/null 2>&1 || die 'SSH 秘密鍵を読み取れない'

  gpg_signing_key=$(git config --global --get user.signingkey 2>/dev/null || true)
  [ -n "$gpg_signing_key" ] || die 'git の user.signingkey が設定されていない'
  gpg --batch --armor --export-secret-keys "$gpg_signing_key" >"$tmpdir/gpg-secret-key.asc"
  [ -s "$tmpdir/gpg-secret-key.asc" ] || die '設定された GPG 署名秘密鍵が見つからない'
}

read_confirmed_secret() {
  local label=$1 destination=$2 first second

  printf '%s: ' "$label" >&2
  IFS= read -r -s first
  printf '\n%s（確認）: ' "$label" >&2
  IFS= read -r -s second
  printf '\n' >&2

  [ -n "$first" ] || die "$label は空にできない"
  [ "$first" = "$second" ] || die "$label が一致しない"
  printf '%s' "$first" >"$destination"
}

generate_age_keys() {
  local management_dir

  management_dir=$(dirname "$management_age_key_file")
  mkdir -p "$management_dir"
  chmod 700 "$management_dir"
  if [ ! -e "$management_age_key_file" ]; then
    age-keygen -o "$management_age_key_file" >/dev/null 2>&1
  fi
  chmod 600 "$management_age_key_file"
  management_age_recipient=$(age-keygen -y "$management_age_key_file")

  age-keygen -o "$tmpdir/jupiter-age-key.txt" >/dev/null 2>&1
  chmod 600 "$tmpdir/jupiter-age-key.txt"
  jupiter_age_recipient=$(age-keygen -y "$tmpdir/jupiter-age-key.txt")
}

write_plaintext_json() {
  jq -n \
    --rawfile luks_passphrase "$tmpdir/luks-passphrase" \
    --rawfile login_password "$tmpdir/login-password" \
    --rawfile ssh_private_key "$ssh_private_key" \
    --rawfile gpg_secret_key "$tmpdir/gpg-secret-key.asc" \
    --rawfile jupiter_age_key "$tmpdir/jupiter-age-key.txt" \
    '{
      "luks-passphrase": $luks_passphrase,
      "login-password": $login_password,
      "ssh-private-key": $ssh_private_key,
      "gpg-secret-key": $gpg_secret_key,
      "jupiter-age-key": $jupiter_age_key
    }' >"$tmpdir/bootstrap.json"

  jq -n \
    --rawfile smb_password "$tmpdir/smb-password" \
    '{"smb-mars-shishi": ("username=shishi\npassword=" + $smb_password)}' >"$tmpdir/runtime.json"
}

encrypt_outputs() {
  printf 'creation_rules:\n  - path_regex: ^secrets/bootstrap\\.yaml$\n    age: %s\n  - path_regex: ^secrets/runtime\\.yaml$\n    age: %s\n' \
    "$management_age_recipient" "$jupiter_age_recipient" >"$tmpdir/.sops.yaml"

  sops --encrypt --age "$management_age_recipient" --input-type json --output-type yaml \
    "$tmpdir/bootstrap.json" >"$tmpdir/bootstrap.yaml"
  sops --encrypt --age "$jupiter_age_recipient" --input-type json --output-type yaml \
    "$tmpdir/runtime.json" >"$tmpdir/runtime.yaml"

  SOPS_AGE_KEY_FILE="$management_age_key_file" sops --decrypt "$tmpdir/bootstrap.yaml" >"$tmpdir/bootstrap.verify"
  SOPS_AGE_KEY_FILE="$tmpdir/jupiter-age-key.txt" sops --decrypt "$tmpdir/runtime.yaml" >"$tmpdir/runtime.verify"

  mkdir -p "$repo_root/secrets"
  staged_sops_config=$(mktemp "$repo_root/.init-secrets-sops.XXXXXXXX")
  staged_bootstrap=$(mktemp "$repo_root/secrets/.init-secrets-bootstrap.XXXXXXXX")
  staged_runtime=$(mktemp "$repo_root/secrets/.init-secrets-runtime.XXXXXXXX")
  cp "$tmpdir/.sops.yaml" "$staged_sops_config"
  cp "$tmpdir/bootstrap.yaml" "$staged_bootstrap"
  cp "$tmpdir/runtime.yaml" "$staged_runtime"

  installation_started=1
  ln -T "$staged_sops_config" "$repo_root/.sops.yaml"
  ln -T "$staged_bootstrap" "$repo_root/secrets/bootstrap.yaml"
  ln -T "$staged_runtime" "$repo_root/secrets/runtime.yaml"
  installation_committed=1
}

rollback_published_output() {
  local staged=$1 final=$2

  if [ -n "$staged" ] && [ -e "$staged" ] && { [ -e "$final" ] || [ -L "$final" ]; } && [ "$final" -ef "$staged" ]; then
    rm -f -- "$final"
  fi
}

remove_staged_outputs() {
  local staged

  for staged in "$staged_sops_config" "$staged_bootstrap" "$staged_runtime"; do
    [ -z "$staged" ] || rm -f -- "$staged"
  done
}

cleanup() {
  if [ "$installation_started" -eq 1 ] && [ "$installation_committed" -eq 0 ]; then
    rollback_published_output "$staged_sops_config" "$repo_root/.sops.yaml"
    rollback_published_output "$staged_bootstrap" "$repo_root/secrets/bootstrap.yaml"
    rollback_published_output "$staged_runtime" "$repo_root/secrets/runtime.yaml"
  fi
  remove_staged_outputs
  if [ -n "${tmpdir:-}" ] && [ -d "$tmpdir" ]; then
    rm -rf -- "$tmpdir"
  fi
}

trap cleanup EXIT
trap 'cleanup; exit 1' HUP INT TERM

repo_root=$(find_repo_root)
cd "$repo_root"

for output in .sops.yaml secrets/bootstrap.yaml secrets/runtime.yaml; do
  [ ! -e "$output" ] && [ ! -L "$output" ] || die "既存の暗号化出力を上書きしない: $output"
done

tmpdir=$(mktemp -d "$(select_tmpfs_root)/init-secrets.XXXXXXXX")
require_source_keys
generate_age_keys
read_confirmed_secret 'LUKS パスフレーズ' "$tmpdir/luks-passphrase"
read_confirmed_secret 'ログインパスワード' "$tmpdir/login-password"
read_confirmed_secret 'SMB パスワード' "$tmpdir/smb-password"
write_plaintext_json
encrypt_outputs

printf 'init-secrets: 暗号化済み secrets を作成した\n'
