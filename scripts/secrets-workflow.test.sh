#!/usr/bin/env bash

set -euo pipefail

case "${1:-}" in
  all)
    for suite in init wrapper gpg-import; do
      bash "${BASH_SOURCE[0]}" "$suite"
    done
    echo "all secrets workflow tests: PASS"
    exit 0
    ;;
  init|wrapper|gpg-import) suite=$1 ;;
  *)
    echo "usage: $0 {all|init|wrapper|gpg-import}" >&2
    exit 64
    ;;
esac

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d)
test_home="$work/home"
repo="$work/repo"
test_bash=$(command -v bash)

cleanup() {
  rm -rf -- "$work"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_file() {
  test -s "$1" || fail "expected nonempty file: $1"
}

assert_absent_outputs() {
  test ! -e "$repo/secrets/jupiter/.sops.yaml" || fail ".sops.yaml must not exist after failure"
  test ! -e "$repo/secrets/jupiter/bootstrap.yaml" || fail "bootstrap output must not exist after failure"
  test ! -e "$repo/secrets/jupiter/runtime.yaml" || fail "runtime output must not exist after failure"
}

reset_fixture() {
  rm -rf -- "$repo" "$test_home"
  mkdir -p "$repo" "$test_home"
}

copy_fixture_repo() {
  mkdir -p "$repo/scripts" "$repo/secrets/jupiter"
  cp "$repo_root/.gitignore" "$repo/.gitignore"
  cp "$repo_root/flake.nix" "$repo/flake.nix"
  cp "$repo_root/scripts/jupiter-secrets.sh" "$repo/scripts/jupiter-secrets.sh"
  chmod +x "$repo/scripts/jupiter-secrets.sh"
}

copy_wrapper_script_if_present() {
  if [ -f "$repo_root/scripts/jupiter-install.sh" ]; then
    cp "$repo_root/scripts/jupiter-install.sh" "$repo/scripts/jupiter-install.sh"
    chmod +x "$repo/scripts/jupiter-install.sh"
  fi
}

prepare_source_keys() {
  local signing_key

  mkdir -p "$test_home/.ssh" "$test_home/.gnupg"
  chmod 700 "$test_home/.gnupg"
  ssh-keygen -q -t ed25519 -N '' -f "$test_home/.ssh/id_ed25519"
  HOME="$test_home" GNUPGHOME="$test_home/.gnupg" \
    gpg --batch --pinentry-mode loopback --passphrase '' \
    --quick-generate-key 'Secrets Workflow Test <secrets-workflow@example.test>' default default never
  signing_key=$(HOME="$test_home" GNUPGHOME="$test_home/.gnupg" \
    gpg --batch --with-colons --list-secret-keys \
    secrets-workflow@example.test | awk -F: '$1 == "fpr" { print $10; exit }')
  test -n "$signing_key" || fail "failed to discover fixture GPG signing key"
  HOME="$test_home" GNUPGHOME="$test_home/.gnupg" \
    gpg --batch --armor --export-secret-keys "$signing_key" >"$work/fixture-gpg-secret.asc"
  assert_file "$work/fixture-gpg-secret.asc"
  HOME="$test_home" git config --global user.signingkey "$signing_key"
}

run_init_from_stdin() {
  (
    cd "$repo"
    HOME="$test_home" \
    GNUPGHOME="$test_home/.gnupg" \
    SOPS_AGE_KEY_FILE="$test_home/.config/sops/age/keys.txt" \
      bash scripts/jupiter-secrets.sh
  )
}

run_init() {
  run_init_from_stdin <<'EOF'
luks-test-value
luks-test-value
login-test-value
login-test-value
smb-test-value
smb-test-value
tskey-client-test-value
tskey-client-test-value
EOF
}

run_init_with_oauth_secret() {
  local oauth_secret=$1

  (
    cd "$repo"
    HOME="$test_home" \
    GNUPGHOME="$test_home/.gnupg" \
    SOPS_AGE_KEY_FILE="$test_home/.config/sops/age/keys.txt" \
      bash scripts/jupiter-secrets.sh
  ) <<EOF
luks-test-value
luks-test-value
login-test-value
login-test-value
smb-test-value
smb-test-value
$oauth_secret
$oauth_secret
EOF
}

run_mismatched_init() {
  (
    cd "$repo"
    HOME="$test_home" \
    GNUPGHOME="$test_home/.gnupg" \
    SOPS_AGE_KEY_FILE="$test_home/.config/sops/age/keys.txt" \
      bash scripts/jupiter-secrets.sh
  ) <<'EOF'
luks-test-value
different-luks-test-value
EOF
}

run_init_with_xdg_config_home() {
  (
    cd "$repo"
    HOME="$test_home" \
    GNUPGHOME="$test_home/.gnupg" \
    XDG_CONFIG_HOME="$test_home/other-config" \
      bash scripts/jupiter-secrets.sh
  ) <<'EOF'
luks-test-value
luks-test-value
login-test-value
login-test-value
smb-test-value
smb-test-value
tskey-client-test-value
tskey-client-test-value
EOF
}

run_init_with_publish_race() {
  local real_ln

  real_ln=$(command -v ln)
  mkdir -p "$work/publish-race-bin"
  printf '%s\n' \
    "#!$test_bash" \
    'set -euo pipefail' \
    'if [ "$1" = -T ] && [ "$3" = "$RACE_FINAL" ]; then' \
    '  rm -f -- "$RACE_REPLACED_FINAL"' \
    '  printf "competing-sops-ciphertext\\n" >"$RACE_REPLACED_FINAL"' \
    '  printf "competing-runtime-ciphertext\\n" >"$3"' \
    'fi' \
    'exec "$REAL_LN" "$@"' >"$work/publish-race-bin/ln"
  chmod 700 "$work/publish-race-bin/ln"

  (
    cd "$repo"
    HOME="$test_home" \
    GNUPGHOME="$test_home/.gnupg" \
    SOPS_AGE_KEY_FILE="$test_home/.config/sops/age/keys.txt" \
    PATH="$work/publish-race-bin:$PATH" \
    REAL_LN="$real_ln" \
    RACE_FINAL="$repo/secrets/jupiter/runtime.yaml" \
    RACE_REPLACED_FINAL="$repo/secrets/jupiter/.sops.yaml" \
      bash scripts/jupiter-secrets.sh
  ) <<'EOF'
luks-test-value
luks-test-value
login-test-value
login-test-value
smb-test-value
smb-test-value
tskey-client-test-value
tskey-client-test-value
EOF
}

test_missing_ssh_key_fails_before_input() {
  copy_fixture_repo
  if (
    cd "$repo"
    HOME="$test_home" \
    GNUPGHOME="$test_home/.gnupg" \
    SOPS_AGE_KEY_FILE="$test_home/.config/sops/age/keys.txt" \
      bash scripts/jupiter-secrets.sh
  ) </dev/null >"$work/stdout" 2>"$work/stderr"; then
    fail "initializer unexpectedly accepted a missing SSH key"
  fi
  assert_absent_outputs
}

test_mismatched_confirmation_leaves_no_outputs() {
  copy_fixture_repo
  prepare_source_keys
  if run_mismatched_init >"$work/stdout" 2>"$work/stderr"; then
    fail "initializer unexpectedly accepted mismatched confirmation"
  fi
  assert_absent_outputs
}

test_existing_ciphertext_is_not_overwritten() {
  copy_fixture_repo
  prepare_source_keys
  printf 'existing-ciphertext\n' >"$repo/secrets/jupiter/.sops.yaml"
  if run_init >"$work/stdout" 2>"$work/stderr"; then
    fail "initializer unexpectedly overwrote existing ciphertext"
  fi
  test "$(cat "$repo/secrets/jupiter/.sops.yaml")" = 'existing-ciphertext' || fail "existing ciphertext changed"
  test ! -e "$repo/secrets/jupiter/bootstrap.yaml" || fail "bootstrap was created despite existing output"
  test ! -e "$repo/secrets/jupiter/runtime.yaml" || fail "runtime was created despite existing output"
}

test_dangling_symlink_is_not_overwritten() {
  copy_fixture_repo
  prepare_source_keys
  ln -s missing-sops-config "$repo/secrets/jupiter/.sops.yaml"
  if run_init >"$work/stdout" 2>"$work/stderr"; then
    fail "initializer unexpectedly overwrote a dangling symlink"
  fi
  test -L "$repo/secrets/jupiter/.sops.yaml" || fail "dangling symlink was replaced"
  test "$(readlink "$repo/secrets/jupiter/.sops.yaml")" = missing-sops-config || fail "dangling symlink changed"
  test ! -e "$repo/secrets/jupiter/bootstrap.yaml" || fail "bootstrap was created despite dangling symlink"
  test ! -e "$repo/secrets/jupiter/runtime.yaml" || fail "runtime was created despite dangling symlink"
}

test_default_management_key_is_created_in_repository() {
  copy_fixture_repo
  prepare_source_keys
  if ! run_init_with_xdg_config_home >"$work/stdout" 2>"$work/stderr"; then
    fail "initializer failed with XDG_CONFIG_HOME set"
  fi
  assert_file "$repo/secrets/management-age-key.txt"
  test "$(stat -c %a "$repo/secrets/management-age-key.txt")" = 600 || \
    fail "repository-local management age key mode is not 600"
  git -C "$repo" init -q
  git -C "$repo" check-ignore -q -- secrets/management-age-key.txt || \
    fail "repository-local management age key is not ignored by Git"
  test ! -e "$test_home/.config/sops/age/keys.txt" || fail "initializer used the old management key path"
  test ! -e "$test_home/other-config/sops/age/keys.txt" || fail "XDG_CONFIG_HOME changed the default management key path"
}

test_failed_installation_rolls_back_outputs() {
  copy_fixture_repo
  prepare_source_keys
  chmod 500 "$repo/secrets/jupiter"
  if run_init >"$work/stdout" 2>"$work/stderr"; then
    fail "initializer unexpectedly succeeded with an unwritable output directory"
  fi
  chmod 700 "$repo/secrets/jupiter"
  assert_absent_outputs
}

test_publish_race_preserves_competing_entry() {
  copy_fixture_repo
  prepare_source_keys
  if run_init_with_publish_race >"$work/stdout" 2>"$work/stderr"; then
    fail "initializer unexpectedly succeeded despite a publish race"
  fi
  if [ ! -f "$repo/secrets/jupiter/.sops.yaml" ] || [ "$(cat "$repo/secrets/jupiter/.sops.yaml")" != competing-sops-ciphertext ]; then
    sed 's/^/initializer stderr: /' "$work/stderr" >&2
    fail "replacement entry was deleted or overwritten"
  fi
  test ! -e "$repo/secrets/jupiter/bootstrap.yaml" || fail "initializer bootstrap output remained after publish race"
  test "$(cat "$repo/secrets/jupiter/runtime.yaml")" = competing-runtime-ciphertext || fail "competing entry was overwritten"
}

test_concurrent_initializer_is_rejected_before_input() {
  local lock_fd

  copy_fixture_repo
  prepare_source_keys
  mkdir -p "$repo/secrets/jupiter"
  exec {lock_fd}>"$repo/secrets/jupiter/.jupiter-secrets.lock"
  flock -n "$lock_fd" || fail "test could not acquire the initializer lock"
  if run_init >"$work/stdout" 2>"$work/stderr"; then
    fail "initializer ignored an existing repository lock"
  fi
  exec {lock_fd}>&-
  rg -F '別の jupiter-secrets が実行中' "$work/stderr" >/dev/null || \
    fail "initializer lock failure did not report a controlled error"
  assert_absent_outputs
}

test_short_luks_passphrase_is_rejected() {
  copy_fixture_repo
  prepare_source_keys
  if run_init_from_stdin >"$work/stdout" 2>"$work/stderr" <<'EOF'
short
short
EOF
  then
    fail "initializer accepted a short LUKS passphrase"
  fi
  if ! rg -F 'LUKS パスフレーズ は15文字以上128文字以下' "$work/stderr" >/dev/null; then
    sed 's/^/initializer stderr: /' "$work/stderr" >&2
    fail "short LUKS passphrase did not report the length policy"
  fi
  ! rg -F 'short' "$work/stdout" "$work/stderr" || fail "initializer logged the rejected LUKS passphrase"
  assert_absent_outputs
}

test_control_character_in_luks_passphrase_is_rejected() {
  local credential=$'long-enough\tvalue'

  copy_fixture_repo
  prepare_source_keys
  if printf '%s\n%s\n' "$credential" "$credential" | \
    run_init_from_stdin >"$work/stdout" 2>"$work/stderr"; then
    fail "initializer accepted a LUKS passphrase containing a control character"
  fi
  if ! rg -F 'LUKS パスフレーズ に制御文字は使えない' "$work/stderr" >/dev/null; then
    sed 's/^/initializer stderr: /' "$work/stderr" >&2
    fail "control character in LUKS passphrase did not report the policy"
  fi
  ! rg -F "$credential" "$work/stdout" "$work/stderr" || \
    fail "initializer logged the rejected LUKS passphrase"
  assert_absent_outputs
}

test_successful_initialization_encrypts_expected_boundaries() {
  copy_fixture_repo
  prepare_source_keys
  if ! run_init >"$work/stdout" 2>"$work/stderr"; then
    fail "successful initializer run failed"
  fi

  assert_file "$repo/secrets/jupiter/.sops.yaml"
  assert_file "$repo/secrets/jupiter/bootstrap.yaml"
  assert_file "$repo/secrets/jupiter/runtime.yaml"
  rg -F "path_regex: '(^|/)bootstrap\\.yaml\$'" "$repo/secrets/jupiter/.sops.yaml" >/dev/null || fail "bootstrap creation rule is missing"
  rg -F "path_regex: '(^|/)runtime\\.yaml\$'" "$repo/secrets/jupiter/.sops.yaml" >/dev/null || fail "runtime creation rule is missing"
  ! rg -F 'AGE-SECRET-KEY-' "$repo/secrets/jupiter/.sops.yaml" || fail "SOPS config contains a private age key"
  test "$(stat -c %a "$test_home/.config/sops/age/keys.txt")" = 600 || fail "management age key mode is not 600"
  ! rg -F -e 'luks-test-value' -e 'login-test-value' -e 'smb-test-value' -e 'tskey-client-test-value' \
    "$repo/secrets/jupiter/.sops.yaml" "$repo/secrets" || fail "ciphertext contains a fixture secret"
  ! rg -F -e 'luks-test-value' -e 'login-test-value' -e 'smb-test-value' -e 'tskey-client-test-value' \
    "$work/stdout" "$work/stderr" || fail "logs contain a fixture secret"

  SOPS_AGE_KEY_FILE="$test_home/.config/sops/age/keys.txt" \
    sops --decrypt --output-type json "$repo/secrets/jupiter/bootstrap.yaml" >"$work/bootstrap.json"
  jq -e '
    keys == ["gpg-secret-key", "jupiter-age-key", "login-password", "luks-passphrase", "ssh-private-key"] and
    .["luks-passphrase"] == "luks-test-value" and
    .["login-password"] == "login-test-value" and
    (.["ssh-private-key"] | length > 0) and
    (.["gpg-secret-key"] | length > 0) and
    (.["jupiter-age-key"] | length > 0)
  ' "$work/bootstrap.json" >/dev/null || fail "bootstrap plaintext shape is incorrect"
  jq -r '.["jupiter-age-key"]' "$work/bootstrap.json" >"$work/jupiter-age-key.txt"
  chmod 600 "$work/jupiter-age-key.txt"

  SOPS_AGE_KEY_FILE="$work/jupiter-age-key.txt" \
    sops --decrypt --output-type json "$repo/secrets/jupiter/runtime.yaml" >"$work/runtime.json"
  jq -e '. == {
    "smb-mars-shishi": "username=shishi\npassword=smb-test-value",
    "tailscale-oauth-secret": "tskey-client-test-value"
  }' \
    "$work/runtime.json" >/dev/null || fail "runtime plaintext shape is incorrect"

  age-keygen -o "$work/unrelated-age-key.txt" >/dev/null 2>&1
  if SOPS_AGE_KEY_FILE="$work/unrelated-age-key.txt" \
    sops --decrypt "$repo/secrets/jupiter/bootstrap.yaml" >/dev/null 2>"$work/unrelated-bootstrap.stderr"; then
    fail "unrelated key decrypted bootstrap ciphertext"
  fi
  if SOPS_AGE_KEY_FILE="$test_home/.config/sops/age/keys.txt" \
    sops --decrypt "$repo/secrets/jupiter/runtime.yaml" >/dev/null 2>"$work/management-runtime.stderr"; then
    fail "management key decrypted runtime ciphertext"
  fi
  if SOPS_AGE_KEY_FILE="$work/jupiter-age-key.txt" \
    sops --decrypt "$repo/secrets/jupiter/bootstrap.yaml" >/dev/null 2>"$work/jupiter-bootstrap.stderr"; then
    fail "Jupiter key decrypted bootstrap ciphertext"
  fi
}

