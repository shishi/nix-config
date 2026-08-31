#!/usr/bin/env bash

set -euo pipefail

update_script=${1:?usage: update.test.sh /absolute/path/to/update.sh}

case "$update_script" in
  /*) ;;
  *)
    echo "update script path must be absolute" >&2
    exit 64
    ;;
esac

test_root=$(mktemp -d)
trap 'rm -rf "$test_root"' EXIT

new_fixture() {
  local fixture=$1

  mkdir -p "$fixture/bin"
  cp "$update_script" "$fixture/update.sh"
  chmod +x "$fixture/update.sh"
  printf '{}\n' > "$fixture/flake.lock"
  {
    printf '#!%s\n' "$BASH"
    cat <<'SCRIPT'
set -euo pipefail
printf 'nix %s\n' "$*" >> "$UPDATE_CALLS"
if [ "$*" = "flake update" ]; then
  printf '{"updated":true}\n' > flake.lock
fi
SCRIPT
  } > "$fixture/bin/nix"

  {
    printf '#!%s\n' "$BASH"
    cat <<'SCRIPT'
set -euo pipefail
printf 'nix-update %s\n' "$*" >> "$UPDATE_CALLS"
exit "${NIX_UPDATE_EXIT:-0}"
SCRIPT
  } > "$fixture/bin/nix-update"

  chmod +x "$fixture/bin/nix" "$fixture/bin/nix-update"
  : > "$fixture/calls"
  git -C "$fixture" init -q
  git -C "$fixture" config user.email test@example.invalid
  git -C "$fixture" config user.name Test
  git -C "$fixture" add update.sh flake.lock bin calls
  git -C "$fixture" commit -qm initial
}

assert_line() {
  local expected=$1
  local file=$2

  if ! grep -Fxq "$expected" "$file"; then
    echo "FAIL: missing call: $expected" >&2
    cat "$file" >&2
    exit 1
  fi
}

clean_fixture="$test_root/clean"
new_fixture "$clean_fixture"
: > "$clean_fixture/calls"
(
  cd "$clean_fixture"
  UPDATE_CALLS="$clean_fixture/calls" PATH="$clean_fixture/bin:$PATH" "$BASH" ./update.sh
)

assert_line "nix flake update" "$clean_fixture/calls"
assert_line "nix-update --flake yaskkserv2" "$clean_fixture/calls"
assert_line "nix flake check" "$clean_fixture/calls"

if grep -Eq -- '--commit|^nix build ' "$clean_fixture/calls"; then
  echo "FAIL: update must not commit or perform host-specific builds" >&2
  cat "$clean_fixture/calls" >&2
  exit 1
fi

if git -C "$clean_fixture" diff --quiet -- flake.lock; then
  echo "FAIL: update must leave dependency changes in the current checkout" >&2
  exit 1
fi

if git -C "$clean_fixture" branch --format='%(refname:short)' | grep -q '^update/'; then
  echo "FAIL: update must not create an update branch" >&2
  exit 1
fi

dirty_fixture="$test_root/dirty"
new_fixture "$dirty_fixture"
printf 'local work\n' > "$dirty_fixture/local.txt"
: > "$dirty_fixture/calls"
if (
  cd "$dirty_fixture"
  UPDATE_CALLS="$dirty_fixture/calls" PATH="$dirty_fixture/bin:$PATH" "$BASH" ./update.sh
) >"$test_root/dirty-output" 2>&1; then
  echo "FAIL: update must reject a dirty checkout" >&2
  exit 1
fi

if [ -s "$dirty_fixture/calls" ]; then
  echo "FAIL: update ran commands before rejecting a dirty checkout" >&2
  cat "$dirty_fixture/calls" >&2
  exit 1
fi

failed_fixture="$test_root/failed"
new_fixture "$failed_fixture"
: > "$failed_fixture/calls"
if (
  cd "$failed_fixture"
  UPDATE_CALLS="$failed_fixture/calls" NIX_UPDATE_EXIT=23 PATH="$failed_fixture/bin:$PATH" "$BASH" ./update.sh
) >"$test_root/failed-output" 2>&1; then
  echo "FAIL: update must propagate nix-update failures" >&2
  exit 1
fi

assert_line "nix flake update" "$failed_fixture/calls"
assert_line "nix-update --flake yaskkserv2" "$failed_fixture/calls"
if grep -Fxq "nix flake check" "$failed_fixture/calls"; then
  echo "FAIL: checks ran after nix-update failed" >&2
  exit 1
fi

echo "update workflow test: PASS"
