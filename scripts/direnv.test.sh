#!/usr/bin/env bash

set -euo pipefail

envrc=${1:?usage: direnv.test.sh /absolute/path/to/.envrc}

case "$envrc" in
  /*) ;;
  *)
    echo "envrc path must be absolute" >&2
    exit 64
    ;;
esac

test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
cd "$test_dir"
touch flake.nix flake.lock

use_count=0
nix_calls="$test_dir/nix-calls"
: > "$nix_calls"

has() {
  [ "$#" -eq 1 ] && [ "$1" = nix_direnv_version ]
}

nix_direnv_version() {
  [ "$#" -eq 1 ] && [ "$1" = 3.0.6 ]
}

source_url() {
  echo "FAIL: .envrc downloaded nix-direnv even though version 3.0.6 is available" >&2
  return 1
}

use() {
  if [ "$#" -ne 3 ] || [ "$1" != flake ] || [ "$2" != . ] || [ "$3" != --accept-flake-config ]; then
    echo "FAIL: .envrc must accept its root flake config explicitly" >&2
    return 1
  fi

  use_count=$((use_count + 1))
  export DIRENV_TEST_VALUE=loaded
}

nix() {
  printf '%s\n' "$*" >> "$nix_calls"
  printf 'export DIRENV_TEST_VALUE=loaded\n'
}

# shellcheck source=/dev/null
source "$envrc"

if [ "$use_count" -ne 1 ]; then
  echo "FAIL: .envrc must delegate environment loading to use flake exactly once" >&2
  exit 1
fi

if [ -s "$nix_calls" ]; then
  echo "FAIL: .envrc directly evaluated Nix in addition to use flake" >&2
  exit 1
fi

if [ "${DIRENV_TEST_VALUE:-}" != loaded ]; then
  echo "FAIL: use flake environment was not retained" >&2
  exit 1
fi

echo "direnv workflow test: PASS"