test_initialization_rejects_non_oauth_client_secrets() {
  local oauth_secret

  for oauth_secret in client-id-value tskey-auth-test-value tskey-client-; do
    reset_fixture
    copy_fixture_repo
    prepare_source_keys
    if run_init_with_oauth_secret "$oauth_secret" >"$work/stdout" 2>"$work/stderr"; then
      fail "initializer accepted a non-OAuth-client secret: $oauth_secret"
    fi
    assert_absent_outputs
    if [ "$oauth_secret" != tskey-client- ]; then
      ! rg -F -- "$oauth_secret" "$work/stdout" "$work/stderr" || \
        fail "initializer logged a rejected OAuth value"
    fi
  done
}

prepare_wrapper_fixture() {
  copy_fixture_repo
  copy_wrapper_script_if_present
  prepare_source_keys
  run_init >"$work/init.stdout" 2>"$work/init.stderr" || fail "failed to prepare wrapper fixture"
  (
    cd "$repo"
    git init -q
    git config user.email secrets-workflow@example.test
    git config user.name 'Secrets Workflow Test'
    git add flake.nix scripts/jupiter-secrets.sh secrets/jupiter/.sops.yaml
    git add -f secrets/jupiter/bootstrap.yaml secrets/jupiter/runtime.yaml
    git commit -qm fixture
  )
}

