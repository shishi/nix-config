# インストール時に --extra-files と --disk-encryption-keys で運ぶ secrets/ の検査。
#
# nixos-anywhere の app がこれを先に実行する。README に書くだけだと、書いたことを
# 読まないまま実行できてしまい、欠けたことに気づくのは初回起動後になる
# (パスワードハッシュが無ければ shadow が `!` になり、autoLogin で上がった
# セッションのロックを解除できない)。ここで止める。
#
# 値そのものは絶対に出力しない。長さと形式だけを見る。

set -uo pipefail

root=$PWD
while [ ! -e "$root/flake.nix" ] && [ "$root" != "/" ]; do
  root=$(dirname "$root")
done
if [ ! -e "$root/flake.nix" ]; then
  echo "check-install-secrets: flake.nix が見つからない。repo の中で実行すること" >&2
  exit 1
fi
cd "$root"

ng=0
ok()  { printf '  ok    %s\n' "$1"; }
bad() { printf '  NG    %s\n      %s\n' "$1" "$2" >&2; ng=1; }

need_file() { # path 説明 期待mode
  local p=$1 what=$2 want=$3
  if [ ! -e "$p" ]; then
    bad "$p" "無い。$what"
    return 1
  fi
  if [ ! -s "$p" ]; then
    bad "$p" "空。$what"
    return 1
  fi
  local m
  m=$(stat -c %a "$p")
  if [ "$m" != "$want" ]; then
    bad "$p" "mode $m。$want であること($what)"
    return 1
  fi
  return 0
}

need_dir_traversable() { # path
  local p=$1 m
  if [ ! -d "$p" ]; then
    bad "$p" "ディレクトリが無い"
    return 1
  fi
  m=$(stat -c %a "$p")
  case "$m" in
    *[157]) ;; # other に x がある
    *) bad "$p" "mode $m。other に実行権が無いと、インストール後に同じパスの mode になって配下が辿れなくなる" ; return 1 ;;
  esac
  return 0
}

one_line_no_edge_space() { # path 説明
  local p=$1 what=$2 n
  n=$(wc -l < "$p")
  if [ "$n" -gt 1 ]; then
    bad "$p" "$n 行ある。1 行だけにする($what)"
    return 1
  fi
  local raw trimmed
  raw=$(cat "$p")
  trimmed=$(printf '%s' "$raw" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
  if [ "$raw" != "$trimmed" ]; then
    bad "$p" "前後に空白がある。手順は末尾改行しか落とさないので、空白は値の一部になる($what)"
    return 1
  fi
  return 0
}

echo "secrets/ の検査(値は表示しない)"

# --- 手順 1 が読む LUKS パスフレーズ ---
if need_file secrets/luks-passphrase "手順 1 の disko と §6 の遠隔復旧で使う" 600; then
  if one_line_no_edge_space secrets/luks-passphrase "LUKS パスフレーズ"; then
    ok "secrets/luks-passphrase ($(wc -c < secrets/luks-passphrase) バイト)"
  fi
fi

# --- 手順 0b が読むログインパスワード ---
if need_file secrets/login-password "手順 0b で mkpasswd に食わせる。RDP とコンソールのログインで打つ値" 600; then
  if one_line_no_edge_space secrets/login-password "ログインパスワード"; then
    ok "secrets/login-password ($(wc -c < secrets/login-password) バイト)"
  fi
fi

# --- --extra-files で運ぶもの ---
ef=secrets/extra-files
if [ ! -d "$ef" ]; then
  bad "$ef" "無い。手順 0b で作る(--extra-files に渡すディレクトリ)"
else
  need_dir_traversable "$ef"
  need_dir_traversable "$ef/home"
  need_dir_traversable "$ef/var"
  need_dir_traversable "$ef/var/lib"

  need_file "$ef/home/shishi/.ssh/id_ed25519" "初回起動後の private repo clone に要る" 600 \
    && ok "$ef/home/shishi/.ssh/id_ed25519"
  need_file "$ef/home/shishi/.ssh/id_ed25519.pub" "同上" 644 \
    && ok "$ef/home/shishi/.ssh/id_ed25519.pub"

  if need_file "$ef/home/shishi/gpg-secret.asc" "commit.gpgsign に要る。手順 5 で import する" 600; then
    if grep -q "BEGIN PGP PRIVATE KEY BLOCK" "$ef/home/shishi/gpg-secret.asc"; then
      ok "$ef/home/shishi/gpg-secret.asc"
    else
      bad "$ef/home/shishi/gpg-secret.asc" "armored な秘密鍵に見えない。<signingkey> の打ち間違いでも gpg は空でないファイルを残す"
    fi
  fi

  h=$ef/var/lib/secrets/shishi-password-hash
  if need_file "$h" "これが無いと shishi の shadow が ! になり、autoLogin のロックも RDP も通らない" 600; then
    # 先頭 3 バイトが yescrypt の印か。単一引用符で書くと shellcheck が SC2016 で
    # 止めるので、二重引用符の中の脱字(リテラルのドル記号)で書く。runbook の
    # 手順 0b が使っているのと同じ形。前方一致していれば除去で値が変わる。
    head3=$(head -c 3 "$h")
    if [ "${head3#\$y\$}" != "$head3" ]; then
      ok "$h (yescrypt)"
    else
      bad "$h" "yescrypt のハッシュで始まっていない。mkpasswd が失敗すると 0 バイトでない壊れた値が残ることがある"
    fi
  fi
fi

if [ "$ng" -ne 0 ]; then
  cat >&2 <<'EOF'

作り方は docs/jupiter-secure-boot-runbook.md の
  手順 0b(secrets/login-password と secrets/extra-files)
  手順 1 (secrets/luks-passphrase)
secrets/ は .gitignore 済みなので、値がコミットされることはない。
EOF
  exit 1
fi

echo "secrets/ は揃っている"
