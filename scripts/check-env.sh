#!/usr/bin/env bash
# ホスト前提の機械検証。--critical は switch に組み込まれる高速サブセット。
# 検査項目は hosts/ubuntu-wsl/README.md の対応表と 1:1。
# writeShellApplication が set -euo pipefail を注入するため errexit-safe に書く。
MODE="${1:---full}"
FAIL=0
ng() { echo "check-env NG: $*" >&2; FAIL=1; }
ok() { echo "check-env ok: $*"; }

resolve() {
  if command -v fish >/dev/null 2>&1; then
    fish -lc "command -v $1" 2>/dev/null || true
  else
    bash -lc "command -v $1" 2>/dev/null || true
  fi
}

# --- critical: シェル / PATH 契約 ---
login_shell="$(getent passwd "$USER" | cut -d: -f7)"
case "$login_shell" in
  */fish) ok "login shell is fish" ;;
  *) ng "login shell is $login_shell (expected fish; hearing #8)" ;;
esac

# rustc/cargo は rustup 実体へ解決されること。
# nixpkgs の rustup は nix profile に proxy symlink を置くため(High-1)、
# 「nix profile に無いこと」ではなく解決先の実体で判定する
for b in rustc cargo; do
  r="$(resolve "$b")"
  if [ -z "$r" ]; then
    ng "$b not resolvable in login shell (run rust-bootstrap)"
    continue
  fi
  target="$(readlink -f "$r" 2>/dev/null || echo "$r")"
  case "$target" in
    *rustup*) ok "$b -> rustup ($r)" ;;
    "$HOME/.cargo/bin/"*) ok "$b -> $r" ;;
    *) ng "$b -> $r -> $target (non-rustup; pre-cutover leftover?)" ;;
  esac
done

# nix 管理ツールが nix 側に解決されること
# (standalone: ~/.nix-profile / NixOS useUserPackages: /etc/profiles/per-user)
for b in bat fd rg eza; do
  r="$(resolve "$b")"
  case "$r" in
    "$HOME/.nix-profile/bin/"* | /etc/profiles/per-user/* | /nix/store/*) ok "$b -> nix" ;;
    *) ng "$b resolves to '$r' (expected nix; stale ~/.cargo/bin copy? see #39)" ;;
  esac
done

# --- critical: 適用経路(スペック: preflight(現 check-env)検査対象 (c))---
FLAKE_DIR="$HOME/dev/src/github.com/shishi/nix-config"
if [ -f "$FLAKE_DIR/flake.nix" ]; then
  ok "flake at standard path"
else
  ng "flake missing at $FLAKE_DIR (clone-first bootstrap)"
fi
r="$(resolve nh)"
if [ -n "$r" ]; then ok "nh -> $r"; else ng "nh not resolvable (pre-cutover なら想定内)"; fi
if command -v fish >/dev/null 2>&1; then
  # shellcheck disable=SC2016  # fish 側で展開させる意図的なシングルクォート
  v="$(fish -lc 'echo $NH_FLAKE' 2>/dev/null || true)"
  if [ "$v" = "$FLAKE_DIR" ]; then
    ok "NH_FLAKE set"
  else
    ng "NH_FLAKE is '$v' (expected $FLAKE_DIR; pre-cutover なら想定内)"
  fi
fi

# PATH 順序契約: nix profile が ~/.cargo/bin より前(standalone のみ。
# 掃除後は衝突バイナリが消えて解決結果だけでは順序違反を検出できないため、
# 順序そのものを検査する — 2 巡目レビュー指摘)
if [ ! -e /etc/NIXOS ] && command -v fish >/dev/null 2>&1; then
  # shellcheck disable=SC2016
  if fish -lc 'set -l ip (contains -i ~/.nix-profile/bin $PATH); set -l ic (contains -i ~/.cargo/bin $PATH); test -n "$ip"; and test -n "$ic"; and test "$ip" -lt "$ic"' 2>/dev/null; then
    ok "PATH order: nix profile before ~/.cargo/bin"
  else
    ng "PATH order violated (dotfiles config.fish の cargo 前置行を確認 — Task 15 Step 4)"
  fi
fi

if [ "$MODE" = "--critical" ]; then
  if [ "$FAIL" = 0 ]; then echo "check-env (critical): PASS"; fi
  exit "$FAIL"
fi

# --- full: 非 Nix 前提(ubuntu-wsl のみ。NixOS では宣言側が担う)---
if [ ! -e /etc/NIXOS ]; then
  command -v gcc >/dev/null 2>&1 || ng "build-essential missing (run install-system-packages)"
  command -v docker >/dev/null 2>&1 || ng "docker missing"
  if ss -tln 2>/dev/null | grep -q ':2375'; then
    ng "docker listening on tcp/2375 (removed by #38; fix daemon config)"
  else
    ok "no docker tcp exposure"
  fi
  if locale -a 2>/dev/null | grep -qiE "ja_JP.(utf8|UTF-8)"; then
    ok "ja_JP.UTF-8 locale generated"
  else
    ng "ja_JP.UTF-8 locale missing (run install-system-packages)"
  fi
fi

if [ "$FAIL" = 0 ]; then echo "check-env: PASS"; fi
exit "$FAIL"