make_fake_nixos_anywhere() {
  mkdir -p "$work/fake-bin"
  printf '#!%s\n' "$test_bash" >"$work/fake-bin/nixos-anywhere"
  cat >>"$work/fake-bin/nixos-anywhere" <<'EOF'
set -euo pipefail

args_log=${FAKE_ARGS_LOG:?}
extra_path_log=${FAKE_EXTRA_PATH_LOG:?}

# 期待する配送物は FAKE_EXTRA_SPEC(path:mode の行)で上書きできる。
# 既定は jupiter の配送物。dns-osaka-1 のテストが自分の配送物を渡す。
jupiter_extra_spec='home/shishi/.ssh/id_ed25519:600
home/shishi/.ssh/id_ed25519.pub:644
home/shishi/gpg-secret.asc:600
var/lib/secrets/shishi-password-hash:600
var/lib/sops-nix/key.txt:600'

check_extra_files() {
  local extra=$1 path mode hash
  printf '%s\n' "$extra" >"$extra_path_log"
  while IFS=: read -r path mode; do
    [ -n "$path" ] || continue
    test "$(stat -c %a "$extra/$path")" = "$mode" || { printf '%s\n' 'fake extra-files mode mismatch' >&2; exit 91; }
  done <<<"${FAKE_EXTRA_SPEC:-$jupiter_extra_spec}"
  # jupiter spec は上の loop がハッシュファイルの存在を強制する(stat が落ちる)ので、
  # この分岐で jupiter 側の検査が弱まることはない。
  if [ -e "$extra/var/lib/secrets/shishi-password-hash" ]; then
    hash=$(head -c 3 "$extra/var/lib/secrets/shishi-password-hash")
    test "$hash" = '$y$' || { printf '%s\n' 'fake password hash is not yescrypt' >&2; exit 92; }
  fi
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --extra-files)
      printf '%s\n' --extra-files >>"$args_log"
      check_extra_files "$2"
      shift 2
      ;;
    --disk-encryption-keys)
      printf '%s\n' --disk-encryption-keys "$2" >>"$args_log"
      test "$(stat -c %a "$3")" = 600 || exit 93
      shift 3
      ;;
    --chown)
      printf '%s\n' --chown "$2" "$3" >>"$args_log"
      shift 3
      ;;
    --phases)
      printf '%s\n' --phases "$2" >>"$args_log"
      shift 2
      ;;
    --ssh-option)
      printf '%s\n' --ssh-option "$2" >>"$args_log"
      shift 2
      ;;
    --copy-host-keys)
      printf '%s\n' --copy-host-keys >>"$args_log"
      shift
      ;;
    *)
      shift
      ;;
  esac
done

exit "${FAKE_NIXOS_ANYWHERE_STATUS:-0}"
EOF
  chmod 700 "$work/fake-bin/nixos-anywhere"

  printf '#!%s\n' "$test_bash" >"$work/fake-bin/ssh"
  cat >>"$work/fake-bin/ssh" <<'EOF'
set -euo pipefail
printf 'ssh %s\n' "$*" >>"${FAKE_ARGS_LOG:?}"
case "$*" in
  *'ssh-keygen -lf'*) printf '256 SHA256:fake-fingerprint root@installer (ED25519)\n' ;;
esac
EOF
  chmod 700 "$work/fake-bin/ssh"

  printf '#!%s\n' "$test_bash" >"$work/fake-bin/ssh-copy-id"
  cat >>"$work/fake-bin/ssh-copy-id" <<'EOF'
set -euo pipefail
printf 'ssh-copy-id %s\n' "$*" >>"${FAKE_ARGS_LOG:?}"
EOF
  chmod 700 "$work/fake-bin/ssh-copy-id"
}

# --target-host / --ssh-port は helper が供給する。追加引数は "$@" で後置する。
run_wrapper() {
  : >"$work/fake.args"
  : >"$work/fake.extra-path"
  (
    cd "$repo"
    HOME="$test_home" \
    GNUPGHOME="$test_home/.gnupg" \
    SOPS_AGE_KEY_FILE="$test_home/.config/sops/age/keys.txt" \
    NIXOS_ANYWHERE_BIN="$work/fake-bin/nixos-anywhere" \
    FAKE_ARGS_LOG="$work/fake.args" \
    FAKE_EXTRA_PATH_LOG="$work/fake.extra-path" \
    PATH="$work/fake-bin:$PATH" \
      bash scripts/jupiter-install.sh --target-host root@fake-target --ssh-port 2222 "$@"
  )
}

# --target-host を渡さずに素で起動する(必須引数の検査用)。
run_wrapper_raw() {
  : >"$work/fake.args"
  : >"$work/fake.extra-path"
  (
    cd "$repo"
    HOME="$test_home" \
    GNUPGHOME="$test_home/.gnupg" \
    SOPS_AGE_KEY_FILE="$test_home/.config/sops/age/keys.txt" \
    NIXOS_ANYWHERE_BIN="$work/fake-bin/nixos-anywhere" \
    FAKE_ARGS_LOG="$work/fake.args" \
    FAKE_EXTRA_PATH_LOG="$work/fake.extra-path" \
    PATH="$work/fake-bin:$PATH" \
      bash scripts/jupiter-install.sh "$@"
  )
}

