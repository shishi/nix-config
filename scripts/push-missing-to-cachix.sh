#!/usr/bin/env bash
set -euo pipefail
cache=${1:?usage: push-missing-to-cachix.sh cache output-paths-file}
outputs_file=${2:?usage: push-missing-to-cachix.sh cache output-paths-file}
mapfile -t outputs < "$outputs_file"
if [[ ${#outputs[@]} -eq 0 ]]; then
  echo 'No build outputs were provided.' >&2
  exit 1
fi

task_tmp=$(mktemp -d)
trap 'rm -rf "$task_tmp"' EXIT
nix path-info --recursive "${outputs[@]}" > "$task_tmp/closure"
test -s "$task_tmp/closure"
: > "$task_tmp/missing"
while IFS= read -r path; do
  if [[ ! $path =~ ^/nix/store/[0-9a-z]{32}-[^/]+$ ]]; then
    echo "Invalid store path: $path" >&2
    exit 1
  fi
  store_name=${path##*/}
  hash=${store_name%%-*}
  status=$(curl --silent --show-error --location \
    --connect-timeout 10 --max-time 30 \
    --output /dev/null --write-out '%{http_code}' \
    "https://cache.nixos.org/$hash.narinfo")
  case "$status" in
    200) ;;
    404) printf '%s\n' "$path" >> "$task_tmp/missing" ;;
    *)
      echo "Official cache lookup failed for $path (HTTP $status)." >&2
      exit 1
      ;;
  esac
done < "$task_tmp/closure"

if [[ -s $task_tmp/missing ]]; then
  # Cachix also omits upstream paths from recursive pushes: https://docs.cachix.org/faq
  cachix push "$cache" < "$task_tmp/missing"
else
  echo 'All build outputs and their dependencies are available from cache.nixos.org.'
fi
