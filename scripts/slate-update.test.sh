#!/usr/bin/env bash
set -euo pipefail
script=${1:?usage: slate-update.test.sh path/to/slate-update.sh}
script=$(realpath "$script")
task_tmp=$(mktemp -d)
trap 'rm -rf "$task_tmp"' EXIT
mkdir "$task_tmp/bin"
export SLATE_TEST_LOG="$task_tmp/log"
printf '#!%s\n' "$BASH" > "$task_tmp/bin/systemctl"
cat >> "$task_tmp/bin/systemctl" <<'STUB'
set -euo pipefail
printf '%s\n' "$*" >> "$SLATE_TEST_LOG"
case "$*" in
  'start slate-build.service') exit "${SLATE_TEST_BUILD_EXIT:-0}" ;;
  'start slate.service slate-run.service') exit 0 ;;
  *) echo "unexpected systemctl call: $*" >&2; exit 99 ;;
esac
STUB
chmod +x "$task_tmp/bin/systemctl"
export PATH="$task_tmp/bin:$PATH"
bash "$script"
printf '%s\n' 'start slate-build.service' 'start slate.service slate-run.service' > "$task_tmp/expected"
diff -u "$task_tmp/expected" "$SLATE_TEST_LOG"
: > "$SLATE_TEST_LOG"
export SLATE_TEST_BUILD_EXIT=42
set +e
bash "$script"
result=$?
set -e
test "$result" -eq 42
printf '%s\n' 'start slate-build.service' > "$task_tmp/expected"
diff -u "$task_tmp/expected" "$SLATE_TEST_LOG"
echo 'slate-update: successful builds start both services; failed builds leave them stopped'
