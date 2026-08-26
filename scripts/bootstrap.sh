# 新しいマシンの初期設営を 1 コマンドに畳む:
#   nix run github:shishi/nix-config#bootstrap
#
# 順序は clone(無認証 HTTPS)→ dotfiles setup → nix 適用 → SSH 鍵の案内。
# nix-config / dotfiles は public repo のため、SSH 鍵が無い段階から完走できる。
# 鍵が要るのは push と private repo(agent-memory)だけなので、最後に状態を
# 確認して案内を出すに留める。全手順は再実行して安全(冪等)。
#
# 動作前提: nix が導入済みであること(nix run で叩く時点で満たされる)。
# NixOS 実機は checked nixos-anywhere wrapper が SSH / GPG 鍵を配送する。
# その経路でインストール済みなら [4/4] は認証 OK 側を通る。

# パスは NH_FLAKE / check-env の契約と一致していなければならないため固定
# (README「初回起動後の手順」参照)
GHQ_ROOT="$HOME/dev/src"
NIX_CONFIG_DIR="$GHQ_ROOT/github.com/shishi/nix-config"
DOTFILES_DIR="$GHQ_ROOT/github.com/shishi/dotfiles"

clone_if_absent() {
  url="$1"
  dir="$2"
  marker="$3" # checkout 完了の目印になる repo 内ファイル
  if [ -e "$dir/.git" ]; then
    # 中断された clone は .git だけ残ることがある。誤って「済み」と
    # 判定すると後段が欠損ファイルで分かりにくく失敗するため、ここで止める
    if [ ! -e "$dir/$marker" ]; then
      echo "bootstrap: $dir に .git はあるが $marker が無い(中断された clone?)。" >&2
      echo "bootstrap: 中身を確認し、不要ならディレクトリを退避・削除して再実行すること" >&2
      exit 1
    fi
    echo "bootstrap: $dir は clone 済み(skip)"
    return 0
  fi
  mkdir -p "$(dirname "$dir")"
  git clone "$url" "$dir"
}

echo "bootstrap: [1/4] repos を clone(公開 repo・無認証 HTTPS)"
clone_if_absent https://github.com/shishi/nix-config.git "$NIX_CONFIG_DIR" flake.nix
clone_if_absent https://github.com/shishi/dotfiles.git "$DOTFILES_DIR" setup.sh

echo "bootstrap: [2/4] dotfiles setup"
bash "$DOTFILES_DIR/setup.sh"

echo "bootstrap: [3/4] nix 適用"
if [ -f /etc/NIXOS ]; then
  if command -v nh >/dev/null 2>&1; then
    nh os switch
  else
    sudo nixos-rebuild switch --flake "$NIX_CONFIG_DIR"
  fi
else
  # standalone(非 NixOS)は repo の公認適用経路(check-env 込み)を使う
  nix run "$NIX_CONFIG_DIR#switch"
fi

echo "bootstrap: [4/4] SSH 鍵の状態"
# ssh -T は認証成功でも exit 1 を返すため、pipefail 下では || true で
# 終了 status を判定から外し、出力メッセージだけを見る
if { ssh -o BatchMode=yes -o ConnectTimeout=5 -T git@github.com 2>&1 || true; } |
  grep -q "successfully authenticated"; then
  echo "bootstrap: GitHub への SSH 認証 OK(push / private repo 利用可)"
else
  cat >&2 <<'EOF'
bootstrap: GitHub への SSH 認証が未設営。clone(公開 repo)はこのまま動くが、
push と private repo(agent-memory)には鍵が要る。

共有鍵(shared/authorized-keys.nix の 1 本)を earth から持ち込む:
  install -d -m 700 ~/.ssh
  scp earth:.ssh/id_ed25519 ~/.ssh/id_ed25519 && chmod 600 ~/.ssh/id_ed25519
  # NixOS 実機では checked nixos-anywhere wrapper が SSH / GPG 鍵を配送する。
  # ここに来た場合は docs/jupiter-secure-boot-runbook.md の暗号化 install workflow を確認する

代替(earth に届かない等): このマシン専用の鍵を作って GitHub に登録する
(既存の ~/.ssh/id_ed25519 が居る場合は keygen を飛ばして登録だけ行う。
 上書き承諾すると既存鍵を失う):
  [ -f ~/.ssh/id_ed25519 ] || ssh-keygen -t ed25519
  gh auth login          # ブラウザのデバイスコード認証
  gh ssh-key add ~/.ssh/id_ed25519.pub --title "$(hostname)"
EOF
fi
