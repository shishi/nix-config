#!/usr/bin/env bash
set -euo pipefail
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
exec python3 "$script_dir/verify-system-cache.py" "${1:?outputs file required}" "${2:?closure file required}" "${3:?generation manifest required}"
