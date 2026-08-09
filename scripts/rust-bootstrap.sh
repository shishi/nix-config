#!/usr/bin/env bash
# Rust bootstrap: toolchain とツールの存在保証。
# --auto   : 加算的操作のみ + health check。常に exit 0(activation 用)
# --repair : 破壊的修復(不合格バイナリの --force 再インストール、リスト外 crate の撤去)
# 注意: writeShellApplication が set -euo pipefail を注入するため、
#       失敗許容箇所はすべて if / || で明示的に受ける(errexit-safe)。
MODE="${1:---auto}"
STATE_DIR="$HOME/.local/state/rust-bootstrap"
MANIFEST="$STATE_DIR/managed.txt"
CARGO_BIN="$HOME/.cargo/bin"
SHELL_NAME="${RUST_BOOTSTRAP_SHELL:-fish}"
TOOLS_JSON="${RUST_BOOTSTRAP_TOOLS:?RUST_BOOTSTRAP_TOOLS (json) required}"
FAIL=0

mkdir -p "$STATE_DIR"
exec 9>"$STATE_DIR/lock"
if [ "$MODE" = "--auto" ]; then
  if ! flock -n 9; then
    echo "rust-bootstrap: another run in progress; skipping" >&2
    exit 0
  fi
else
  flock 9
fi

note() { echo "rust-bootstrap: $*" >&2; }

ensure_toolchains() {
  local tc
  for tc in stable nightly; do
    if ! rustup toolchain list | grep -q "^$tc"; then
      note "installing toolchain $tc"
      if ! timeout 600 rustup toolchain install "$tc" --no-self-update; then
        note "toolchain $tc install failed (offline?)"
        FAIL=1
      fi
    fi
  done
  if ! rustup default 2>/dev/null | grep -q stable; then
    if ! rustup default stable; then FAIL=1; fi
  fi
  # rustc とロックステップのコンポーネント(Med-4: 現行構成の rust-analyzer 継続保証)
  if ! timeout 600 rustup component add rust-analyzer rust-src --toolchain stable; then
    note "component add failed (offline?)"
    FAIL=1
  fi
}

split_bins() { # "a,b,c" -> 行区切り
  echo "$1" | tr ',' '\n'
}

bin_ok() {
  # cargo サブコマンド系(cargo-add 等)は `--version` 直接指定だと clap が
  # exit 2 を返す(実測: cargo-add/rm/set-version/upgrade)。
  # 直接形 → サブコマンド形(cargo-add add --version)の順で試す
  local b="$1"
  if [ ! -x "$CARGO_BIN/$b" ]; then return 1; fi
  if "$CARGO_BIN/$b" --version >/dev/null 2>&1; then return 0; fi
  case "$b" in
    cargo-*) "$CARGO_BIN/$b" "${b#cargo-}" --version >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}

tool_ok() {
  local bins="$1" b
  while IFS= read -r b; do
    if ! bin_ok "$b"; then return 1; fi
  done < <(split_bins "$bins")
  return 0
}

record_manifest() {
  local crate="$1" bins="$2" tmp
  tmp="$(mktemp "$STATE_DIR/manifest.XXXXXX")"
  if [ -f "$MANIFEST" ]; then
    grep -v "^$crate	" "$MANIFEST" > "$tmp" || true
  fi
  printf '%s\t%s\n' "$crate" "$bins" >> "$tmp"
  mv "$tmp" "$MANIFEST"
}

install_tool() {
  local crate="$1" bins="$2" force="$3" ok=0
  note "binstall $crate (force=$force)"
  if [ "$force" = 1 ]; then
    if timeout 600 cargo binstall -y --force "$crate"; then ok=1; fi
  else
    if timeout 600 cargo binstall -y "$crate"; then ok=1; fi
  fi
  if [ "$ok" = 1 ] && tool_ok "$bins"; then
    record_manifest "$crate" "$bins"
  else
    note "$crate: install/verify failed"
    FAIL=1
  fi
}

