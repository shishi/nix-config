# NixOS での Slate サービス運用

このリポジトリーの Slate 用 NixOS 構成を使う管理者向けの手順です。
Main は Vault と Web 画面を提供し、Run は別ユーザーで HTML を実行します。
構成の適用先、ソースディレクトリー、Vault、state、公開 Origin は、
使用するホストの `slate.nix` で設定します。
Vault は書き込み可能な保存先、state は Vault 外のローカルディスクに置きます。

## サービスとビルド

| 定義 | 役割 |
| --- | --- |
| `slate.service` | Main。Vault と state を読み書きします |
| `slate-run.service` | Run。Vault と state を参照できません |
| `slate-build.service` | Main と Run を停止して依存を導入し、サーバーと Web をビルドします |
| `slate-serve.service` | Main と Run を別々の Tailscale Service として公開します |
| `slate-update` | ビルド成功後に Main と Run を起動し、HTTP の準備完了を待ちます |

Slate は作業ツリーの `apps/server/dist` と `apps/web/dist` を直接使います。
Nix は Bun、Node.js、coreutils と systemd の実行環境を管理します。
実行ツールを更新する場合は、`nixpkgs-slate` input と Slate の `flake.lock` を合わせて検証します。

## 初回の導入

ソースの checkout、Vault と state の読み書き権限、Tailscale の接続を用意します。
Tailscale の管理画面で `slate` と `slate-run` の Service と TCP 443 番を登録し、
配備先を両 Service のホストとして承認します。公開 Origin は NixOS 構成と一致させます。

このリポジトリーのルートで、`<構成名>` を適用先の flake 構成名へ置き換えて実行します。

```sh
SLATE_HOST_CONFIG='<構成名>'
nix build ".#nixosConfigurations.${SLATE_HOST_CONFIG}.config.system.build.toplevel" --dry-run
nix build ".#nixosConfigurations.${SLATE_HOST_CONFIG}.config.system.build.toplevel"
```

同じポートや Vault を使用する既存の Slate がある場合は、起動元で停止し、
自動起動を無効にしてから新しい構成を適用します。

```sh
sudo nixos-rebuild switch --flake ".#${SLATE_HOST_CONFIG}"
sudo slate-update
```

Main と Run はシステムサービスとして起動し、ユーザーのログインに依存しません。
初回ビルドが成功するまでは起動しません。

## 更新・切り戻し

Slate のソースと lockfile を更新してから実行します。

```sh
sudo slate-update
```

ビルド中は利用できません。制限時間は `slate.nix` の `slate-build.service` にある
`TimeoutStartSec` で定め、失敗時は両サーバーが停止したままになります。
`apps/server/dist/.slate-build-ready` はビルド開始時に削除され、成功時だけ作成されます。
この印がなければホスト再起動後も Main と Run は起動しません。印を手動で作らず、
ビルドエラーを修正して `sudo slate-update` を再実行してください。
稼働中の配信ファイルを置き換えないよう、更新には `bun run build` の直接実行を使いません。

切り戻しはソースと lockfile を戻し、同じコマンドで再ビルドします。
Vault、SQLite、履歴、ごみ箱は巻き戻しません。
戻すアプリが現在のデータ形式を扱えることが条件です。

## 起動・障害の確認

```sh
systemctl status slate.service slate-run.service slate-serve.service
journalctl -u slate-build.service -u slate.service -u slate-run.service -n 80 --no-pager
curl --fail http://127.0.0.1:8787/readyz
curl --fail http://127.0.0.1:8789/ --output /dev/null
tailscale serve status
```

公開 URL から Main の読み書きと Run の HTML 実行も確認します。
ローカル HTTP の成功だけでは、Tailscale 側のホスト承認や公開設定を検証できません。

Main と Run は異常終了後に待機して再起動します。再試行間隔と停止時の待機上限は、
`slate.nix` の共通設定 `runtimeService` にある `RestartSec` と `TimeoutStopSec` で定めます。
NAS を使用している場合、HTTP の生存確認だけでは NAS への書き込みを確認できません。
接続を復旧し、未完了の保存操作が残っている場合は Main を再起動します。

```sh
sudo systemctl restart slate.service
```

バックアップ・復元と `.slate-tmp-*` の扱いは
[Slate のサーバー運用ガイド](https://github.com/shishi/slate/blob/main/docs/server-operations.md)を参照してください。
