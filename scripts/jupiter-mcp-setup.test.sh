#!/usr/bin/env bash
set -euo pipefail
script=$(realpath "$1")
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cd "$work"
git init -q
touch flake.nix
mkdir -p secrets/jupiter
age-keygen -o age-key.txt 2>/dev/null
recipient=$(age-keygen -y age-key.txt)
printf 'creation_rules:\n  - path_regex: runtime\\.yaml$\n    age: %s\n' "$recipient" > secrets/jupiter/.sops.yaml
printf 'tunnel_0123456789abcdef0123456789abcdef\nhttps://slate.example.ts.net\nfixture-runtime-key\nfixture-runtime-key\n' | bash "$script" >output 2>&1
! grep -q fixture-runtime-key output
SOPS_AGE_KEY_FILE="$work/age-key.txt" sops -d --output-type json secrets/jupiter/mcp.yaml >decoded.json
jq -e '."api-key" == "fixture-runtime-key" and ((."slate-config" | fromjson) | .control_plane.tunnel_id == "tunnel_0123456789abcdef0123456789abcdef" and .mcp.server_urls[0].url == "https://slate.example.ts.net/mcp" and .health.listen_addr == "127.0.0.1:18080")' decoded.json >/dev/null
git ls-files --error-unmatch secrets/jupiter/mcp.yaml >/dev/null
cp secrets/jupiter/mcp.yaml before.yaml
if printf '\n' | bash "$script" >output 2>&1; then exit 1; fi
cmp secrets/jupiter/mcp.yaml before.yaml
echo 'encrypted setup and failed-input preservation passed'
