# Personal Nix Configuration

個人用のNix設定（flake-parts + home-manager）

## 機能

- 🏠 Home Manager によるユーザー環境管理
- 🦀 Rust開発環境（fenixによる最新ツールチェイン）
- 🇯🇵 日本語入力環境（fcitx5-skk + yaskkserv2）
- 🛠️ 開発ツール（Git, エディタ, シェル環境）
- 📦 カスタムパッケージとオーバーレイ
- 🐳 Docker環境のセットアップスクリプト
- ⚡ Nix flakes機能の自動有効化（Home Manager経由）

## セットアップ

### 前提条件

- Nix (2.4以降、flakes機能有効)
  ```bash
  # flakesが有効か確認
  nix --version
  # 有効でない場合は ~/.config/nix/nix.conf に以下を追加:
  # experimental-features = nix-command flakes
  ```
- Ubuntu（現在の設定対象）

### インストール手順

```bash
# 1. リポジトリのクローン
git clone https://github.com/shishi/nix-config.git
cd nix-config

# 2. システムパッケージのインストール（Ubuntu用）
nix --experimental-features 'nix-command flakes' run .#install-system-packages

# 3. Home Manager設定の適用
# 注: 初回実行時はhome-managerがダウンロードされます
nix --experimental-features 'nix-command flakes' run home-manager/master -- switch --flake .#shishi@ubuntu

# 4. 開発シェルに入る（オプション）
nix --experimental-features 'nix-command flakes' develop
```

**注意**: 
- `--experimental-features 'nix-command flakes'` オプションは初回実行時のみ必要です
- Home Manager適用後は、Nix設定が自動的に更新されflakesが有効になります
- 2回目以降は `nix run home-manager/master -- switch --flake .#shishi@ubuntu` で実行可能です
- `nix run home-manager/master` は Nix の flake 機能を使用して home-manager を自動的にダウンロード・実行するため、事前に home-manager をインストールする必要はありません

## ディレクトリ構成

```
.
├── flake.nix                # メインのflake定義
├── flake.lock              # 依存関係のロック
├── home-manager/           # Home Manager設定
│   ├── default.nix         # エントリーポイント
│   └── modules/            # 機能別モジュール
│       ├── dconf.nix       # デスクトップ設定
│       ├── editor.nix      # エディタ設定
│       ├── git.nix         # Git設定
│       ├── packages.nix    # インストールパッケージ一覧
│       ├── rust.nix        # Rust開発環境
│       ├── shell.nix       # シェル環境
│       └── yaskkserv2.nix  # 日本語入力サーバー
├── lib/                    # 共通ライブラリ関数
├── modules/                # flake-partsモジュール
├── overlays/               # Nixpkgsオーバーレイ
├── pkgs/                   # カスタムパッケージ定義
├── scripts/                # ヘルパースクリプト
│   └── install-system-packages.sh
├── shells/                 # 開発シェル定義
└── templates/              # プロジェクトテンプレート
    ├── basic/              # 基本的なNixプロジェクト
    └── rust/               # Rustプロジェクト
```

## 主な設定内容

### パッケージ管理
- 開発ツール: ripgrep, fd, bat, eza, zoxide
- プログラミング言語: Rust (fenix), Deno
- ユーティリティ: jq, yq, bottom, etc.

### 日本語環境
- fcitx5-skkによる日本語入力
- yaskkserv2による辞書サーバー（自動起動）
- セミコロンキーでのsticky shift設定済み

### 開発環境
- Rustツールチェイン（最新stable）
- Git設定（エイリアス、エディタ設定）
- シェル環境（環境変数、PATH設定）

## コマンド

```bash
# flakeのチェック
nix --experimental-features 'nix-command flakes' flake check

# フォーマット
nix --experimental-features 'nix-command flakes' fmt

# システムパッケージのインストール（Ubuntu）
nix --experimental-features 'nix-command flakes' run .#install-system-packages

# 新しいプロジェクトの作成
nix --experimental-features 'nix-command flakes' flake new -t .#basic my-project
nix --experimental-features 'nix-command flakes' flake new -t .#rust my-rust-project

# flakes機能を恒久的に有効にする場合
echo "experimental-features = nix-command flakes" >> ~/.config/nix/nix.conf
```

## 複数マシン対応

将来的に複数マシンに対応する場合：
1. flake.nixのhomeConfigurationsに新しいエントリを追加
2. ホスト固有の設定をhome-manager/hosts/に分離
3. 共通設定をモジュール化

## トラブルシューティング

### 日本語入力が動作しない場合
1. `install-system-packages.sh`を実行したか確認
2. 再ログインまたは再起動を実行
3. `systemctl --user status yaskkserv2`でサーバーの状態を確認

### Home Managerの適用でエラーが出る場合
```bash
# 設定の検証
nix --experimental-features 'nix-command flakes' flake check

# デバッグ情報付きで実行
nix --experimental-features 'nix-command flakes' run home-manager/master -- switch --flake .#shishi@ubuntu --show-trace
```
