#!/usr/bin/env bash

set -eEuo pipefail
umask 077

repo_root=""
tmpdir=""
management_age_key_file=""
bootstrap_json=""
luks_key=""
login_password=""
ssh_private_key=""
ssh_public_key=""
gpg_secret_key=""
jupiter_age_key=""
password_hash=""
extra_files=""
run_disko=0
run_install=0
phase_specified=0
primary_credential_min_chars=15
primary_credential_max_chars=128
original_args=()

die() {
  printf 'nixos-anywhere-with-secrets: %s\n' "$*" >&2
  exit 1
}

resolve_management_age_key_file() {
  if [ -n "${SOPS_AGE_KEY_FILE:-}" ]; then
    management_age_key_file="$SOPS_AGE_KEY_FILE"
  else
    management_age_key_file="$repo_root/secrets/management-age-key.txt"
  fi
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

reject_manual_secret_args() {
  local arg

  for arg in "$@"; do
    case "$arg" in
      --extra-files|--extra-files=*)
        die 'wrapper manages --extra-files; remove --extra-files'
        ;;
      --disk-encryption-keys|--disk-encryption-keys=*)
        die 'wrapper manages --disk-encryption-keys; remove --disk-encryption-keys'
        ;;
    esac
  done
}

add_phases() {
  local phases=$1 phase
  local -a values=()

  IFS=, read -r -a values <<<"$phases"
  for phase in "${values[@]}"; do
    case "$phase" in
      disko) run_disko=1 ;;
      install) run_install=1 ;;
    esac
  done
}

parse_phases() {
  local index=0 arg

  original_args=("$@")
  while [ "$index" -lt "$#" ]; do
    arg=${original_args[index]}
    case "$arg" in
      --phases)
        [ "$phase_specified" -eq 0 ] || die '--phases は 1 回だけ指定すること'
        index=$((index + 1))
        [ "$index" -lt "$#" ] || die '--phases の値が無い'
        phase_specified=1
        add_phases "${original_args[index]}"
        ;;
      --phases=*)
        [ "$phase_specified" -eq 0 ] || die '--phases は 1 回だけ指定すること'
        phase_specified=1
        add_phases "${arg#--phases=}"
        ;;
    esac
    index=$((index + 1))
  done

  if [ "$phase_specified" -eq 0 ]; then
    run_disko=1
    run_install=1
  fi
}

require_tracked_ciphertext() {
  git -C "$repo_root" ls-files --error-unmatch -- secrets/bootstrap.yaml >/dev/null 2>&1 || \
    die 'secrets/bootstrap.yaml が Git で追跡されていない'
  git -C "$repo_root" ls-files --error-unmatch -- secrets/runtime.yaml >/dev/null 2>&1 || \
    die 'secrets/runtime.yaml が Git で追跡されていない'
}

decrypt_bootstrap() {
  local sops_home="$tmpdir/sops-home" sops_config_home="$tmpdir/sops-config"

  [ -f "$management_age_key_file" ] || die 'management age key が読めない'
  mkdir -p "$sops_home" "$sops_config_home"

  bootstrap_json="$tmpdir/bootstrap.json"
  HOME="$sops_home" \
  XDG_CONFIG_HOME="$sops_config_home" \
  SOPS_AGE_KEY_FILE="$management_age_key_file" \
    sops --decrypt --output-type json "$repo_root/secrets/bootstrap.yaml" >"$bootstrap_json" || \
    die 'bootstrap.yaml を復号・検証できない'
}

extract_json_file() {
  local key=$1 destination=$2

  jq -ej --arg key "$key" 'if (.[$key] | type) == "string" and .[$key] != "" then .[$key] else error("missing secret") end' \
    "$bootstrap_json" >"$destination" || die "bootstrap.yaml の $key が無効"
  chmod 600 "$destination"
}

validate_primary_credential_file() {
  local label=$1 file=$2 length

  length=$(jq -Rs 'length' "$file")
  if [ "$length" -lt "$primary_credential_min_chars" ] || \
    [ "$length" -gt "$primary_credential_max_chars" ]; then
    die "$label は${primary_credential_min_chars}文字以上${primary_credential_max_chars}文字以下にすること"
  fi
}