# HOME / SOPS_AGE_KEY_FILE を外して wrapper を実行する。
# 既定 key path の解決と、key 不在時の失敗の両方の検査で使う。
run_wrapper_without_key_env() {
  : >"$work/fake.args"
  : >"$work/fake.extra-path"
  (
    cd "$repo"
    env -u HOME -u SOPS_AGE_KEY_FILE \
      GNUPGHOME="$test_home/.gnupg" \
      NIXOS_ANYWHERE_BIN="$work/fake-bin/nixos-anywhere" \
      FAKE_ARGS_LOG="$work/fake.args" \
      FAKE_EXTRA_PATH_LOG="$work/fake.extra-path" \
      PATH="$work/fake-bin:$PATH" \
        bash scripts/jupiter-install.sh --target-host root@fake-target --ssh-port 2222 "$@"
  )
}

# dns-osaka-1 の暗号文フィクスチャ。本番と同じ境界で、bootstrap は管理鍵
# (テスト鍵)宛て、runtime はホスト age 鍵宛てに暗号化する。
# dns-osaka-1-secrets.sh は対話 editor を開くため fixture 生成には使えない。
prepare_dns_fixture() {
  local management_recipient
  cp "$repo_root/scripts/dns-osaka-1-install.sh" "$repo/scripts/dns-osaka-1-install.sh"
  chmod +x "$repo/scripts/dns-osaka-1-install.sh"
  mkdir -p "$repo/secrets/dns-osaka-1"
  # age-keygen -o は既存ファイルを上書きしない(2 回目の fixture 準備で落ちる)
  rm -f "$work/dns-host-age-key.txt"
  age-keygen -o "$work/dns-host-age-key.txt" >/dev/null 2>&1
  management_recipient=$(age-keygen -y "$test_home/.config/sops/age/keys.txt")
  jq -n --rawfile key "$work/dns-host-age-key.txt" '{"dns-osaka-1-age-key": $key}' \
    >"$work/dns-bootstrap.json"
  (
    cd "$work"
    sops --encrypt --age "$management_recipient" --input-type json --output-type yaml \
      dns-bootstrap.json
  ) >"$repo/secrets/dns-osaka-1/bootstrap.yaml"
  write_dns_runtime '.'
  printf '129.225.177.221 %s\n' "$(cut -d' ' -f1,2 "$test_home/.ssh/id_ed25519.pub")" >"$test_home/.ssh/known_hosts"
  (
    cd "$repo"
    git add scripts/dns-osaka-1-install.sh
    git add -f secrets/dns-osaka-1/bootstrap.yaml secrets/dns-osaka-1/runtime.yaml
    git commit -qm dns-fixture
  )
}

# jq filter を適用した runtime 平文を dns ホスト鍵宛てに暗号化して置き直す。
write_dns_runtime() {
  local filter=$1 dns_recipient
  dns_recipient=$(age-keygen -y "$work/dns-host-age-key.txt")
  jq -n '{
    "freshrss-api-password": "freshrss-password-test-value",
    "freshrss-api-url": "https://freshrss.example.test",
    "freshrss-api-username": "freshrss-user",
    "tailscale-oauth-secret": "tskey-client-test-value-0123456789"
  } | '"$filter" >"$work/dns-runtime.json"
  (
    cd "$work"
    sops --encrypt --age "$dns_recipient" --input-type json --output-type yaml \
      dns-runtime.json
  ) >"$repo/secrets/dns-osaka-1/runtime.yaml"
}

run_dns_wrapper() {
  : >"$work/fake.args"
  : >"$work/fake.extra-path"
  (
    cd "$repo"
    HOME="$test_home" \
    SOPS_AGE_KEY_FILE="$test_home/.config/sops/age/keys.txt" \
    SSH_KNOWN_HOSTS_FILE="$test_home/.ssh/known_hosts" \
    NIXOS_ANYWHERE_BIN="$work/fake-bin/nixos-anywhere" \
    FAKE_ARGS_LOG="$work/fake.args" \
    FAKE_EXTRA_PATH_LOG="$work/fake.extra-path" \
    FAKE_EXTRA_SPEC='var/lib/sops-nix/dns-osaka-1-age-key.txt:600' \
    PATH="$work/fake-bin:$PATH" \
      bash scripts/dns-osaka-1-install.sh "$@"
  )
}

assert_args_contain() {
  local expected
  for expected in "$@"; do
    rg -Fx -- "$expected" "$work/fake.args" >/dev/null || fail "missing wrapper argument: $expected"
  done
}

assert_args_absent() {
  local unwanted
  for unwanted in "$@"; do
    ! rg -Fx -- "$unwanted" "$work/fake.args" >/dev/null || fail "unexpected wrapper argument: $unwanted"
  done
}

# 各パターンが args log にこの順で現れることを検査する。
assert_args_order() {
  local pattern line previous_line=0
  for pattern in "$@"; do
    line=$(rg -n -- "$pattern" "$work/fake.args" | head -1 | cut -d: -f1)
    [ -n "$line" ] || fail "missing ordered wrapper step: $pattern"
    [ "$line" -gt "$previous_line" ] || fail "wrapper step out of order: $pattern"
    previous_line=$line
  done
}

assert_wrapper_logs_redacted() {
  ! rg -F -e 'luks-test-value' -e 'login-test-value' -e 'smb-test-value' -e 'tskey-client-test-value' \
    "$work/wrapper.stdout" "$work/wrapper.stderr" || fail "wrapper logs contain a fixture secret"
}

assert_extra_files_cleaned_up() {
  local extra
  test -s "$work/fake.extra-path" || return 0
  extra=$(cat "$work/fake.extra-path")
  test ! -e "$extra" || fail "wrapper tmpfs extra-files tree was not removed"
}

rewrite_bootstrap() {
  local filter=$1 recipient
  recipient=$(age-keygen -y "$test_home/.config/sops/age/keys.txt")
  SOPS_AGE_KEY_FILE="$test_home/.config/sops/age/keys.txt" \
    sops --decrypt --output-type json "$repo/secrets/jupiter/bootstrap.yaml" >"$work/bootstrap.json"
  jq "$filter" "$work/bootstrap.json" >"$work/bootstrap-mutated.json"
  (
    cd "$work"
    sops --encrypt --age "$recipient" --input-type json --output-type yaml \
      "$work/bootstrap-mutated.json"
  ) >"$repo/secrets/jupiter/bootstrap.yaml"
  git -C "$repo" add -f secrets/jupiter/bootstrap.yaml
  git -C "$repo" commit -qm mutated-bootstrap
}

rewrite_runtime() {
  local filter=$1 recipient

  SOPS_AGE_KEY_FILE="$test_home/.config/sops/age/keys.txt" \
    sops --decrypt --output-type json "$repo/secrets/jupiter/bootstrap.yaml" | \
    jq -r '."jupiter-age-key"' >"$work/jupiter-age-key.txt"
  chmod 600 "$work/jupiter-age-key.txt"
  recipient=$(age-keygen -y "$work/jupiter-age-key.txt")
  SOPS_AGE_KEY_FILE="$work/jupiter-age-key.txt" \
    sops --decrypt --output-type json "$repo/secrets/jupiter/runtime.yaml" >"$work/runtime.json"
  jq "$filter" "$work/runtime.json" >"$work/runtime-mutated.json"
  (
    cd "$work"
    sops --encrypt --age "$recipient" --input-type json --output-type yaml \
      "$work/runtime-mutated.json"
  ) >"$repo/secrets/jupiter/runtime.yaml"
  git -C "$repo" add -f secrets/jupiter/runtime.yaml
  git -C "$repo" commit -qm mutated-runtime
}

run_init_update() {
  (
    cd "$repo"
    HOME="$test_home" \
    GNUPGHOME="$test_home/.gnupg" \
    SOPS_AGE_KEY_FILE="$test_home/.config/sops/age/keys.txt" \
      bash scripts/jupiter-secrets.sh
  )
}

reset_init_update_fixture() {
  reset_fixture
  prepare_wrapper_fixture
}

