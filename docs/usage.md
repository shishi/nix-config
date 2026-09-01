# 利用手順

## earth

### Flake app

| app | コマンド | 使う場面 |
|---|---|---|
| `bootstrap` | `nix run github:shishi/nix-config#bootstrap` | 新しい earth にリポジトリと dotfiles を配置し、設定適用までまとめて進める |
| `switch` | `nix run .#switch` | earth の設定を適用する。`nh home switch` と異なり、適用前の必須検査と適用した revision の記録を含む |
| `check-env` | `nix run .#check-env` | `switch` の必須検査に加え、Docker とロケールを含む earth の前提をまとめて診断する |
| `rust-bootstrap` | `nix run .#rust-bootstrap` | rustup の stable／nightly と管理対象の Cargo ツールを揃える。`-- --repair` は壊れた管理対象ツールを再導入し、この app が過去に導入して管理対象外になった crate を削除する |
| `setup-sudo-nopasswd` | `nix run .#setup-sudo-nopasswd` | earth の初期構築で、現在のユーザーにパスワードなしの sudo を設定する |
| `setup-trusted-user` | `nix run .#setup-trusted-user` | earth の初期構築で、現在のユーザーを Nix の `trusted-users` に追加する |
| `install-system-packages` | `nix run .#install-system-packages` | earth の初期構築で、Nix 管理外のビルド環境、Docker、`ja_JP.UTF-8` ロケールを導入する |

### 初期構築

```bash
nix run github:shishi/nix-config#bootstrap
```

### 設定の適用

```bash
nix run .#switch
```

## jupiter

### Flake app

| app | コマンド | 使う場面 |
|---|---|---|
| `jupiter-secrets` | `nix run .#jupiter-secrets` | SOPS ファイルを手作業で編集せず、Jupiter の秘密情報を一時領域で作成・更新して暗号化する |
| `jupiter-install` | `nix run .#jupiter-install -- --target-host root@<target> …` | Jupiter の構成を固定し、公開鍵配置(未配置なら root パスワードを 1 回)→ disko(ディスク全消去 + LUKS)→ 対象機上での Secure Boot 鍵生成 → install(秘密の配送 + NixOS 本体)→ 配送確認を固定順で実行する |
| `bootstrap` | `nix run github:shishi/nix-config#bootstrap` | Jupiter の初回起動後にリポジトリと dotfiles を配置し、設定適用までまとめて進める |

### 初期構築

1. [秘密情報を準備する](#秘密情報)
2. [NixOS をインストールする](jupiter-install-runbook.md)
3. 初回起動後にセットアップする。

```bash
nix run github:shishi/nix-config#bootstrap
```

4. [生体認証を登録する](#生体認証)
5. [Secure Boot と TPM2 自動解錠を設定する](jupiter-secure-boot-runbook.md)

### 設定の適用

```bash
nh os switch
```

### 秘密情報

管理用 age 鍵をパスワードマネージャーから復元する。

```bash
install -m 600 /path/to/management-age-key.txt secrets/management-age-key.txt
```

値を変更する場合だけ実行する。空 Enter は現在値を維持する。

```bash
nix run .#jupiter-secrets
git add secrets/jupiter/.sops.yaml secrets/jupiter/bootstrap.yaml secrets/jupiter/runtime.yaml
git check-ignore secrets/management-age-key.txt
git commit secrets/jupiter/.sops.yaml secrets/jupiter/bootstrap.yaml secrets/jupiter/runtime.yaml -m "chore(secrets): update encrypted inputs"
```

入力項目:

1. LUKS パスフレーズ
2. ログインパスワード
3. SMB パスワード
4. Tailscale OAuth クライアントシークレット

初回作成、パスワード変更、鍵の復旧は
[秘密情報の手順書](jupiter-secrets-runbook.md)を使う。

### 生体認証

jupiter の実機で登録する。

```bash
sudo linux-enable-ir-emitter configure
sudo howdy add
sudo howdy -U shishi list
sudo fprintd-enroll shishi
fprintd-list shishi
```

## dns-osaka-1

| app | コマンド | 使う場面 |
|---|---|---|
| `dns-osaka-1-secrets` | `nix run .#dns-osaka-1-secrets` | DNS ホスト専用の Tailscale・FreshRSS 秘密情報を編集する |
| `dns-osaka-1-install` | `nix run .#dns-osaka-1-install` | 固定した Oracle VPS へ DNS ホスト構成をインストールする |

導入と運用は [dns-osaka-1 手順書](dns-osaka-1-runbook.md)を使う。

## リポジトリ管理

| app | コマンド | 使う場面 |
|---|---|---|
| `update`（default） | `nix run .#update` | Flake input と独自パッケージ `yaskkserv2` を更新し、`nix flake check` を実行する。`nix flake update` だけでは `yaskkserv2` は更新されないため、通常はこちらを使う |

`update` は未コミットの変更がない checkout で実行する。更新結果は現在の checkout に未コミット差分として残るので、内容を確認してからcommitする。各ホストの完全なビルドと適用は、そのホストを更新するときに行う。