extract_and_validate() {
  luks_key="$tmpdir/luks.key"
  login_password="$tmpdir/login-password"
  ssh_private_key="$tmpdir/id_ed25519"
  ssh_public_key="$tmpdir/id_ed25519.pub"
  gpg_secret_key="$tmpdir/gpg-secret.asc"
  jupiter_age_key="$tmpdir/jupiter-age-key.txt"
  password_hash="$tmpdir/shishi-password-hash"

  extract_json_file luks-passphrase "$luks_key"
  extract_json_file login-password "$login_password"
  extract_json_file ssh-private-key "$ssh_private_key"
  extract_json_file gpg-secret-key "$gpg_secret_key"
  extract_json_file jupiter-age-key "$jupiter_age_key"

  validate_primary_credential_file 'LUKS パスフレーズ' "$luks_key"
  validate_primary_credential_file 'ログインパスワード' "$login_password"

  ssh-keygen -y -f "$ssh_private_key" >"$ssh_public_key" 2>/dev/null || \
    die 'bootstrap.yaml の SSH 秘密鍵が無効'
  chmod 644 "$ssh_public_key"
  gpg --batch --list-packets "$gpg_secret_key" 2>/dev/null | grep -q ':secret key packet:' || \
    die 'bootstrap.yaml の GPG 秘密鍵が無効'
  age-keygen -y "$jupiter_age_key" >/dev/null 2>&1 || \
    die 'bootstrap.yaml の Jupiter age 鍵が無効'

  mkpasswd -m yescrypt -s <"$login_password" >"$password_hash" || \
    die 'ログインパスワードの yescrypt ハッシュを生成できない'
  grep -q '^\$y\$' "$password_hash" || die 'mkpasswd が yescrypt ハッシュを返さない'
  chmod 600 "$password_hash"
}

build_extra_files() {
  extra_files="$tmpdir/extra-files"
  mkdir -p \
    "$extra_files/home/shishi/.ssh" \
    "$extra_files/var/lib/secrets" \
    "$extra_files/var/lib/sops-nix"
  chmod 755 "$extra_files" "$extra_files/home" "$extra_files/var" "$extra_files/var/lib"
  chmod 700 "$extra_files/home/shishi" "$extra_files/home/shishi/.ssh" "$extra_files/var/lib/secrets" "$extra_files/var/lib/sops-nix"
  install -m 600 "$ssh_private_key" "$extra_files/home/shishi/.ssh/id_ed25519"
  install -m 644 "$ssh_public_key" "$extra_files/home/shishi/.ssh/id_ed25519.pub"
  install -m 600 "$gpg_secret_key" "$extra_files/home/shishi/gpg-secret.asc"
  install -m 600 "$password_hash" "$extra_files/var/lib/secrets/shishi-password-hash"
  install -m 600 "$jupiter_age_key" "$extra_files/var/lib/sops-nix/key.txt"
}

validate_runtime_secret() {
  SOPS_AGE_KEY_FILE="$jupiter_age_key" \
    sops --decrypt --output-type json "$repo_root/secrets/runtime.yaml" | \
    jq -e '
      type == "object" and
      (keys == ["smb-mars-shishi", "tailscale-oauth-secret"]) and
      (."smb-mars-shishi" | type == "string") and
      (."smb-mars-shishi" | startswith("username=shishi\npassword=")) and
      (."smb-mars-shishi" | length > ("username=shishi\npassword=" | length)) and
      (."tailscale-oauth-secret" | type == "string") and
      (."tailscale-oauth-secret" | startswith("tskey-client-")) and
      (."tailscale-oauth-secret" | length > ("tskey-client-" | length))
    ' >/dev/null || die 'runtime.yaml を Jupiter 鍵で復号・検証できない'
}

run_nixos_anywhere() {
  local -a command_args=("${original_args[@]}")

  [ -n "${NIXOS_ANYWHERE_BIN:-}" ] || die 'NIXOS_ANYWHERE_BIN を指定すること'
  [ -x "$NIXOS_ANYWHERE_BIN" ] || die 'NIXOS_ANYWHERE_BIN を実行できない'

  if [ "$run_disko" -eq 1 ]; then
    command_args+=(--disk-encryption-keys /tmp/secret.key "$luks_key")
  fi
  if [ "$run_install" -eq 1 ]; then
    command_args+=(--extra-files "$extra_files" --chown home/shishi 1000:100)
  fi

  "$NIXOS_ANYWHERE_BIN" "${command_args[@]}"
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

trap cleanup EXIT
trap 'exit 1' HUP INT TERM

repo_root=$(find_repo_root)
cd "$repo_root"
resolve_management_age_key_file
reject_manual_secret_args "$@"
parse_phases "$@"
require_tracked_ciphertext
tmpdir=$(mktemp -d "$(select_tmpfs_root)/nixos-anywhere-secrets.XXXXXXXX")
decrypt_bootstrap
extract_and_validate

if [ "$run_install" -eq 1 ]; then
  build_extra_files
  validate_runtime_secret
fi

if run_nixos_anywhere; then
  exit 0
else
  exit "$?"
fi
