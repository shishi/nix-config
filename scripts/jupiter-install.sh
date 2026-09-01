#!/usr/bin/env bash
#
# nixos-anywhere を disko(ディスク全消去 + LUKS 鍵の注入)→ 対象機上での鍵生成 →
# install(SSH/GPG 鍵・パスワードハッシュ・sops 鍵の配送 + NixOS 本体)の固定順で
# 実行する。lanzaboote の lzbt install が /var/lib/sbctl の署名鍵を要求するため、
# sbctl 鍵と initrd SSH ホスト鍵は install の前に対象機上で生成して /mnt へ置く
# (秘密鍵はワークステーションを経由しない)。順序は wrapper が所有し、
# --phases は受け付けない(docs/jupiter-install-runbook.md)。

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
target_host=""
ssh_port=""
primary_credential_min_chars=15
primary_credential_max_chars=128
original_args=()

die() {
  printf 'jupiter-install: %s\n' "$*" >&2
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

reject_managed_args() {
  local arg

  for arg in "$@"; do
    case "$arg" in
      --flake|--flake=*|--store-paths|--store-paths=*)
        die 'Jupiter の構成は wrapper が固定するため指定しないこと'
        ;;
      --extra-files|--extra-files=*)
        die 'wrapper manages --extra-files; remove --extra-files'
        ;;
      --disk-encryption-keys|--disk-encryption-keys=*)
        die 'wrapper manages --disk-encryption-keys; remove --disk-encryption-keys'
        ;;
      --ssh-option|--ssh-option=*)
        die 'SSH host key の扱いは wrapper が固定するため --ssh-option は指定しないこと'
        ;;
      --phases|--phases=*)
        die 'インストールの順序(disko → 鍵生成 → install)は wrapper が固定するため --phases は指定しないこと'
        ;;
    esac
  done
}

parse_arguments() {
  local index=0 arg

  original_args=("$@")
  while [ "$index" -lt "$#" ]; do
    arg=${original_args[index]}
    case "$arg" in
      --target-host)
        index=$((index + 1))
        [ "$index" -lt "$#" ] || die '--target-host の値が無い'
        target_host=${original_args[index]}
        ;;
      --target-host=*)
        target_host=${arg#--target-host=}
        ;;
      --ssh-port)
        index=$((index + 1))
        [ "$index" -lt "$#" ] || die '--ssh-port の値が無い'
        ssh_port=${original_args[index]}
        ;;
      --ssh-port=*)
        ssh_port=${arg#--ssh-port=}
        ;;
    esac
    index=$((index + 1))
  done

  [ -n "$target_host" ] || \
    die 'インストール先を --target-host root@<target> で指定すること(手順は docs/jupiter-install-runbook.md)'
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
  local label=$1 file=$2 contains_control length

  length=$(jq -Rs 'length' "$file")
  if [ "$length" -lt "$primary_credential_min_chars" ] || \
    [ "$length" -gt "$primary_credential_max_chars" ]; then
    die "$label は${primary_credential_min_chars}文字以上${primary_credential_max_chars}文字以下にすること"
  fi
  contains_control=$(jq -Rs 'test("\\p{Cc}")' "$file")
  [ "$contains_control" = false ] || die "$label に制御文字は使えない"
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
  # shellcheck disable=SC2016 # yescrypt prefix のリテラルを検査する。
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

target_ssh() {
  # インストーラーのホスト鍵は起動ごとに作り直される使い捨てで、照合する対象が無い。
  # known_hosts へ記録すると、インストーラー再起動後とインストール後の接続が
  # HOST IDENTIFICATION CHANGED で拒否されるため記録しない。
  local -a ssh_args=(-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no)

  [ -z "$ssh_port" ] || ssh_args+=(-p "$ssh_port")
  # shellcheck disable=SC2029 # 渡すのはリテラルのコマンド文字列で、クライアント側展開は意図どおり。
  ssh "${ssh_args[@]}" "$target_host" "$@"
}

# lanzaboote の lzbt install は /var/lib/sbctl の鍵で boot entry を署名し、
# initrd SSH ホスト鍵は boot.initrd.secrets が /mnt から initrd へ取り込む。
# どちらも install の前に /mnt に存在する必要があり、秘密鍵は対象機の外へ出さない。
generate_target_keys() {
  target_ssh 'rm -rf /var/lib/sbctl && nix --extra-experimental-features "nix-command flakes" run nixpkgs#sbctl -- create-keys && mkdir -p /mnt/var/lib && cp -a /var/lib/sbctl /mnt/var/lib/ && mkdir -p /mnt/var/lib/initrd-ssh && ssh-keygen -t ed25519 -N "" -f /mnt/var/lib/initrd-ssh/ssh_host_ed25519_key && chmod 600 /mnt/var/lib/initrd-ssh/ssh_host_ed25519_key' || \
    die '対象機での Secure Boot 鍵と initrd SSH ホスト鍵の生成に失敗した'
  printf 'jupiter-install: initrd SSH ホスト鍵の fingerprint(復旧時の照合用。Jupiter 以外から読める場所へ保存する):\n'
  target_ssh 'ssh-keygen -lf /mnt/var/lib/initrd-ssh/ssh_host_ed25519_key.pub' || \
    die 'initrd SSH ホスト鍵の fingerprint を取得できない'
}

run_nixos_anywhere() {
  local phase=$1
  local -a command_args=(
    --flake .#jupiter
    "${original_args[@]}"
    --phases "$phase"
    --ssh-option UserKnownHostsFile=/dev/null
    --ssh-option StrictHostKeyChecking=no
  )

  [ -n "${NIXOS_ANYWHERE_BIN:-}" ] || die 'NIXOS_ANYWHERE_BIN を指定すること'
  [ -x "$NIXOS_ANYWHERE_BIN" ] || die 'NIXOS_ANYWHERE_BIN を実行できない'

  if [ "$phase" = disko ]; then
    command_args+=(--disk-encryption-keys /tmp/secret.key "$luks_key")
  else
    command_args+=(--extra-files "$extra_files" --chown home/shishi 1000:100)
  fi

  "$NIXOS_ANYWHERE_BIN" "${command_args[@]}"
}

# shellcheck disable=SC2329 # EXIT/HUP/INT/TERM trap から呼ぶ。
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
reject_managed_args "$@"
parse_arguments "$@"
require_tracked_ciphertext
tmpdir=$(mktemp -d "$(select_tmpfs_root)/jupiter-install.XXXXXXXX")
decrypt_bootstrap
extract_and_validate
build_extra_files
validate_runtime_secret

run_nixos_anywhere disko
generate_target_keys
run_nixos_anywhere install
