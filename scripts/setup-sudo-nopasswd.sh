#!/usr/bin/env bash
set -euo pipefail

echo "=== Sudo No-Password Setup ==="
echo

# 現在のユーザーを取得
CURRENT_USER=$(whoami)

# rootユーザーでは実行しない
if [[ "$CURRENT_USER" == "root" ]]; then
  echo "❌ This script should not be run as root"
  exit 1
fi

echo "Setting up passwordless sudo for user: $CURRENT_USER"
echo

# 既存の設定を確認
if [[ -f "/etc/sudoers.d/50-$CURRENT_USER-nopasswd" ]]; then
  echo "⚠️  Passwordless sudo is already configured for $CURRENT_USER"
  echo "To remove it, run: sudo rm /etc/sudoers.d/50-$CURRENT_USER-nopasswd"
  exit 0
fi

# sudoersディレクトリが存在することを確認
sudo mkdir -p /etc/sudoers.d

# ユーザー用のsudoersファイルを作成
# 一時ファイルを作成して、visudoで検証してから設置
TEMP_FILE=$(mktemp)
echo "$CURRENT_USER ALL=(ALL) NOPASSWD: ALL" >"$TEMP_FILE"

# visudoで構文チェック
if sudo visudo -c -f "$TEMP_FILE" >/dev/null 2>&1; then
  # 検証が成功したら、正式な場所にコピー
  sudo cp "$TEMP_FILE" "/etc/sudoers.d/50-$CURRENT_USER-nopasswd"
  sudo chmod 0440 "/etc/sudoers.d/50-$CURRENT_USER-nopasswd"

  # 一時ファイルを削除
  rm -f "$TEMP_FILE"

  echo
  echo "✅ Passwordless sudo has been configured for $CURRENT_USER"
  echo
  echo "⚠️  SECURITY WARNING:"
  echo "   This configuration allows sudo without password."
  echo "   Only use this in development environments!"
  echo
  echo "To remove this configuration later, run:"
  echo "   sudo rm /etc/sudoers.d/50-$CURRENT_USER-nopasswd"
else
  echo "❌ Failed to validate sudoers syntax"
  rm -f "$TEMP_FILE"
  exit 1
fi

