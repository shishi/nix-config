#!/usr/bin/env bash

set -euo pipefail

case "${1:-}" in
  init|wrapper|gpg-import) suite=$1 ;;
  *)
    echo "usage: $0 {init|wrapper|gpg-import}" >&2
    exit 64
    ;;
esac

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d)
test_home="$work/home"
repo="$work/repo"

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
  test ! -e "$repo/.sops.yaml" || fail ".sops.yaml must not exist after failure"
  test ! -e "$repo/secrets/bootstrap.yaml" || fail "bootstrap output must not exist after failure"
  test ! -e "$repo/secrets/runtime.yaml" || fail "runtime output must not exist after failure"
}

copy_fixture_repo() {
  mkdir -p "$repo/scripts"
  cp "$repo_root/flake.nix" "$repo/flake.nix"
  cp "$repo_root/scripts/init-secrets.sh" "$repo/scripts/init-secrets.sh"
  chmod +x "$repo/scripts/init-secrets.sh"
}

copy_wrapper_script_if_present() {
  if [ -f "$repo_root/scripts/nixos-anywhere-with-secrets.sh" ]; then
    cp "$repo_root/scripts/nixos-anywhere-with-secrets.sh" "$repo/scripts/nixos-anywhere-with-secrets.sh"
    chmod +x "$repo/scripts/nixos-anywhere-with-secrets.sh"
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

run_init() {
  (
    cd "$repo"
    HOME="$test_home" \
    GNUPGHOME="$test_home/.gnupg" \
    SOPS_AGE_KEY_FILE="$test_home/.config/sops/age/keys.txt" \
      bash scripts/init-secrets.sh
  ) <<'EOF'
luks-test-value
luks-test-value
login-test-value
login-test-value
smb-test-value
smb-test-value
EOF
}

run_mismatched_init() {
  (
    cd "$repo"
    HOME="$test_home" \
    GNUPGHOME="$test_home/.gnupg" \
    SOPS_AGE_KEY_FILE="$test_home/.config/sops/age/keys.txt" \
      bash scripts/init-secrets.sh
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
      bash scripts/init-secrets.sh
  ) <<'EOF'
luks-test-value
luks-test-value
login-test-value
login-test-value
smb-test-value
smb-test-value
EOF
}

run_init_with_publish_race() {
  local real_ln

  real_ln=$(command -v ln)
  mkdir -p "$work/publish-race-bin"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
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
    RACE_FINAL="$repo/secrets/runtime.yaml" \
    RACE_REPLACED_FINAL="$repo/.sops.yaml" \
      bash scripts/init-secrets.sh
  ) <<'EOF'
luks-test-value
luks-test-value
login-test-value
login-test-value
smb-test-value
smb-test-value
EOF
}