decrypt_runtime_fixture() {
  SOPS_AGE_KEY_FILE="$test_home/.config/sops/age/keys.txt" \
    sops --decrypt --output-type json "$repo/secrets/jupiter/bootstrap.yaml" | \
    jq -r '."jupiter-age-key"' >"$work/jupiter-age-key.txt"
  chmod 600 "$work/jupiter-age-key.txt"
  SOPS_AGE_KEY_FILE="$work/jupiter-age-key.txt" \
    sops --decrypt --output-type json "$repo/secrets/jupiter/runtime.yaml"
}

decrypt_bootstrap_fixture() {
  SOPS_AGE_KEY_FILE="$test_home/.config/sops/age/keys.txt" \
    sops --decrypt --output-type json "$repo/secrets/jupiter/bootstrap.yaml"
}

test_init_update_updates_entered_values_and_preserves_empty_values() {
  reset_init_update_fixture
  decrypt_bootstrap_fixture >"$work/bootstrap-before.json"
  run_init_update >"$work/update.stdout" 2>"$work/update.stderr" <<'EOF'
luks-updated-value
luks-updated-value

smb-updated-value
smb-updated-value

EOF

  decrypt_bootstrap_fixture >"$work/bootstrap-after.json"
  decrypt_runtime_fixture >"$work/runtime-after.json"
  jq -e -s '
    .[1]."luks-passphrase" == "luks-updated-value" and
    .[1]."login-password" == "login-test-value" and
    .[1]."ssh-private-key" == .[0]."ssh-private-key" and
    .[1]."gpg-secret-key" == .[0]."gpg-secret-key" and
    .[1]."jupiter-age-key" == .[0]."jupiter-age-key"
  ' "$work/bootstrap-before.json" "$work/bootstrap-after.json" >/dev/null || \
    fail "init update did not preserve empty bootstrap values"
  jq -e '. == {
    "smb-mars-shishi": "username=shishi\npassword=smb-updated-value",
    "tailscale-oauth-secret": "tskey-client-test-value"
  }' "$work/runtime-after.json" >/dev/null || fail "init update did not preserve empty runtime values"
  ! rg -F -e 'luks-updated-value' -e 'smb-updated-value' \
    "$work/update.stdout" "$work/update.stderr" || fail "init update logged an entered secret"
}

test_init_update_adds_missing_oauth_secret() {
  reset_init_update_fixture
  rewrite_runtime 'del(."tailscale-oauth-secret")'
  run_init_update >"$work/update.stdout" 2>"$work/update.stderr" <<'EOF'



tskey-client-updated-value
tskey-client-updated-value
EOF

  decrypt_runtime_fixture | \
    jq -e '."tailscale-oauth-secret" == "tskey-client-updated-value"' >/dev/null || \
    fail "init update did not add the missing OAuth secret"
}

test_init_update_preserves_all_existing_secrets_on_empty_input() {
  local bootstrap_before runtime_before

  reset_init_update_fixture
  bootstrap_before=$(sha256sum "$repo/secrets/jupiter/bootstrap.yaml")
  runtime_before=$(sha256sum "$repo/secrets/jupiter/runtime.yaml")
  run_init_update >"$work/update.stdout" 2>"$work/update.stderr" <<'EOF'




EOF
  test "$(sha256sum "$repo/secrets/jupiter/bootstrap.yaml")" = "$bootstrap_before" || \
    fail "init update changed bootstrap.yaml after all-empty input"
  test "$(sha256sum "$repo/secrets/jupiter/runtime.yaml")" = "$runtime_before" || \
    fail "init update changed runtime.yaml after empty input"
}

test_init_update_preserves_an_existing_short_primary_credential() {
  local bootstrap_before runtime_before

  reset_init_update_fixture
  rewrite_bootstrap '."luks-passphrase" = "short"'
  bootstrap_before=$(sha256sum "$repo/secrets/jupiter/bootstrap.yaml")
  runtime_before=$(sha256sum "$repo/secrets/jupiter/runtime.yaml")
  if ! run_init_update >"$work/update.stdout" 2>"$work/update.stderr" <<'EOF'




EOF
  then
    fail "init update rejected preserving an existing short LUKS passphrase"
  fi
  test "$bootstrap_before" = "$(sha256sum "$repo/secrets/jupiter/bootstrap.yaml")" || \
    fail "preserving an existing short LUKS passphrase changed bootstrap.yaml"
  test "$runtime_before" = "$(sha256sum "$repo/secrets/jupiter/runtime.yaml")" || \
    fail "preserving an existing short LUKS passphrase changed runtime.yaml"
}

test_init_update_rejects_invalid_input_without_changes() {
  local bootstrap_before filter runtime_before

  for filter in mismatch empty; do
    reset_init_update_fixture
    if [ "$filter" = empty ]; then
      rewrite_runtime 'del(."tailscale-oauth-secret")'
    fi
    bootstrap_before=$(sha256sum "$repo/secrets/jupiter/bootstrap.yaml")
    runtime_before=$(sha256sum "$repo/secrets/jupiter/runtime.yaml")
    case "$filter" in
      mismatch)
        if run_init_update >"$work/update.stdout" 2>"$work/update.stderr" <<'EOF'
luks-updated-value
luks-updated-value


tskey-client-first-value
tskey-client-second-value
EOF
        then
          fail "init update accepted mismatched confirmation"
        fi
        ;;
      empty)
        if run_init_update >"$work/update.stdout" 2>"$work/update.stderr" <<'EOF'




EOF
        then
          fail "init update accepted an empty missing OAuth secret"
        fi
        ;;
    esac
    test "$(sha256sum "$repo/secrets/jupiter/bootstrap.yaml")" = "$bootstrap_before" || \
      fail "init update changed bootstrap.yaml after invalid input"
    test "$(sha256sum "$repo/secrets/jupiter/runtime.yaml")" = "$runtime_before" || \
      fail "init update changed runtime.yaml after invalid input"
    ! rg -F -e 'luks-updated-value' -e 'tskey-client-first-value' -e 'tskey-client-second-value' \
      "$work/update.stdout" "$work/update.stderr" || fail "init update logged invalid secret input"
  done
}

test_init_update_rejects_non_oauth_client_secrets_without_changes() {
  local bootstrap_before oauth_secret runtime_before

  for oauth_secret in client-id-value tskey-auth-test-value tskey-client-; do
    reset_init_update_fixture
    bootstrap_before=$(sha256sum "$repo/secrets/jupiter/bootstrap.yaml")
    runtime_before=$(sha256sum "$repo/secrets/jupiter/runtime.yaml")
    if run_init_update >"$work/update.stdout" 2>"$work/update.stderr" <<EOF



$oauth_secret
$oauth_secret
EOF
    then
      fail "init update accepted a non-OAuth-client secret: $oauth_secret"
    fi
    test "$(sha256sum "$repo/secrets/jupiter/bootstrap.yaml")" = "$bootstrap_before" || \
      fail "init update changed bootstrap.yaml after invalid OAuth input"
    test "$(sha256sum "$repo/secrets/jupiter/runtime.yaml")" = "$runtime_before" || \
      fail "init update changed runtime.yaml after invalid OAuth input"
    if [ "$oauth_secret" != tskey-client- ]; then
      ! rg -F -- "$oauth_secret" "$work/update.stdout" "$work/update.stderr" || \
        fail "init update logged a rejected OAuth value"
    fi
  done
}

test_init_update_rejects_existing_non_oauth_client_secrets() {
  local filter runtime_before

  for filter in \
    '."tailscale-oauth-secret" = "client-id-value"' \
    '."tailscale-oauth-secret" = "tskey-auth-test-value"' \
    '."tailscale-oauth-secret" = "tskey-client-"'; do
    reset_init_update_fixture
    rewrite_runtime "$filter"
    runtime_before=$(sha256sum "$repo/secrets/jupiter/runtime.yaml")
    if run_init_update >"$work/update.stdout" 2>"$work/update.stderr" <<'EOF'




EOF
    then
      fail "init update accepted an existing non-OAuth-client secret"
    fi
    rg -F 'runtime.yaml の形式が不正' "$work/update.stderr" >/dev/null || \
      fail "init update rejected invalid runtime.yaml for an unexpected reason"
    test "$(sha256sum "$repo/secrets/jupiter/runtime.yaml")" = "$runtime_before" || \
      fail "init update changed an invalid existing runtime.yaml"
  done
}

