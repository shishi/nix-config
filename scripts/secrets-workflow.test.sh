#!/usr/bin/env bash

set -euo pipefail

case "${1:-}" in
  init) ;;
  *)
    echo "usage: $0 init" >&2
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
test_successful_initialization_encrypts_expected_boundaries

echo "secrets workflow tests: PASS"