test_missing_ssh_key_fails_before_input() {
  copy_fixture_repo
  if (
    cd "$repo"
    HOME="$test_home" \
    GNUPGHOME="$test_home/.gnupg" \
    SOPS_AGE_KEY_FILE="$test_home/.config/sops/age/keys.txt" \
      bash scripts/init-secrets.sh
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
  printf 'existing-ciphertext\n' >"$repo/.sops.yaml"
  if run_init >"$work/stdout" 2>"$work/stderr"; then
    fail "initializer unexpectedly overwrote existing ciphertext"
  fi
  test "$(cat "$repo/.sops.yaml")" = 'existing-ciphertext' || fail "existing ciphertext changed"
  test ! -e "$repo/secrets/bootstrap.yaml" || fail "bootstrap was created despite existing output"
  test ! -e "$repo/secrets/runtime.yaml" || fail "runtime was created despite existing output"
}

test_dangling_symlink_is_not_overwritten() {
  copy_fixture_repo
  prepare_source_keys
  ln -s missing-sops-config "$repo/.sops.yaml"
  if run_init >"$work/stdout" 2>"$work/stderr"; then
    fail "initializer unexpectedly overwrote a dangling symlink"
  fi
  test -L "$repo/.sops.yaml" || fail "dangling symlink was replaced"
  test "$(readlink "$repo/.sops.yaml")" = missing-sops-config || fail "dangling symlink changed"
  test ! -e "$repo/secrets/bootstrap.yaml" || fail "bootstrap was created despite dangling symlink"
  test ! -e "$repo/secrets/runtime.yaml" || fail "runtime was created despite dangling symlink"
}

test_xdg_config_home_does_not_change_default_management_key_path() {
  copy_fixture_repo
  prepare_source_keys
  if ! run_init_with_xdg_config_home >"$work/stdout" 2>"$work/stderr"; then
    fail "initializer failed with XDG_CONFIG_HOME set"
  fi
  assert_file "$test_home/.config/sops/age/keys.txt"
  test ! -e "$test_home/other-config/sops/age/keys.txt" || fail "XDG_CONFIG_HOME changed the default management key path"
}

test_failed_installation_rolls_back_outputs() {
  copy_fixture_repo
  prepare_source_keys
  mkdir "$repo/secrets"
  chmod 500 "$repo/secrets"
  if run_init >"$work/stdout" 2>"$work/stderr"; then
    fail "initializer unexpectedly succeeded with an unwritable output directory"
  fi
  chmod 700 "$repo/secrets"
  assert_absent_outputs
}

test_publish_race_preserves_competing_entry() {
  copy_fixture_repo
  prepare_source_keys
  if run_init_with_publish_race >"$work/stdout" 2>"$work/stderr"; then
    fail "initializer unexpectedly succeeded despite a publish race"
  fi
  test "$(cat "$repo/.sops.yaml")" = competing-sops-ciphertext || fail "replacement entry was deleted or overwritten"
  test ! -e "$repo/secrets/bootstrap.yaml" || fail "initializer bootstrap output remained after publish race"
  test "$(cat "$repo/secrets/runtime.yaml")" = competing-runtime-ciphertext || fail "competing entry was overwritten"
}

test_successful_initialization_encrypts_expected_boundaries() {
  copy_fixture_repo
  prepare_source_keys
  if ! run_init >"$work/stdout" 2>"$work/stderr"; then
    fail "successful initializer run failed"
  fi

  assert_file "$repo/.sops.yaml"
  assert_file "$repo/secrets/bootstrap.yaml"
  assert_file "$repo/secrets/runtime.yaml"
  rg -F 'path_regex: ^secrets/bootstrap\.yaml$' "$repo/.sops.yaml" >/dev/null || fail "bootstrap creation rule is missing"
  rg -F 'path_regex: ^secrets/runtime\.yaml$' "$repo/.sops.yaml" >/dev/null || fail "runtime creation rule is missing"
  ! rg -F 'AGE-SECRET-KEY-' "$repo/.sops.yaml" || fail "SOPS config contains a private age key"
  test "$(stat -c %a "$test_home/.config/sops/age/keys.txt")" = 600 || fail "management age key mode is not 600"
  ! rg -F -e 'luks-test-value' -e 'login-test-value' -e 'smb-test-value' \
    "$repo/.sops.yaml" "$repo/secrets" || fail "ciphertext contains a fixture secret"
  ! rg -F -e 'luks-test-value' -e 'login-test-value' -e 'smb-test-value' \
    "$work/stdout" "$work/stderr" || fail "logs contain a fixture secret"

  SOPS_AGE_KEY_FILE="$test_home/.config/sops/age/keys.txt" \
    sops --decrypt --output-type json "$repo/secrets/bootstrap.yaml" >"$work/bootstrap.json"
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
    sops --decrypt --output-type json "$repo/secrets/runtime.yaml" >"$work/runtime.json"
  jq -e '. == {"smb-mars-shishi": "username=shishi\npassword=smb-test-value"}' \
    "$work/runtime.json" >/dev/null || fail "runtime plaintext shape is incorrect"

  age-keygen -o "$work/unrelated-age-key.txt" >/dev/null 2>&1
  if SOPS_AGE_KEY_FILE="$work/unrelated-age-key.txt" \
    sops --decrypt "$repo/secrets/bootstrap.yaml" >/dev/null 2>"$work/unrelated-bootstrap.stderr"; then
    fail "unrelated key decrypted bootstrap ciphertext"
  fi
  if SOPS_AGE_KEY_FILE="$test_home/.config/sops/age/keys.txt" \
    sops --decrypt "$repo/secrets/runtime.yaml" >/dev/null 2>"$work/management-runtime.stderr"; then
    fail "management key decrypted runtime ciphertext"
  fi
  if SOPS_AGE_KEY_FILE="$work/jupiter-age-key.txt" \
    sops --decrypt "$repo/secrets/bootstrap.yaml" >/dev/null 2>"$work/jupiter-bootstrap.stderr"; then
    fail "Jupiter key decrypted bootstrap ciphertext"
  fi
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
    git add flake.nix scripts/init-secrets.sh .sops.yaml
    git add -f secrets/bootstrap.yaml secrets/runtime.yaml
    git commit -qm fixture
  )
}

