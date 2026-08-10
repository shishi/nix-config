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
  sudo apt-get install -yqq --no-install-recommends build-essential pkg-config software-properties-common language-pack-ja

  sudo locale-gen ja_JP.UTF-8

  log_info "システムパッケージのインストールが完了しました"
}

install_docker() {
  log_info "dockerのインストールを開始します"

  # Add Docker's official GPG key:
  sudo apt-get update
  sudo apt-get install -yqq --no-install-recommends ca-certificates curl
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

  # #38 裁定: TCP 公開(tcp://0.0.0.0:2375 無認証)は廃止。過去の override も除去する
  if [ -f /etc/systemd/system/docker.service.d/override.conf ]; then
    sudo systemctl stop docker
    sudo rm -f /etc/systemd/system/docker.service.d/override.conf
    sudo systemctl daemon-reload
    sudo systemctl restart docker
  fi

  log_info "dockerのインストールが完了しました"
}

main() {
  install_apt_packages
  install_docker

  log_info "すべてのインストールが完了しました"
}

# 直接実行時のみmainを実行
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