test_init_update_rejects_eof_without_changes() {
  local bootstrap_before runtime_before

  reset_init_update_fixture
  bootstrap_before=$(sha256sum "$repo/secrets/jupiter/bootstrap.yaml")
  runtime_before=$(sha256sum "$repo/secrets/jupiter/runtime.yaml")
  if run_init_update >"$work/update.stdout" 2>"$work/update.stderr" <<'EOF'
luks-updated-value
luks-updated-value
EOF
  then
    fail "init update accepted EOF before all secret prompts completed"
  fi
  test "$(sha256sum "$repo/secrets/jupiter/bootstrap.yaml")" = "$bootstrap_before" || \
    fail "init update changed bootstrap.yaml after EOF"
  test "$(sha256sum "$repo/secrets/jupiter/runtime.yaml")" = "$runtime_before" || \
    fail "init update changed runtime.yaml after EOF"
}

test_init_update_rolls_back_both_files_when_second_publish_fails() {
  local bootstrap_before real_mv runtime_before

  reset_init_update_fixture
  bootstrap_before=$(sha256sum "$repo/secrets/jupiter/bootstrap.yaml")
  runtime_before=$(sha256sum "$repo/secrets/jupiter/runtime.yaml")
  real_mv=$(command -v mv)
  mkdir -p "$work/failing-bin"
  printf '#!%s\n' "$test_bash" >"$work/failing-bin/mv"
  cat >>"$work/failing-bin/mv" <<'EOF'
set -euo pipefail
if [ "${@: -1}" = secrets/jupiter/runtime.yaml ] && [ ! -e "$FAILURE_MARKER" ]; then
  : >"$FAILURE_MARKER"
  exit 71
fi
exec "$REAL_MV" "$@"
EOF
  chmod +x "$work/failing-bin/mv"

  if FAILURE_MARKER="$work/second-publish-failed" REAL_MV="$real_mv" PATH="$work/failing-bin:$PATH" \
    run_init_update >"$work/update.stdout" 2>"$work/update.stderr" <<'EOF'
luks-updated-value
luks-updated-value

smb-updated-value
smb-updated-value

EOF
  then
    fail "init update succeeded after the second publish failed"
  fi
  test "$(sha256sum "$repo/secrets/jupiter/bootstrap.yaml")" = "$bootstrap_before" || \
    fail "init update left bootstrap.yaml partially updated"
  test "$(sha256sum "$repo/secrets/jupiter/runtime.yaml")" = "$runtime_before" || \
    fail "init update changed runtime.yaml after the second publish failed"
}

test_init_update_preserves_files_when_sops_set_fails() {
  local bootstrap_before real_sops runtime_before

  reset_init_update_fixture
  bootstrap_before=$(sha256sum "$repo/secrets/jupiter/bootstrap.yaml")
  runtime_before=$(sha256sum "$repo/secrets/jupiter/runtime.yaml")
  real_sops=$(command -v sops)
  mkdir -p "$work/failing-bin"
  printf '#!%s\n' "$test_bash" >"$work/failing-bin/sops"
  cat >>"$work/failing-bin/sops" <<'EOF'
if [ "$1" = set ]; then
  : >"$3"
  exit 70
fi
exec "$REAL_SOPS" "$@"
EOF
  chmod +x "$work/failing-bin/sops"

  if REAL_SOPS="$real_sops" PATH="$work/failing-bin:$PATH" \
    run_init_update >"$work/update.stdout" 2>"$work/update.stderr" <<'EOF'
luks-updated-value
luks-updated-value



EOF
  then
    fail "init update succeeded after sops set failed"
  fi
  test "$(sha256sum "$repo/secrets/jupiter/bootstrap.yaml")" = "$bootstrap_before" || \
    fail "init update damaged bootstrap.yaml after sops set failed"
  test "$(sha256sum "$repo/secrets/jupiter/runtime.yaml")" = "$runtime_before" || \
    fail "init update damaged runtime.yaml after sops set failed"
}

assert_wrapper_fails() {
  if run_wrapper "$@" >"$work/wrapper.stdout" 2>"$work/wrapper.stderr"; then
    fail "wrapper unexpectedly succeeded: $*"
  fi
  assert_wrapper_logs_redacted
  assert_extra_files_cleaned_up
}

reset_wrapper_fixture() {
  reset_fixture
  prepare_wrapper_fixture
  make_fake_nixos_anywhere
}

test_run_executes_disko_keygen_install_in_order() {
  reset_wrapper_fixture
  run_wrapper >"$work/wrapper.stdout" 2>"$work/wrapper.stderr" || fail "wrapper run failed"
  assert_args_contain --disk-encryption-keys /tmp/secret.key --extra-files --chown home/shishi 1000:100
  assert_args_order '^ssh-copy-id ' '^disko$' 'create-keys' '^install$' 'find /mnt/home/shishi/\.ssh'
  assert_args_order '^--disk-encryption-keys$' 'ssh_host_ed25519_key' '^--extra-files$'
  rg -F 'SHA256:fake-fingerprint' "$work/wrapper.stdout" "$work/wrapper.stderr" >/dev/null || \
    fail "wrapper did not surface the initrd host key fingerprint"
  assert_wrapper_logs_redacted
  assert_extra_files_cleaned_up
}

test_phases_and_target_host_are_wrapper_owned() {
  reset_wrapper_fixture
  assert_wrapper_fails --phases disko
  rg -F -- '--phases は指定しないこと' "$work/wrapper.stderr" >/dev/null || \
    fail "manual phases rejection did not explain the wrapper contract"
  if run_wrapper_raw >"$work/wrapper.stdout" 2>"$work/wrapper.stderr"; then
    fail "wrapper unexpectedly ran without --target-host"
  fi
  rg -F -- '--target-host' "$work/wrapper.stderr" >/dev/null || \
    fail "missing target host rejection did not name the required argument"
  if run_wrapper_raw --target-host nixos@fake-target >"$work/wrapper.stdout" 2>"$work/wrapper.stderr"; then
    fail "wrapper unexpectedly accepted a non-root target host"
  fi
  rg -F -- 'root@<target> にすること' "$work/wrapper.stderr" >/dev/null || \
    fail "non-root target rejection did not explain the root requirement"
}

test_default_management_key_path_is_used_when_env_is_unset() {
  reset_wrapper_fixture
  install -m 600 "$test_home/.config/sops/age/keys.txt" "$repo/secrets/management-age-key.txt"
  rm -f -- "$test_home/.config/sops/age/keys.txt"
  run_wrapper_without_key_env >"$work/wrapper.stdout" 2>"$work/wrapper.stderr" || \
    fail "wrapper did not use the default management key path"
  assert_args_contain --extra-files --chown home/shishi 1000:100
  assert_wrapper_logs_redacted
  assert_extra_files_cleaned_up
}

test_missing_default_management_key_reports_a_controlled_error() {
  reset_wrapper_fixture
  rm -f -- "$test_home/.config/sops/age/keys.txt" "$repo/secrets/management-age-key.txt"
  if run_wrapper_without_key_env >"$work/wrapper.stdout" 2>"$work/wrapper.stderr"; then
    fail "wrapper unexpectedly accepted a missing management key"
  fi
  rg -F 'management age key が読めない' "$work/wrapper.stderr" >/dev/null || \
    fail "missing management key did not report a controlled error"
  ! rg -F 'unbound variable' "$work/wrapper.stderr" || fail "missing management key caused an unbound variable error"
  assert_wrapper_logs_redacted
  assert_extra_files_cleaned_up
}