make_fake_nixos_anywhere() {
  mkdir -p "$work/fake-bin"
  cat >"$work/fake-bin/nixos-anywhere" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

args_log=${FAKE_ARGS_LOG:?}
extra_path_log=${FAKE_EXTRA_PATH_LOG:?}
: >"$args_log"
: >"$extra_path_log"

check_extra_files() {
  local extra=$1 path mode hash
  printf '%s\n' "$extra" >"$extra_path_log"
  while IFS=: read -r path mode; do
    test "$(stat -c %a "$extra/$path")" = "$mode" || { printf '%s\n' 'fake extra-files mode mismatch' >&2; exit 91; }
  done <<'MODES'
home/shishi/.ssh/id_ed25519:600
home/shishi/.ssh/id_ed25519.pub:644
home/shishi/gpg-secret.asc:600
var/lib/secrets/shishi-password-hash:600
var/lib/sops-nix/key.txt:600
MODES
  hash=$(head -c 3 "$extra/var/lib/secrets/shishi-password-hash")
  test "$hash" = '$y$' || { printf '%s\n' 'fake password hash is not yescrypt' >&2; exit 92; }
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
    *)
      shift
      ;;
  esac
done

exit "${FAKE_NIXOS_ANYWHERE_STATUS:-0}"
EOF
  chmod 700 "$work/fake-bin/nixos-anywhere"
}

run_wrapper() {
  (
    cd "$repo"
    HOME="$test_home" \
    GNUPGHOME="$test_home/.gnupg" \
    SOPS_AGE_KEY_FILE="$test_home/.config/sops/age/keys.txt" \
    NIXOS_ANYWHERE_BIN="$work/fake-bin/nixos-anywhere" \
    FAKE_ARGS_LOG="$work/fake.args" \
    FAKE_EXTRA_PATH_LOG="$work/fake.extra-path" \
      bash scripts/nixos-anywhere-with-secrets.sh "$@"
  )
}

run_wrapper_with_default_management_key() {
  (
    cd "$repo"
    env -u SOPS_AGE_KEY_FILE \
      HOME="$test_home" \
      GNUPGHOME="$test_home/.gnupg" \
      NIXOS_ANYWHERE_BIN="$work/fake-bin/nixos-anywhere" \
      FAKE_ARGS_LOG="$work/fake.args" \
      FAKE_EXTRA_PATH_LOG="$work/fake.extra-path" \
        bash scripts/nixos-anywhere-with-secrets.sh "$@"
  )
}

