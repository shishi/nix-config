#!/usr/bin/env bash
set -euo pipefail
umask 077
repo=$(git rev-parse --show-toplevel)
cd "$repo"
test -f flake.nix
test -f secrets/jupiter/.sops.yaml
exec 9>secrets/jupiter/.jupiter-secrets.lock
flock -n 9 || { echo '別の jupiter secrets 操作が実行中です' >&2; exit 1; }
work=$(mktemp -d /dev/shm/jupiter-mcp.XXXXXX)
trap 'rm -rf "$work"' EXIT
printf '[操作] Slate の tunnel_id: ' >&2
IFS= read -r tunnel
[[ $tunnel =~ ^tunnel_[a-zA-Z0-9]+$ ]] || { echo 'tunnel_id の形式が不正です' >&2; exit 1; }
printf '[操作] Slate Main の HTTPS Origin: ' >&2
IFS= read -r origin
origin=${origin%/}
[[ $origin =~ ^https://[a-zA-Z0-9.-]+\.ts\.net(:[0-9]+)?$ ]] || { echo 'https://…ts.net の Main Origin を指定してください' >&2; exit 1; }
printf '[操作] 実行用 API キー（非表示）: ' >&2
IFS= read -r -s key
printf '\n[操作] API キーを再入力（非表示）: ' >&2
IFS= read -r -s confirmation
printf '\n' >&2
[[ -n $key && $key == "$confirmation" ]] || { echo 'キーが空、または確認入力が一致しません' >&2; exit 1; }
printf '%s' "$key" >"$work/key"
unset key confirmation
jq -n --arg tunnel "$tunnel" --arg url "$origin/mcp" '{config_version:1,control_plane:{base_url:"https://api.openai.com",tunnel_id:$tunnel},mcp:{server_urls:[{channel:"main",url:$url}]},health:{listen_addr:"127.0.0.1:18080"},admin_ui:{open_browser:false},log:{level:"info",format:"json"}}' >"$work/config"
jq -n --rawfile key "$work/key" --rawfile config "$work/config" '{"api-key":$key,"slate-config":$config}' | sops --encrypt --config secrets/jupiter/.sops.yaml --filename-override secrets/jupiter/runtime.yaml --input-type json --output-type yaml /dev/stdin >"$work/encrypted"
install -m 600 "$work/encrypted" secrets/jupiter/mcp.yaml
git add -- secrets/jupiter/mcp.yaml
echo '[完了] secrets/jupiter/mcp.yaml に暗号化保存し、Nix が参照できるよう Git に追加しました。'
echo '[次の操作] nix build .#nixosConfigurations.jupiter.config.system.build.toplevel'
echo '適用後は openai-mcp-tunnel-slate.service と http://127.0.0.1:18080/readyz を確認し、ChatGPT Web で Tunnel を登録します。'