sync_tools() {
  # プロセス置換で回す(パイプのサブシェルだと FAIL が親へ伝播しない)
  local repair="$1" crate bins b any
  while IFS=$'\t' read -r crate bins; do
    if tool_ok "$bins"; then continue; fi
    any=0
    while IFS= read -r b; do
      if [ -e "$CARGO_BIN/$b" ]; then any=1; fi
    done < <(split_bins "$bins")
    if [ "$any" = 1 ] && [ "$repair" != 1 ]; then
      note "$crate: unhealthy binaries present; run 'nix run .#rust-bootstrap -- --repair'"
      FAIL=1
    else
      install_tool "$crate" "$bins" "$any"
    fi
  done < <(echo "$TOOLS_JSON" | jq -r '.[] | "\(.crate)\t\(.bins | join(","))"')
}

remove_stale() {
  if [ ! -f "$MANIFEST" ]; then return 0; fi
  # MANIFEST を読みながら更新しない(SC2094)— コピーを走査する
  local crate bins tmp iter
  iter="$(mktemp "$STATE_DIR/manifest-iter.XXXXXX")"
  cp "$MANIFEST" "$iter"
  while IFS=$'\t' read -r crate bins; do
    if ! echo "$TOOLS_JSON" | jq -e --arg c "$crate" 'any(.[]; .crate == $c)' >/dev/null; then
      note "uninstalling stale crate $crate (bins: $bins)"
      if ! cargo uninstall "$crate"; then note "uninstall $crate failed"; fi
      tmp="$(mktemp "$STATE_DIR/manifest.XXXXXX")"
      grep -v "^$crate	" "$MANIFEST" > "$tmp" || true
      mv "$tmp" "$MANIFEST"
    fi
  done < "$iter"
  rm -f "$iter"
}

resolve_in_login_shell() {
  local b="$1"
  if [ "$SHELL_NAME" = fish ] && command -v fish >/dev/null 2>&1; then
    fish -lc "command -v $b" 2>/dev/null || true
  else
    bash -lc "command -v $b" 2>/dev/null || true
  fi
}

health_check() {
  local ok=1 b r target
  if ! rustup which rustc >/dev/null 2>&1; then
    note "health: rustup which rustc failed"; ok=0
  fi
  if ! rustup toolchain list | grep -q '^stable'; then note "health: stable missing"; ok=0; fi
  if ! rustup toolchain list | grep -q '^nightly'; then note "health: nightly missing"; ok=0; fi
  if ! rustup component list --toolchain stable 2>/dev/null | grep -q 'rust-analyzer.*(installed)'; then
    note "health: rust-analyzer component missing"; ok=0
  fi
  # High-1 対応: nixpkgs の rustup は nix profile に rustc/cargo の proxy symlink を
  # 常設する。「nix profile に無いこと」ではなく「解決先が rustup 実体であること」を検証する
  for b in rustc cargo; do
    r="$(resolve_in_login_shell "$b")"
    if [ -z "$r" ]; then
      note "health: $b not resolvable in login shell"; ok=0; continue
    fi
    target="$(readlink -f "$r" 2>/dev/null || echo "$r")"
    case "$target" in
      *rustup*) ;;                # rustup proxy(nix)/ rustup 実体
      "$CARGO_BIN"/*) ;;          # ~/.cargo/bin のシム
      *) note "health: $b -> $r -> $target (non-rustup; fenix leftover?)"; ok=0 ;;
    esac
  done
  # 管理ツールの実行検証(不合格は ok に反映 — false-green を作らない)
  while IFS= read -r b; do
    if ! bin_ok "$b"; then
      note "health: tool $b unhealthy"
      ok=0
    fi
  done < <(echo "$TOOLS_JSON" | jq -r '.[] | .bins[]')
  [ "$ok" = 1 ]
}

ensure_toolchains
if [ "$MODE" = "--repair" ]; then
  sync_tools 1
  remove_stale
else
  sync_tools 0
fi

if health_check && [ "$FAIL" = 0 ]; then
  note "OK"
  exit 0
fi
note "INCOMPLETE — switch 自体は成功しています。'nix run .#rust-bootstrap -- --repair' を実行してください"
if [ "$MODE" = "--repair" ]; then exit 1; fi
exit 0