run_wrapper_without_management_key_or_home() {
  (
    cd "$repo"
    env -u HOME -u SOPS_AGE_KEY_FILE \
      GNUPGHOME="$test_home/.gnupg" \
      NIXOS_ANYWHERE_BIN="$work/fake-bin/nixos-anywhere" \
      FAKE_ARGS_LOG="$work/fake.args" \
      FAKE_EXTRA_PATH_LOG="$work/fake.extra-path" \
        bash scripts/nixos-anywhere-with-secrets.sh "$@"
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

assert_wrapper_logs_redacted() {
  ! rg -F -e 'luks-test-value' -e 'login-test-value' -e 'smb-test-value' \
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
    sops --decrypt --output-type json "$repo/secrets/bootstrap.yaml" >"$work/bootstrap.json"
  jq "$filter" "$work/bootstrap.json" >"$work/bootstrap-mutated.json"
  (
    cd "$work"
    sops --encrypt --age "$recipient" --input-type json --output-type yaml \
      "$work/bootstrap-mutated.json"
  ) >"$repo/secrets/bootstrap.yaml"
  git -C "$repo" add -f secrets/bootstrap.yaml
  git -C "$repo" commit -qm mutated-bootstrap
}

assert_wrapper_fails() {
  if run_wrapper "$@" >"$work/wrapper.stdout" 2>"$work/wrapper.stderr"; then
    fail "wrapper unexpectedly succeeded: $*"
  fi
  assert_wrapper_logs_redacted
  assert_extra_files_cleaned_up
}

reset_wrapper_fixture() {
  rm -rf -- "$repo" "$test_home"
  mkdir -p "$repo" "$test_home"
  prepare_wrapper_fixture
  make_fake_nixos_anywhere
}

test_disko_phase_only_injects_luks_key() {
  reset_wrapper_fixture
  run_wrapper --phases disko >"$work/wrapper.stdout" 2>"$work/wrapper.stderr" || fail "disko wrapper run failed"
  assert_args_contain --disk-encryption-keys /tmp/secret.key
  assert_args_absent --extra-files
  assert_wrapper_logs_redacted
  assert_extra_files_cleaned_up
}

test_install_phase_delivers_checked_extra_files() {
  reset_wrapper_fixture
  run_wrapper --phases install >"$work/wrapper.stdout" 2>"$work/wrapper.stderr" || fail "install wrapper run failed"
  assert_args_contain --extra-files --chown home/shishi 1000:100
  assert_args_absent --disk-encryption-keys
  assert_wrapper_logs_redacted
  assert_extra_files_cleaned_up
}

test_default_management_key_path_is_used_when_env_is_unset() {
  reset_wrapper_fixture
  run_wrapper_with_default_management_key --phases install >"$work/wrapper.stdout" 2>"$work/wrapper.stderr" || \
    fail "wrapper did not use the default management key path"
  assert_args_contain --extra-files --chown home/shishi 1000:100
  assert_wrapper_logs_redacted
  assert_extra_files_cleaned_up
}

test_missing_home_and_management_key_reports_a_controlled_error() {
  reset_wrapper_fixture
  if run_wrapper_without_management_key_or_home --phases install >"$work/wrapper.stdout" 2>"$work/wrapper.stderr"; then
    fail "wrapper unexpectedly accepted a missing HOME and management key"
  fi
  rg -F 'SOPS_AGE_KEY_FILE または HOME を指定すること' "$work/wrapper.stderr" >/dev/null || \
    fail "missing management key did not report a controlled error"
  ! rg -F 'unbound variable' "$work/wrapper.stderr" || fail "missing HOME caused an unbound variable error"
  assert_wrapper_logs_redacted
  assert_extra_files_cleaned_up
}

test_full_run_delivers_both_phase_inputs() {
  reset_wrapper_fixture
  run_wrapper >"$work/wrapper.stdout" 2>"$work/wrapper.stderr" || fail "full wrapper run failed"
  assert_args_contain --disk-encryption-keys /tmp/secret.key --extra-files --chown home/shishi 1000:100
  assert_wrapper_logs_redacted
  assert_extra_files_cleaned_up
}

test_manual_secret_arguments_are_rejected() {
  reset_wrapper_fixture
  assert_wrapper_fails --extra-files arbitrary --phases install
  rg -F 'remove --extra-files' "$work/wrapper.stderr" >/dev/null || fail "manual extra-files rejection did not explain remediation"
  assert_wrapper_fails --disk-encryption-keys /tmp/secret.key arbitrary --phases disko
  rg -F 'remove --disk-encryption-keys' "$work/wrapper.stderr" >/dev/null || fail "manual disk key rejection did not explain remediation"
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
      bash scripts/nixos-anywhere-with-secrets.sh --phases install
  ) >"$work/wrapper.stdout" 2>"$work/wrapper.stderr"; then
    fail "wrapper accepted a wrong management key"
  fi
  assert_wrapper_logs_redacted
  assert_extra_files_cleaned_up
}

test_damaged_bootstrap_mac_is_rejected() {
  reset_wrapper_fixture
  sed -i '/^    mac:/c\    mac: ENC[AES256_GCM,data:broken,type:str]' "$repo/secrets/bootstrap.yaml"
  assert_wrapper_fails --phases install
}

test_rewrite_bootstrap_isolated_from_repository_sops_config() {
  reset_wrapper_fixture
  rewrite_bootstrap '."login-password" = ""'
  SOPS_AGE_KEY_FILE="$test_home/.config/sops/age/keys.txt" \
    sops --decrypt --output-type json "$repo/secrets/bootstrap.yaml" | \
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
    assert_wrapper_fails --phases install
  done
}

test_untracked_ciphertext_is_rejected() {
  reset_wrapper_fixture
  git -C "$repo" rm --cached -q secrets/runtime.yaml
  assert_wrapper_fails --phases install
  rg -F 'Git で追跡されていない' "$work/wrapper.stderr" >/dev/null || fail "untracked ciphertext was not explained"
}

test_child_status_and_cleanup_are_preserved() {
  reset_wrapper_fixture
  if FAKE_NIXOS_ANYWHERE_STATUS=37 run_wrapper --phases install >"$work/wrapper.stdout" 2>"$work/wrapper.stderr"; then
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

if [ "$suite" = wrapper ]; then
  test_disko_phase_only_injects_luks_key
  test_install_phase_delivers_checked_extra_files
  test_default_management_key_path_is_used_when_env_is_unset
  test_missing_home_and_management_key_reports_a_controlled_error
  test_full_run_delivers_both_phase_inputs
  test_manual_secret_arguments_are_rejected
  test_wrong_management_key_is_rejected
  test_damaged_bootstrap_mac_is_rejected
  test_rewrite_bootstrap_isolated_from_repository_sops_config
  test_malformed_bootstrap_values_are_rejected
  test_untracked_ciphertext_is_rejected
  test_child_status_and_cleanup_are_preserved
  echo "secrets wrapper tests: PASS"
  exit 0
fi

test_missing_ssh_key_fails_before_input
rm -rf -- "$repo" "$test_home"
mkdir -p "$repo" "$test_home"
test_mismatched_confirmation_leaves_no_outputs
rm -rf -- "$repo" "$test_home"
mkdir -p "$repo" "$test_home"
test_existing_ciphertext_is_not_overwritten
rm -rf -- "$repo" "$test_home"
mkdir -p "$repo" "$test_home"
test_dangling_symlink_is_not_overwritten
rm -rf -- "$repo" "$test_home"
mkdir -p "$repo" "$test_home"
test_xdg_config_home_does_not_change_default_management_key_path
rm -rf -- "$repo" "$test_home"
mkdir -p "$repo" "$test_home"
test_failed_installation_rolls_back_outputs
rm -rf -- "$repo" "$test_home"
mkdir -p "$repo" "$test_home"
test_publish_race_preserves_competing_entry
rm -rf -- "$repo" "$test_home"
mkdir -p "$repo" "$test_home"
test_successful_initialization_encrypts_expected_boundaries

echo "secrets workflow tests: PASS"
