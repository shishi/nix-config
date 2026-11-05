#!/usr/bin/env bash
set -euo pipefail
script=$(realpath "${1:?usage: push-missing-to-cachix.test.sh path/to/script}")
task_tmp=$(mktemp -d)
trap 'rm -rf "$task_tmp"' EXIT
mkdir "$task_tmp/bin"
export CACHE_TEST_DIR="$task_tmp"
export PATH="$task_tmp/bin:$PATH"
root=/nix/store/00000000000000000000000000000000-brave
dependency=/nix/store/11111111111111111111111111111111-runtime
printf '%s\n' "$root" > "$task_tmp/outputs"
printf '%s\n' "$root" "$dependency" > "$task_tmp/closure"

for command in nix curl cachix; do
  printf '#!%s\n' "$BASH" > "$task_tmp/bin/$command"
done
cat >> "$task_tmp/bin/nix" <<'STUB'
set -euo pipefail
test "$*" = 'path-info --recursive /nix/store/00000000000000000000000000000000-brave'
cat "$CACHE_TEST_DIR/closure"
exit "${CACHE_TEST_NIX_EXIT:-0}"
STUB
cat >> "$task_tmp/bin/curl" <<'STUB'
set -euo pipefail
url=${!#}
case "$url" in
  https://cache.nixos.org/00000000000000000000000000000000.narinfo)
    printf '%s' "${CACHE_TEST_ROOT_STATUS:-404}" ;;
  https://cache.nixos.org/11111111111111111111111111111111.narinfo)
    printf '%s' "${CACHE_TEST_DEPENDENCY_STATUS:-200}" ;;
  *) echo "unexpected URL: $url" >&2; exit 99 ;;
esac
exit "${CACHE_TEST_CURL_EXIT:-0}"
STUB
cat >> "$task_tmp/bin/cachix" <<'STUB'
set -euo pipefail
test "$*" = 'push test-cache'
cat > "$CACHE_TEST_DIR/pushed"
exit "${CACHE_TEST_CACHIX_EXIT:-0}"
STUB
chmod +x "$task_tmp"/bin/*

run() {
  rm -f "$task_tmp/pushed"
  set +e
  bash "$script" test-cache "$task_tmp/outputs" > "$task_tmp/stdout" 2> "$task_tmp/stderr"
  result=$?
  set -e
}

run
test "$result" -eq 0
diff -u "$task_tmp/outputs" "$task_tmp/pushed"

export CACHE_TEST_ROOT_STATUS=200
run
test "$result" -eq 0
test ! -e "$task_tmp/pushed"
unset CACHE_TEST_ROOT_STATUS

# A failure after finding a missing root must not publish a partial closure.
for status in 403 429 500 000; do
  export CACHE_TEST_DEPENDENCY_STATUS=$status
  run
  test "$result" -ne 0
  test ! -e "$task_tmp/pushed"
done
unset CACHE_TEST_DEPENDENCY_STATUS

export CACHE_TEST_CURL_EXIT=28
run
test "$result" -ne 0
test ! -e "$task_tmp/pushed"
unset CACHE_TEST_CURL_EXIT

export CACHE_TEST_NIX_EXIT=1
run
test "$result" -ne 0
test ! -e "$task_tmp/pushed"
unset CACHE_TEST_NIX_EXIT

export CACHE_TEST_CACHIX_EXIT=42
run
test "$result" -eq 42
diff -u "$task_tmp/outputs" "$task_tmp/pushed"

echo 'cachix: only confirmed official-cache misses are pushed; lookup and upload errors fail'
