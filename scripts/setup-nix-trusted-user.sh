#!/usr/bin/env bash
set -euo pipefail

echo "=== Nix Trusted User Setup ==="
echo

# 現在のユーザーを取得
CURRENT_USER=$(whoami)

# OSを検出
if [[ "$OSTYPE" == "darwin"* ]]; then
    NIX_DAEMON_SERVICE="org.nixos.nix-daemon"
    RESTART_CMD="sudo launchctl kickstart -k system/$NIX_DAEMON_SERVICE"
elif command -v systemctl &> /dev/null; then
    NIX_DAEMON_SERVICE="nix-daemon"
    RESTART_CMD="sudo systemctl restart $NIX_DAEMON_SERVICE"
else
    echo "⚠️  Warning: Unable to detect service manager (systemd or launchd)"
    RESTART_CMD="echo 'Please restart nix-daemon manually'"
fi

# /etc/nix/nix.confが存在するか確認
if [[ ! -f /etc/nix/nix.conf ]]; then
    echo "Creating /etc/nix/nix.conf..."
    sudo mkdir -p /etc/nix
    sudo touch /etc/nix/nix.conf
fi

# 現在のtrusted-users設定を確認
CURRENT_TRUSTED_USERS=$(grep -E "^trusted-users" /etc/nix/nix.conf 2>/dev/null || echo "")

if [[ -z "$CURRENT_TRUSTED_USERS" ]]; then
    # trusted-users行が存在しない場合
    echo "Adding trusted-users configuration..."
    echo "trusted-users = root $CURRENT_USER" | sudo tee -a /etc/nix/nix.conf > /dev/null
elif echo "$CURRENT_TRUSTED_USERS" | grep -q "$CURRENT_USER"; then
    # すでに設定されている場合
    echo "✓ User '$CURRENT_USER' is already a trusted user"
else
    # trusted-users行は存在するが、現在のユーザーが含まれていない場合
    echo "Adding '$CURRENT_USER' to trusted-users..."
    sudo sed -i.bak "s/^trusted-users.*/& $CURRENT_USER/" /etc/nix/nix.conf
fi

echo
echo "Current /etc/nix/nix.conf:"
echo "=========================="
sudo cat /etc/nix/nix.conf
echo "=========================="
echo

# Nixデーモンを再起動
echo "Restarting Nix daemon..."
eval "$RESTART_CMD"

echo
echo "✓ Setup complete!"
echo
echo "You can now use Nix commands without trusted user warnings."
echo "The binary cache will be used automatically, significantly speeding up builds."
echo
echo "Next steps:"
echo "  nix --experimental-features 'nix-command flakes' run .#install-system-packages"
echo "  nix --experimental-features 'nix-command flakes' run home-manager/master -- switch --flake .#shishi@ubuntu"