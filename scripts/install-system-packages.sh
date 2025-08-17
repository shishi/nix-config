#!/usr/bin/env bash
# Ubuntu専用: Nixで管理しにくいシステムパッケージのインストールスクリプト

set -euo pipefail

# 色付き出力用の定数
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly RED='\033[0;31m'
readonly NC='\033[0m'

log_info() {
  echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
  echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
  echo -e "${RED}[ERROR]${NC} $1"
}

# APTパッケージのインストール
install_apt_packages() {
  log_info "システムパッケージのインストールを開始します"

  sudo apt update
  sudo apt-get install -yqq --no-install-recommends build-essential pkg-config software-properties-common

  log_info "システムパッケージのインストールが完了しました"
}

install_docker() {
  log_info "dockerのインストールを開始します"

  # Add Docker's official GPG key:
  sudo apt-get update
  sudo apt-get install ca-certificates curl
  sudo install -m 0755 -d /etc/apt/keyrings
  sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  sudo chmod a+r /etc/apt/keyrings/docker.asc

  # Add the repository to Apt sources:
  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}") stable" |
    sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
  sudo apt-get update
  sudo apt-get update -qq
  sudo apt-get install -yqq --no-install-recommends docker-ce docker-ce-cli containerd.io docker-compose-plugin docker-buildx-plugin golang-docker-credential-helpers qemu-user-static

  sudo usermod -aG docker "${USER}"
  sudo systemctl enable --now docker
  sudo systemctl stop docker

  sudo mkdir -p /etc/systemd/system/docker.service.d
  sudo rm -f /etc/systemd/system/docker.service.d/override.conf
  sudo touch /etc/systemd/system/docker.service.d/override.conf
  cat <<EOF | sudo tee /etc/systemd/system/docker.service.d/override.conf
[Service]
ExecStart=
ExecStart=/usr/bin/dockerd -H fd:// -H tcp://0.0.0.0:2375
EOF

  sudo systemctl daemon-reload
  sudo systemctl start docker

  log_info "dockerのインストールが完了しました"
}

install_japanese_environment() {
  log_info "日本語環境のセットアップを開始します"

  # 日本語言語パックと日本語入力メソッドのインストール
  sudo apt-get update
  sudo apt-get install -yqq --no-install-recommends \
    language-pack-ja \
    language-pack-gnome-ja \
    fonts-noto-cjk \
    fonts-noto-cjk-extra \
    im-config \
    fcitx5 \
    fcitx5-skk \
    fcitx5-config-qt \
    fcitx5-frontend-all \
    skkdic \
    skkdic-extra

  # ロケールの生成
  sudo locale-gen ja_JP.UTF-8

  # im-configでfcitx5を設定
  im-config -n fcitx5

  # 自動起動設定
  # mkdir -p ~/.config/autostart

  # 環境変数の設定（.profileに追加）
  if ! grep -q "GTK_IM_MODULE=fcitx5" ~/.profile; then
    cat >>~/.profile <<'EOF'

# fcitx5 environment variables
export GTK_IM_MODULE=fcitx5
export QT_IM_MODULE=fcitx5
export XMODIFIERS=@im=fcitx5
export DefaultIMModule=fcitx5
EOF
  fi

  # libskk
  cat >~/.config/libskk/rules/StickyShift/metadata.json <<'EOF'
{
  "name": "Sticky Shift",
  "description": "Enable Sticky Shift"
}
EOF

  cat >~/.config/libskk/rules/StickyShift/keymap/hiragana.json <<'EOF'
{
    "include": [
        "default/hiragana"
    ],
    "define": {
        "keymap": {
            ";": "start-preedit-no-delete"
        }
    }
}
EOF

  cat >~/.config/libskk/rules/StickyShift/keymap/katakana.json <<'EOF'
{
  "include": [
      "default/katakana"
  ],
  "define": {
    "keymap": {
      ";": "start-preedit-no-delete"
    }
  }
}
EOF

  log_info "日本語環境のセットアップが完了しました"
  log_info "fcitx5はログアウト後に fcitx5-configtool で設定してください"
  log_warn "設定を反映するには再ログインが必要です"
}

main() {
  install_apt_packages
  install_docker
  install_japanese_environment

  log_info "すべてのインストールが完了しました"
  log_warn "日本語入力を使用するには再ログインしてください"
}

# 直接実行時のみmainを実行
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