test_manual_secret_arguments_are_rejected() {
  reset_wrapper_fixture
  assert_wrapper_fails --extra-files arbitrary
  rg -F 'remove --extra-files' "$work/wrapper.stderr" >/dev/null || fail "manual extra-files rejection did not explain remediation"
  assert_wrapper_fails --disk-encryption-keys /tmp/secret.key arbitrary
  rg -F 'remove --disk-encryption-keys' "$work/wrapper.stderr" >/dev/null || fail "manual disk key rejection did not explain remediation"
}

test_installer_host_keys_are_not_recorded() {
  reset_wrapper_fixture
  run_wrapper >"$work/wrapper.stdout" 2>"$work/wrapper.stderr" || \
    fail "wrapper run with wrapper-owned ssh options failed"
  assert_args_contain --ssh-option UserKnownHostsFile=/dev/null StrictHostKeyChecking=no
  rg -- '^ssh .*UserKnownHostsFile=/dev/null .*StrictHostKeyChecking=no' "$work/fake.args" >/dev/null || \
    fail "wrapper-owned ssh commands do not carry the host key options"
  rg -- '^ssh-copy-id .*UserKnownHostsFile=/dev/null .*StrictHostKeyChecking=no' "$work/fake.args" >/dev/null || \
    fail "wrapper-owned ssh-copy-id does not carry the host key options"
  assert_wrapper_fails --ssh-option StrictHostKeyChecking=yes
  rg -F -- '--ssh-option は指定しないこと' "$work/wrapper.stderr" >/dev/null || \
    fail "manual ssh option rejection did not explain the wrapper contract"
}

test_wrong_management_key_is_rejected() {
  reset_wrapper_fixture
  age-keygen -o "$work/wrong-age-key.txt" >/dev/null 2>&1
  if (
    cd "$repo"
    HOME="$test_home" \
    SOPS_AGE_KEY_FILE="$work/wrong-age-key.txt" \
    NIXOS_ANYWHERE_BIN="$work/fake-bin/nixos-anywhere" \
    FAKE_ARGS_LOG="$work/fake.args" FAKE_EXTRA_PATH_LOG="$work/fake.extra-path" \
    PATH="$work/fake-bin:$PATH" \
      bash scripts/jupiter-install.sh --target-host root@fake-target
  ) >"$work/wrapper.stdout" 2>"$work/wrapper.stderr"; then
    fail "wrapper accepted a wrong management key"
  fi
  assert_wrapper_logs_redacted
  assert_extra_files_cleaned_up
}

test_damaged_bootstrap_mac_is_rejected() {
  reset_wrapper_fixture
  sed -i '/^    mac:/c\    mac: ENC[AES256_GCM,data:broken,type:str]' "$repo/secrets/jupiter/bootstrap.yaml"
  assert_wrapper_fails
}

test_rewrite_bootstrap_isolated_from_repository_sops_config() {
  reset_wrapper_fixture
  rewrite_bootstrap '."login-password" = ""'
  SOPS_AGE_KEY_FILE="$test_home/.config/sops/age/keys.txt" \
    sops --decrypt --output-type json "$repo/secrets/jupiter/bootstrap.yaml" | \
    jq -e '."login-password" == ""' >/dev/null || fail "fixture bootstrap rewrite did not preserve the requested mutation"
}

test_malformed_bootstrap_values_are_rejected() {
  local filter
  for filter in \
    '."ssh-private-key" = "not-an-ssh-private-key"' \
    '."gpg-secret-key" = "not-an-armored-gpg-key"' \
    '."jupiter-age-key" = "not-an-age-key"' \
    '."luks-passphrase" = ""' \
    '."login-password" = ""'; do
    reset_wrapper_fixture
    rewrite_bootstrap "$filter"
    assert_wrapper_fails
  done
}

test_primary_credential_length_policy_is_enforced_by_wrapper() {
  local filter
  for filter in \
    '."luks-passphrase" = "short"' \
    '."login-password" = "short"' \
    '."luks-passphrase" = ("x" * 129)' \
    '."login-password" = ("x" * 129)'; do
    reset_wrapper_fixture
    rewrite_bootstrap "$filter"
    assert_wrapper_fails
    rg -F '15文字以上128文字以下' "$work/wrapper.stderr" >/dev/null || \
      fail "wrapper credential length failure did not report the policy"
  done
}

test_primary_credential_control_characters_are_rejected_by_wrapper() {
  local filter
  for filter in \
    '."luks-passphrase" = "long-enough\u0009value"' \
    '."login-password" = "short\u000axxxxxxxxx"' \
    '."login-password" = "short\u0000xxxxxxxxx"'; do
    reset_wrapper_fixture
    rewrite_bootstrap "$filter"
    assert_wrapper_fails
    rg -F '制御文字は使えない' "$work/wrapper.stderr" >/dev/null || \
      fail "wrapper credential control-character failure did not report the policy"
  done
}

test_malformed_runtime_values_are_rejected() {
  local filter
  for filter in \
    'del(."tailscale-oauth-secret")' \
    '."tailscale-oauth-secret" = ""' \
    '."tailscale-oauth-secret" = null' \
    '."tailscale-oauth-secret" = "client-id-value"' \
    '."tailscale-oauth-secret" = "tskey-auth-test-value"' \
    '."tailscale-oauth-secret" = "tskey-client-"' \
    '.unexpected = "extra"'; do
    reset_wrapper_fixture
    rewrite_runtime "$filter"
    assert_wrapper_fails
  done
}

test_untracked_ciphertext_is_rejected() {
  reset_wrapper_fixture
  git -C "$repo" rm --cached -q secrets/jupiter/runtime.yaml
  assert_wrapper_fails
  rg -F 'Git で追跡されていない' "$work/wrapper.stderr" >/dev/null || fail "untracked ciphertext was not explained"
}

test_child_status_and_cleanup_are_preserved() {
  reset_wrapper_fixture
  if FAKE_NIXOS_ANYWHERE_STATUS=37 run_wrapper >"$work/wrapper.stdout" 2>"$work/wrapper.stderr"; then
    fail "wrapper unexpectedly hid child failure"
  else
    test "$?" -eq 37 || fail "wrapper did not preserve child exit status"
  fi
  assert_wrapper_logs_redacted
  assert_extra_files_cleaned_up
}

test_gpg_import_succeeds_and_removes_export() {
  local export_file="$work/gpg-secret.asc"
  local target_gnupg_home="$work/imported-gnupg"
  local fingerprint

  prepare_source_keys
  cp "$work/fixture-gpg-secret.asc" "$export_file"
  fingerprint=$(HOME="$test_home" GNUPGHOME="$test_home/.gnupg" \
    gpg --batch --with-colons --list-secret-keys secrets-workflow@example.test | \
    awk -F: '$1 == "fpr" { print $10; exit }')

  bash "$repo_root/scripts/import-gpg-secret.sh" "$export_file" "$target_gnupg_home" \
    >"$work/gpg-import.stdout" 2>"$work/gpg-import.stderr" || fail "GPG import failed"

  test ! -e "$export_file" || fail "successful GPG import retained the export"
  gpg --homedir "$target_gnupg_home" --batch --list-secret-keys "$fingerprint" >/dev/null 2>&1 || \
    fail "imported secret key is missing"
  printf 'test\n' | gpg --homedir "$target_gnupg_home" --batch --pinentry-mode loopback \
    --local-user "$fingerprint" --clearsign >/dev/null 2>&1 || fail "imported key cannot clearsign"
  gpg --homedir "$target_gnupg_home" --batch --export-ownertrust | \
    rg -Fx "$fingerprint:6:" >/dev/null || fail "imported key does not have ultimate ownertrust"
  ! rg -F 'BEGIN PGP PRIVATE KEY BLOCK' "$work/gpg-import.stdout" "$work/gpg-import.stderr" || \
    fail "GPG import logs contain private-key armor"
}

