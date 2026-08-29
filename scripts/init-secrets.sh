#!/usr/bin/env bash

set -eEuo pipefail
umask 077

repo_root=""
tmpdir=""
bootstrap_tmp=""
runtime_tmp=""
bootstrap_backup=""
runtime_backup=""
update_started=0
update_committed=0
primary_credential_min_chars=15
primary_credential_max_chars=128
management_age_key_file=""
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

acquire_repo_lock() {
  mkdir -p "$repo_root/secrets"
  exec 9>"$repo_root/secrets/.init-secrets.lock" || die 'init-secrets lock を作成できない'
  flock -n 9 || die '別の init-secrets が実行中'
}

resolve_management_age_key_file() {
  management_age_key_file="${SOPS_AGE_KEY_FILE:-$repo_root/secrets/management-age-key.txt}"
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
  IFS= read -r -s first || die "$label の入力を読み取れない"
  printf '\n%s（確認）: ' "$label" >&2
  IFS= read -r -s second || die "$label の確認入力を読み取れない"
  printf '\n' >&2

  [ -n "$first" ] || die "$label は空にできない"
  [ "$first" = "$second" ] || die "$label が一致しない"
  printf '%s' "$first" >"$destination"
}

validate_primary_credential_file() {
  local label=$1 file=$2 length

  length=$(jq -Rs 'length' "$file")
  if [ "$length" -lt "$primary_credential_min_chars" ] || \
    [ "$length" -gt "$primary_credential_max_chars" ]; then
    die "$label は${primary_credential_min_chars}文字以上${primary_credential_max_chars}文字以下にすること"
  fi
}

read_optional_confirmed_secret() {
  local label=$1 current_json=$2 key=$3 destination=$4 first second

  printf '%s（空Enterで現在値を維持）: ' "$label" >&2
  IFS= read -r -s first || die "$label の入力を読み取れない"
  printf '\n' >&2
  if [ -z "$first" ]; then
    jq -e --arg key "$key" '.[$key] | type == "string" and length > 0' "$current_json" >/dev/null || \
      die "$label は未登録のため空にできない"
    return 1
  fi

  printf '%s（確認）: ' "$label" >&2
  IFS= read -r -s second || die "$label の確認入力を読み取れない"
  printf '\n' >&2
  [ "$first" = "$second" ] || die "$label が一致しない"
  printf '%s' "$first" >"$destination"
}

validate_tailscale_oauth_client_secret() {
  local secret_file=$1 secret

  secret=$(<"$secret_file")
  case "$secret" in
    tskey-client-?*) ;;
    *) die 'Tailscale OAuth client secret は tskey-client- で始まる値を指定すること' ;;
  esac
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
    --rawfile tailscale_oauth_secret "$tmpdir/tailscale-oauth-secret" \
    '{
      "smb-mars-shishi": ("username=shishi\npassword=" + $smb_password),
      "tailscale-oauth-secret": $tailscale_oauth_secret
    }' >"$tmpdir/runtime.json"
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

