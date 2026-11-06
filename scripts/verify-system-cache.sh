#!/usr/bin/env bash
set -euo pipefail
outputs_file=${1:?usage: verify-system-cache.sh output-paths-file closure-file}
closure_file=${2:?usage: verify-system-cache.sh output-paths-file closure-file}
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
mapfile -t outputs < "$outputs_file"
test "${#outputs[@]}" -gt 0
settings=$(nix eval --json --file "$script_dir/../shared/nix-caches.nix")
substituters=$(jq -r '.substituters | join(" ")' <<< "$settings")
keys=$(jq -r '.trustedPublicKeys | join(" ")' <<< "$settings")
verification_root=$(mktemp -d)
trap 'chmod -R u+w "$verification_root"; rm -rf "$verification_root"' EXIT
store="local?root=$verification_root"
nix-store --store "$store" --realise "${outputs[@]}" --option max-jobs 0 --option builders '' --option substituters "$substituters" --option trusted-public-keys "$keys"
nix path-info --store "$store" --recursive "${outputs[@]}" | sort > "$verification_root/actual"
sort "$closure_file" > "$verification_root/expected"
diff -u "$verification_root/expected" "$verification_root/actual"
nix store verify --store "$store" --all --option trusted-public-keys "$keys"
