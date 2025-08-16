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
    sudo apt-get install -yqq --no-install-recommends \
        language-pack-ja \
        language-pack-gnome-ja \
        fonts-noto-cjk \
        fonts-noto-cjk-extra \
        fcitx5 \
        fcitx5-skk \
        fcitx5-config-qt \
        fcitx5-frontend-gtk3 \
        fcitx5-frontend-gtk4 \
        fcitx5-frontend-qt5 \
        libskk0 \
        skkdic \
        skkdic-extra

    # ロケールの生成
    sudo locale-gen ja_JP.UTF-8

    # im-configでfcitx5を設定
    im-config -n fcitx5

    # fcitx5の自動起動設定
    mkdir -p ~/.config/autostart
    cp /usr/share/applications/org.fcitx.Fcitx5.desktop ~/.config/autostart/

    # 環境変数の設定（.profileに追加）
    if ! grep -q "GTK_IM_MODULE=fcitx" ~/.profile; then
        cat >>~/.profile <<'EOF'

# Fcitx5 environment variables
export GTK_IM_MODULE=fcitx
export QT_IM_MODULE=fcitx
export XMODIFIERS=@im=fcitx
export DefaultIMModule=fcitx
EOF
    fi

    # fcitx5-skkの設定ディレクトリを作成
    mkdir -p ~/.config/fcitx5/conf

    # sticky shift設定（セミコロンキー）
    cat >~/.config/fcitx5/conf/skk.conf <<'EOF'
# SKK設定
# Sticky Shiftキーの設定
StickyKey=semicolon

# その他のSKK設定
InitialInputMode=Latin
PageSize=8
CandidateChooseKeys=asdfhjkl
ShowAnnotation=True
EOF

    # fcitx5のプロファイル設定
    mkdir -p ~/.config/fcitx5/profile
    cat >~/.config/fcitx5/profile/default <<'EOF'
[Groups/0]
# Group 1
Name=Default
Default Layout=us
DefaultIM=skk

[Groups/0/Items/0]
Name=keyboard-us
Layout=

[Groups/0/Items/1]
Name=skk
Layout=
EOF

    # fcitx5グローバル設定
    cat >~/.config/fcitx5/config <<'EOF'
[Hotkey]
# 入力メソッドの切り替え
TriggerKeys=
# 入力メソッドをオフに
DeactivateKeys=

[Hotkey/TriggerKeys]
0=Control+space
1=Zenkaku_Hankaku

[Hotkey/DeactivateKeys]
0=Escape

[Behavior]
# デフォルトで最初の入力メソッドをアクティブに(SKKの英字モード)
ActiveByDefault=True
ShareInputState=No
ShowInputMethodInformation=True
EOF

    log_info "日本語環境のセットアップが完了しました"
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