update_existing_secrets() {
  local bootstrap_changed=0 jupiter_age_key="$tmpdir/jupiter-age-key.txt" runtime_changed=0

  [ -f "$management_age_key_file" ] || die 'management age key が読めない'
  SOPS_AGE_KEY_FILE="$management_age_key_file" \
    sops --decrypt --output-type json secrets/bootstrap.yaml >"$tmpdir/bootstrap-current.json"
  jq -e '
    type == "object" and
    (keys == ["gpg-secret-key", "jupiter-age-key", "login-password", "luks-passphrase", "ssh-private-key"]) and
    all(.[]; type == "string" and length > 0)
  ' "$tmpdir/bootstrap-current.json" >/dev/null || die 'bootstrap.yaml の形式が不正'
  jq -ejr '."jupiter-age-key"' "$tmpdir/bootstrap-current.json" >"$jupiter_age_key"
  chmod 600 "$jupiter_age_key"
  age-keygen -y "$jupiter_age_key" >/dev/null 2>&1 || die 'Jupiter age key が無効'

  SOPS_AGE_KEY_FILE="$jupiter_age_key" \
    sops --decrypt --output-type json secrets/runtime.yaml >"$tmpdir/runtime-current.json"
  jq -e '
    type == "object" and
    ((keys == ["smb-mars-shishi"]) or
     (keys == ["smb-mars-shishi", "tailscale-oauth-secret"])) and
    (."smb-mars-shishi" | type == "string" and startswith("username=shishi\npassword=") and
      length > ("username=shishi\npassword=" | length)) and
    ((has("tailscale-oauth-secret") | not) or
     (."tailscale-oauth-secret" | type == "string" and startswith("tskey-client-") and
       length > ("tskey-client-" | length)))
  ' "$tmpdir/runtime-current.json" >/dev/null || die 'runtime.yaml の形式が不正'

  if read_optional_confirmed_secret \
    'LUKS パスフレーズ' "$tmpdir/bootstrap-current.json" 'luks-passphrase' "$tmpdir/luks-passphrase"; then
    validate_primary_credential_file 'LUKS パスフレーズ' "$tmpdir/luks-passphrase"
    bootstrap_changed=1
  fi
  if read_optional_confirmed_secret \
    'ログインパスワード' "$tmpdir/bootstrap-current.json" 'login-password' "$tmpdir/login-password"; then
    validate_primary_credential_file 'ログインパスワード' "$tmpdir/login-password"
    bootstrap_changed=1
  fi
  if read_optional_confirmed_secret \
    'SMB パスワード' "$tmpdir/runtime-current.json" 'smb-mars-shishi' "$tmpdir/smb-password"; then
    printf 'username=shishi\npassword=' >"$tmpdir/smb-credential"
    cat "$tmpdir/smb-password" >>"$tmpdir/smb-credential"
    runtime_changed=1
  fi
  if read_optional_confirmed_secret \
    'Tailscale OAuth client secret' \
    "$tmpdir/runtime-current.json" \
    'tailscale-oauth-secret' \
    "$tmpdir/tailscale-oauth-secret"; then
    validate_tailscale_oauth_client_secret "$tmpdir/tailscale-oauth-secret"
    runtime_changed=1
  fi

  if [ "$bootstrap_changed" -eq 0 ] && [ "$runtime_changed" -eq 0 ]; then
    printf 'init-secrets: 既存の secret を維持した\n'
    return
  fi

  if [ "$bootstrap_changed" -eq 1 ]; then
    bootstrap_tmp=$(mktemp "secrets/bootstrap.tmp.XXXXXXXX.yaml")
    cp --preserve=mode -- secrets/bootstrap.yaml "$bootstrap_tmp"
    if [ -f "$tmpdir/luks-passphrase" ]; then
      jq -Rs . <"$tmpdir/luks-passphrase" | \
        SOPS_AGE_KEY_FILE="$management_age_key_file" \
        sops set --value-stdin "$bootstrap_tmp" '["luks-passphrase"]'
    fi
    if [ -f "$tmpdir/login-password" ]; then
      jq -Rs . <"$tmpdir/login-password" | \
        SOPS_AGE_KEY_FILE="$management_age_key_file" \
        sops set --value-stdin "$bootstrap_tmp" '["login-password"]'
    fi
  fi

  if [ "$runtime_changed" -eq 1 ]; then
    runtime_tmp=$(mktemp "secrets/runtime.tmp.XXXXXXXX.yaml")
    cp --preserve=mode -- secrets/runtime.yaml "$runtime_tmp"
    if [ -f "$tmpdir/smb-credential" ]; then
      jq -Rs . <"$tmpdir/smb-credential" | \
        SOPS_AGE_KEY_FILE="$jupiter_age_key" \
        sops set --value-stdin "$runtime_tmp" '["smb-mars-shishi"]'
    fi
    if [ -f "$tmpdir/tailscale-oauth-secret" ]; then
      jq -Rs . <"$tmpdir/tailscale-oauth-secret" | \
        SOPS_AGE_KEY_FILE="$jupiter_age_key" \
        sops set --value-stdin "$runtime_tmp" '["tailscale-oauth-secret"]'
    fi
  fi

  if [ "$bootstrap_changed" -eq 1 ]; then
    SOPS_AGE_KEY_FILE="$management_age_key_file" \
      sops --decrypt --output-type json "$bootstrap_tmp" >"$tmpdir/bootstrap-updated.json"
    jq -e '
      type == "object" and
      (keys == ["gpg-secret-key", "jupiter-age-key", "login-password", "luks-passphrase", "ssh-private-key"]) and
      all(.[]; type == "string" and length > 0)
    ' "$tmpdir/bootstrap-updated.json" >/dev/null || die '更新後の bootstrap.yaml の形式が不正'
    jq -S '{
      "gpg-secret-key": ."gpg-secret-key",
      "jupiter-age-key": ."jupiter-age-key",
      "ssh-private-key": ."ssh-private-key"
    }' "$tmpdir/bootstrap-current.json" >"$tmpdir/bootstrap-immutable-current.json"
    jq -S '{
      "gpg-secret-key": ."gpg-secret-key",
      "jupiter-age-key": ."jupiter-age-key",
      "ssh-private-key": ."ssh-private-key"
    }' "$tmpdir/bootstrap-updated.json" >"$tmpdir/bootstrap-immutable-updated.json"
    cmp -s "$tmpdir/bootstrap-immutable-current.json" "$tmpdir/bootstrap-immutable-updated.json" || \
      die 'SSH、GPG、Jupiter age key のいずれかが変更された'
  fi

  if [ "$runtime_changed" -eq 1 ]; then
    SOPS_AGE_KEY_FILE="$jupiter_age_key" \
      sops --decrypt --output-type json "$runtime_tmp" >"$tmpdir/runtime-updated.json"
    jq -e '
      type == "object" and
      (keys == ["smb-mars-shishi", "tailscale-oauth-secret"]) and
      (."smb-mars-shishi" | type == "string" and startswith("username=shishi\npassword=") and
        length > ("username=shishi\npassword=" | length)) and
      (."tailscale-oauth-secret" | type == "string" and startswith("tskey-client-") and
        length > ("tskey-client-" | length))
    ' "$tmpdir/runtime-updated.json" >/dev/null || die '更新後の runtime.yaml の形式が不正'
  fi

  if [ "$bootstrap_changed" -eq 1 ]; then
    bootstrap_backup=$(mktemp "secrets/bootstrap.rollback.XXXXXXXX.yaml")
    cp --preserve=mode -- secrets/bootstrap.yaml "$bootstrap_backup"
  fi
  if [ "$runtime_changed" -eq 1 ]; then
    runtime_backup=$(mktemp "secrets/runtime.rollback.XXXXXXXX.yaml")
    cp --preserve=mode -- secrets/runtime.yaml "$runtime_backup"
  fi

  update_started=1
  if [ "$bootstrap_changed" -eq 1 ]; then
    mv -f -- "$bootstrap_tmp" secrets/bootstrap.yaml
    bootstrap_tmp=""
  fi
  if [ "$runtime_changed" -eq 1 ]; then
    mv -f -- "$runtime_tmp" secrets/runtime.yaml
    runtime_tmp=""
  fi
  update_committed=1
  remove_update_backups
  printf 'init-secrets: secret を更新した\n'
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

