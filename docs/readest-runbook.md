# Readest の運用

## 利用の前提

この構成は Readest の Web 版と同期用バックエンドを Docker Compose で起動します。
Nixpkgs の `readest` はデスクトップ版のため、サーバーには上流のコンテナーを使います。
Compose の起動・停止はユーザーの systemd が管理します。
Docker デーモンはシステムのサービスとして動きます。
ユーザーの linger により、ログアウト後も Readest を稼働させます。
S3 互換ストレージには SeaweedFS の単一プロセス構成を使います。
上流 Compose のストレージ用イメージを取得できないため置き換えています。
Docker グループのメンバーはホストの管理者相当の権限を持ちます。

利用前に Tailscale へログインし、tailnet の HTTPS 証明書を有効にします。
ホスト自身の HTTPS ポート 443 は Readest 専用にします。
Tailscale Services の個別サービス名で公開するほかのアプリとは併用できます。
Tailscale Serve は tailnet 内へ公開し、インターネットへの Funnel は設定しません。

初回起動時にホストの Tailscale DNS 名から HTTPS の公開元 URL を決めます。
パスワードと JWT の署名鍵も初回に生成します。
`${XDG_DATA_HOME:-$HOME/.local/share}/readest/.env` を所有者だけが読める権限で保存します。
再起動しても既存のファイルを保持します。
秘密情報を Nix store や Git に保存する必要はありません。

## 起動と状態確認

NixOS 構成を反映すると、`readest.service` と `readest-serve.service` が自動起動します。
手動で起動する場合も、操作はサービスを使います。

```bash
systemctl --user start readest-serve
systemctl --user status readest readest-serve
readest-compose ps
journalctl --user -u readest -u readest-serve -n 100
```

公開 URL は次のコマンドで確認します。表示された HTTPS URL をブラウザーで開きます。

```bash
readest-compose exec -T client printenv API_BASE_URL
```

`http://127.0.0.1:3080` はホスト内からの疎通確認用です。
Tailscale Serve はフォアグラウンドで動くため、通常の `tailscale serve status` には
表示されません。公開設定の詳細は `tailscale serve status --json` の `Foreground` で確認します。
認証、同期、ブラウザーの保存領域を使う通常操作では HTTPS URL を使います。
公開元を変更するときは `.env` 内の `SITE_URL`、`API_EXTERNAL_URL`、
`SUPABASE_PUBLIC_URL`、`S3_PUBLIC_ENDPOINT`、`ADDITIONAL_REDIRECT_URLS` を合わせます。
ブラウザーのローカルデータは公開元ごとに分かれるため、URL を変える前に同期します。

同じ HTTPS 公開元で、`/` は Web アプリへ転送します。
`/auth/v1/` と `/rest/v1/` は Supabase へ転送します。
`/readest-files/` は本のファイルを保存する SeaweedFS へ転送します。
ホストへ公開するコンテナーポートは `127.0.0.1:3080` だけです。

アカウントはこの Web 版で作成します。メール確認は省略し、SMTP は使いません。
別のブラウザーでも同じ HTTPS URL を開き、同じアカウントにログインして同期します。
公式 Readest クラウドのアカウントやデータは、この環境へ自動で移行しません。

## 停止と再起動

```bash
systemctl --user stop readest-serve readest
systemctl --user start readest-serve
systemctl --user restart readest
```

停止時は Compose の `down` でコンテナーとネットワークを除去します。
PostgreSQL と SeaweedFS の named volume、および `.env` は保持します。
再起動すると HTTPS 公開も再起動します。

`readest-compose` は、この構成の Compose ファイルと `.env` を指定するラッパーです。
通常の Compose 引数を渡せます。

```bash
readest-compose logs --tail 100 client auth rest
readest-compose exec db psql -U supabase_admin -d postgres
```

手動の `readest-compose up` はフォアグラウンドで起動します。
`readest-compose down` はコンテナーを止めますが、systemd の状態管理から外れます。
通常は `systemctl --user` で操作してください。
`down --volumes` は保存データを削除するため、通常の停止には使いません。

## バックアップと復元

保存対象は `.env` と、`readest_db-data`、`readest_db-config`、
`readest_storage-data` の 3 つの Docker volume です。
`.env` には既存データへ接続するためのパスワードと署名鍵が入っています。
volume と同じ世代の `.env` を安全な場所へ保管します。

ファイルとして volume を保存する場合は、両サービスを停止してから取得します。
稼働中の PostgreSQL データディレクトリをコピーしてはいけません。
保存先を用意し、Docker の volume バックアップ手順で 3 つとも保存します。
volume の一覧と格納場所は次のコマンドで確認できます。

```bash
systemctl --user stop readest-serve readest
docker volume inspect readest_db-data readest_db-config readest_storage-data
```

復元時もサービスを停止します。
同じ名前の volume へデータを戻し、同世代の `.env` を元の場所へ戻します。
`.env` の権限を `0600`、格納ディレクトリを `0700` にしてから起動します。
バックアップの検証は別環境で復元し、ログイン、本のダウンロード、同期を確認します。

## 更新と制限

コンテナーのバージョンと上流 SQL の版は Nix モジュールで固定します。
更新時は両方の互換性を確認して構成を変更し、反映前にバックアップします。
既存の PostgreSQL volume では初期化 SQL は再実行しません。
上流の migration を更新した場合は、起動後に次を実行します。

```bash
readest-compose exec db /docker-entrypoint-initdb.d/zz-readest-migrations.sh
```

適用済みの migration は上流の管理テーブルで判別します。
スキーマ更新後の切り戻しは、コンテナーの版だけを戻しても成立するとは限りません。
必要な場合は更新前の volume と `.env` をまとめて復元します。

ストレージ容量は上流の既定値の 1 アカウント 1 GiB です。
翻訳枠は 1 アカウントにつき 1 日 50,000 文字で、UTC 0 時（日本時間 9 時）にリセットします。
外部翻訳・音声サービスの認証情報やメール受信経路はこの構成に含めません。

上流 CDN の CJK Web フォントは、独自ドメインでは CORS 制限を受けます。
必要ならフォントを別途配信し、`.env` の `FONT_BASE_URL` をその URL にします。
システムフォントと Google Fonts はこの制限の対象外です。
