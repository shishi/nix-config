#!/usr/bin/env bash
set -euo pipefail
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
exec python3 "$script_dir/push-missing-to-cachix.py" "${1:?usage: push-missing-to-cachix.sh cache output-paths-file}" "${2:?usage: push-missing-to-cachix.sh cache output-paths-file}"