restore_update_backups() {
  if [ -n "$bootstrap_backup" ] && [ -e "$bootstrap_backup" ]; then
    mv -f -- "$bootstrap_backup" secrets/bootstrap.yaml
    bootstrap_backup=""
  fi
  if [ -n "$runtime_backup" ] && [ -e "$runtime_backup" ]; then
    mv -f -- "$runtime_backup" secrets/runtime.yaml
    runtime_backup=""
  fi
}

remove_update_backups() {
  [ -z "$bootstrap_backup" ] || rm -f -- "$bootstrap_backup"
  [ -z "$runtime_backup" ] || rm -f -- "$runtime_backup"
  bootstrap_backup=""
  runtime_backup=""
}

cleanup() {
  if [ "$installation_started" -eq 1 ] && [ "$installation_committed" -eq 0 ]; then
    rollback_published_output "$staged_sops_config" "$repo_root/.sops.yaml"
    rollback_published_output "$staged_bootstrap" "$repo_root/secrets/bootstrap.yaml"
    rollback_published_output "$staged_runtime" "$repo_root/secrets/runtime.yaml"
  fi
  if [ "$update_started" -eq 1 ] && [ "$update_committed" -eq 0 ]; then
    restore_update_backups
  fi
  remove_update_backups
  remove_staged_outputs
  if [ -n "${tmpdir:-}" ] && [ -d "$tmpdir" ]; then
    rm -rf -- "$tmpdir"
  fi
  if [ -n "${bootstrap_tmp:-}" ] && [ -f "$bootstrap_tmp" ]; then
    rm -f -- "$bootstrap_tmp"
  fi
  if [ -n "${runtime_tmp:-}" ] && [ -f "$runtime_tmp" ]; then
    rm -f -- "$runtime_tmp"
  fi
}

trap cleanup EXIT
trap 'cleanup; exit 1' HUP INT TERM

repo_root=$(find_repo_root)
cd "$repo_root"
acquire_repo_lock
resolve_management_age_key_file

existing_outputs=0
for output in .sops.yaml secrets/bootstrap.yaml secrets/runtime.yaml; do
  if [ -e "$output" ] || [ -L "$output" ]; then
    existing_outputs=$((existing_outputs + 1))
  fi
done

tmpdir=$(mktemp -d "$(select_tmpfs_root)/init-secrets.XXXXXXXX")
if [ "$existing_outputs" -eq 3 ]; then
  update_existing_secrets
  exit 0
fi
[ "$existing_outputs" -eq 0 ] || die '暗号化出力の一部だけが存在するため更新できない'

require_source_keys
generate_age_keys
read_confirmed_secret 'LUKS パスフレーズ' "$tmpdir/luks-passphrase"
validate_primary_credential_file 'LUKS パスフレーズ' "$tmpdir/luks-passphrase"
read_confirmed_secret 'ログインパスワード' "$tmpdir/login-password"
validate_primary_credential_file 'ログインパスワード' "$tmpdir/login-password"
read_confirmed_secret 'SMB パスワード' "$tmpdir/smb-password"
read_confirmed_secret 'Tailscale OAuth client secret' "$tmpdir/tailscale-oauth-secret"
validate_tailscale_oauth_client_secret "$tmpdir/tailscale-oauth-secret"
write_plaintext_json
encrypt_outputs

printf 'init-secrets: 暗号化済み secrets を作成した\n'
