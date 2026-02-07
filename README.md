# nix-config

flake-parts + home-manager による個人用 Nix 設定

## セットアップ

Nix をインストールして flakes を有効にしておく。

```bash
git clone https://github.com/shishi/nix-config.git
cd nix-config

nix run .#setup-sudo-nopasswd
nix run .#setup-trusted-user
nix run .#install-system-packages
nix run home-manager/master -- switch --flake .#shishi@ubuntu
```

初回は各コマンドに `--extra-experimental-features 'nix-command flakes'` が必要。
Home Manager 適用後は flakes が自動で有効になる。

## 更新

```bash
nix run home-manager/master -- switch --flake .#shishi@ubuntu

# nom でビルドログを見やすくする
nix run home-manager/master -- switch --flake .#shishi@ubuntu 2>&1 | nom
```

## nix run で使えるコマンド

| コマンド | 内容 |
|---|---|
| `nix run .#setup-sudo-nopasswd` | sudo パスワード不要設定（開発環境専用） |
| `nix run .#setup-trusted-user` | Nix trusted user 設定 |
| `nix run .#install-system-packages` | Ubuntu システムパッケージのインストール |

## テンプレート

```bash
nix flake new -t .#basic my-project
nix flake new -t .#rust my-rust-project
```