test_corrupt_gpg_export_is_preserved_without_secret_output() {
  local export_file="$work/corrupt-gpg-secret.asc"
  local target_gnupg_home="$work/corrupt-imported-gnupg"

  printf '%s\n' \
    '-----BEGIN PGP PRIVATE KEY BLOCK-----' \
    'corrupt-private-body' \
    '-----END PGP PRIVATE KEY BLOCK-----' >"$export_file"

  if bash "$repo_root/scripts/import-gpg-secret.sh" "$export_file" "$target_gnupg_home" \
    >"$work/gpg-corrupt.stdout" 2>"$work/gpg-corrupt.stderr"; then
    fail "GPG import unexpectedly accepted a corrupt export"
  fi
  test -e "$export_file" || fail "failed GPG import removed the export"
  ! rg -F -e 'BEGIN PGP PRIVATE KEY BLOCK' -e 'corrupt-private-body' \
    "$work/gpg-corrupt.stdout" "$work/gpg-corrupt.stderr" || fail "failed GPG import logged private-key material"
}

test_clearsign_failure_preserves_export() {
  local export_file="$work/public-gpg-key.asc"
  local source_gnupg_home="$work/public-source-gnupg"
  local target_gnupg_home="$work/public-only-gnupg"
  local fingerprint

  mkdir -m 700 "$source_gnupg_home"
  gpg --homedir "$source_gnupg_home" --batch --pinentry-mode loopback --passphrase '' \
    --quick-generate-key 'Public-only Test <public-only@example.test>' default default never
  fingerprint=$(gpg --homedir "$source_gnupg_home" --batch --with-colons \
    --list-secret-keys public-only@example.test | \
    awk -F: '$1 == "fpr" { print $10; exit }')
  gpg --homedir "$source_gnupg_home" --batch --armor --export "$fingerprint" >"$export_file"

  if bash "$repo_root/scripts/import-gpg-secret.sh" "$export_file" "$target_gnupg_home" \
    >"$work/gpg-public.stdout" 2>"$work/gpg-public.stderr"; then
    fail "GPG import unexpectedly signed with a public-only key"
  fi
  test -e "$export_file" || fail "clearsign failure removed the export"
  gpg --homedir "$target_gnupg_home" --batch --list-keys "$fingerprint" >/dev/null 2>&1 || \
    fail "public key was not imported before clearsign failed"
  gpg --homedir "$target_gnupg_home" --batch --export-ownertrust | \
    rg -Fx "$fingerprint:6:" >/dev/null || fail "ownertrust was not set before clearsign failed"
  ! rg -F -e 'BEGIN PGP PRIVATE KEY BLOCK' -e 'BEGIN PGP PUBLIC KEY BLOCK' \
    "$work/gpg-public.stdout" "$work/gpg-public.stderr" || fail "clearsign failure logged key material"
}

if [ "$suite" = gpg-import ]; then
  test_gpg_import_succeeds_and_removes_export
  test_corrupt_gpg_export_is_preserved_without_secret_output
  test_clearsign_failure_preserves_export
  echo "GPG import tests: PASS"
  exit 0
fi

# dns-osaka-1 wrapper: 配送物(ホスト age 鍵、mode 600)と、登録済み known_hosts での
# 厳格なホスト鍵検証、固定 phase 列を fake nixos-anywhere で検査する。
test_dns_install_delivers_host_key_with_verified_host_identity() {
  reset_wrapper_fixture
  prepare_dns_fixture
  run_dns_wrapper >"$work/wrapper.stdout" 2>"$work/wrapper.stderr" || fail "dns wrapper run failed"
  assert_args_contain --extra-files --copy-host-keys --phases kexec,disko,install,reboot \
    --ssh-option StrictHostKeyChecking=yes "UserKnownHostsFile=$test_home/.ssh/known_hosts"
  assert_args_absent StrictHostKeyChecking=no UserKnownHostsFile=/dev/null
  assert_wrapper_logs_redacted
  assert_extra_files_cleaned_up
}

test_dns_install_rejects_bad_preconditions() {
  reset_wrapper_fixture
  prepare_dns_fixture
  if run_dns_wrapper --phases disko >"$work/wrapper.stdout" 2>"$work/wrapper.stderr"; then
    fail "dns wrapper accepted arguments"
  fi
  rg -F -- '引数は指定しないこと' "$work/wrapper.stderr" >/dev/null || \
    fail "dns wrapper argument rejection did not explain the contract"
  rm -f "$test_home/.ssh/known_hosts"
  if run_dns_wrapper >"$work/wrapper.stdout" 2>"$work/wrapper.stderr"; then
    fail "dns wrapper ran without a verified host key registration"
  fi
  rg -F 'authorized_keys に自分の公開鍵を確認できない' "$work/wrapper.stderr" >/dev/null || \
    fail "failed key verification was not reported"
  test ! -e "$test_home/.ssh/known_hosts" || \
    fail "wrapper recorded a host key despite failed verification"
  printf '129.225.177.221 %s\n' "$(cut -d' ' -f1,2 "$test_home/.ssh/id_ed25519.pub")" >"$test_home/.ssh/known_hosts"
  write_dns_runtime 'del(."freshrss-api-password")'
  if run_dns_wrapper >"$work/wrapper.stdout" 2>"$work/wrapper.stderr"; then
    fail "dns wrapper accepted an incomplete runtime secret"
  fi
  rg -F 'runtime.yamlの値が未設定または不正' "$work/wrapper.stderr" >/dev/null || \
    fail "incomplete runtime secret was not reported"
  assert_wrapper_logs_redacted
}

if [ "$suite" = wrapper ]; then
  test_run_executes_disko_keygen_install_in_order
  test_phases_and_target_host_are_wrapper_owned
  test_default_management_key_path_is_used_when_env_is_unset
  test_missing_default_management_key_reports_a_controlled_error
  test_manual_secret_arguments_are_rejected
  test_installer_host_keys_are_not_recorded
  test_wrong_management_key_is_rejected
  test_damaged_bootstrap_mac_is_rejected
  test_rewrite_bootstrap_isolated_from_repository_sops_config
  test_malformed_bootstrap_values_are_rejected
  test_primary_credential_length_policy_is_enforced_by_wrapper
  test_primary_credential_control_characters_are_rejected_by_wrapper
  test_malformed_runtime_values_are_rejected
  test_untracked_ciphertext_is_rejected
  test_child_status_and_cleanup_are_preserved
  test_dns_install_delivers_host_key_with_verified_host_identity
  test_dns_install_rejects_bad_preconditions
  echo "secrets wrapper tests: PASS"
  exit 0
fi

test_missing_ssh_key_fails_before_input
reset_fixture
test_mismatched_confirmation_leaves_no_outputs
reset_fixture
test_existing_ciphertext_is_not_overwritten
reset_fixture
test_dangling_symlink_is_not_overwritten
reset_fixture
test_default_management_key_is_created_in_repository
reset_fixture
test_failed_installation_rolls_back_outputs
reset_fixture
test_publish_race_preserves_competing_entry
reset_fixture
test_concurrent_initializer_is_rejected_before_input
reset_fixture
test_short_luks_passphrase_is_rejected
reset_fixture
test_control_character_in_luks_passphrase_is_rejected
reset_fixture
test_successful_initialization_encrypts_expected_boundaries
test_initialization_rejects_non_oauth_client_secrets
test_init_update_updates_entered_values_and_preserves_empty_values
test_init_update_adds_missing_oauth_secret
test_init_update_preserves_all_existing_secrets_on_empty_input
test_init_update_preserves_an_existing_short_primary_credential
test_init_update_rejects_invalid_input_without_changes
test_init_update_rejects_non_oauth_client_secrets_without_changes
test_init_update_rejects_existing_non_oauth_client_secrets
test_init_update_rejects_eof_without_changes
test_init_update_rolls_back_both_files_when_second_publish_fails
test_init_update_preserves_files_when_sops_set_fails

echo "secrets workflow tests: PASS"
