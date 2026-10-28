# Readest の運用

## 利用の前提

この構成は Readest の Web 版と同期用バックエンドを Docker Compose で起動します。
Nixpkgs の `readest` はデスクトップ版のため、サーバーには上流の Dockerfile を使います。
公式イメージではオフライン用の Service Worker が生成されないため、固定したソースから Web 版をビルドします。
上流の Webpack 切替スクリプトで Service Worker を生成します。
画面の保存先と参照先は Serwist の標準ページキャッシュに揃え、圏外での起動に使います。
上流のビルド引数にセルフホストの接続先と公開用の認証キーを渡し、初期化時もその接続先を使います。
ビルド入力からイメージ名を決め、接続先が変わった場合も対応するイメージを作ります。
イメージがない場合だけ起動前にビルドし、通常の起動と再起動では完成済みのイメージを使います。
初回ビルドには外部レジストリへの接続、依存パッケージの取得とコンパイルが必要です。
ビルド時の Node のヒープ上限は 8 GiB で、ほかのプロセスが使うメモリも必要です。
初期化とビルド、イメージ取得のタイムアウトは各 30 分で、起動確認は約 6 分で失敗を返します。
ソースやパッチの更新時も新しいイメージを作り、起動前のビルド中は Web 版が停止します。
旧イメージは切り戻し用に残し、自動削除しません。
Compose の起動・停止はユーザーの systemd が管理します。
Docker デーモンはシステムのサービスとして動きます。
ユーザーの linger により、ログアウト後も Readest を稼働させます。
S3 互換ストレージには SeaweedFS の単一プロセス構成を使います。
上流 Compose のストレージ用イメージを取得できないため置き換えています。
Docker グループのメンバーはホストの管理者相当の権限を持ちます。

利用前に Tailscale へログインし、tailnet の HTTPS 証明書を有効にします。
tailnet 管理用リポジトリーから、`svc:readest` の TCP 443 を登録します。
`readest-serve` の起動でホストが広告された後、同じ管理用リポジトリーからホストを承認します。
承認後に HTTPS が応答しない場合は、`systemctl --user restart readest-serve` で再広告します。
Readest はこの専用 Tailscale Service へ公開します。
ホスト共用の HTTPS エンドポイントは使用しません。
インターネットへの Funnel は設定しません。

Service 名と tailnet の MagicDNS サフィックスから HTTPS の公開元 URL を決めます。
パスワードと JWT の署名鍵も初回に生成します。
`${XDG_DATA_HOME:-$HOME/.local/share}/readest/.env` を所有者だけが読める権限で保存します。
再起動時は既存の署名鍵・パスワード・任意設定を保持し、公開元 URL を専用 Service に揃えます。
秘密情報を Nix store や Git に保存する必要はありません。

## 起動と状態確認

通常の `nh os switch` で NixOS 構成を反映します。
Home Manager が `readest-compose` と user unit を配置します。
反映時に `readest.service` と `readest-serve.service` を自動起動します。
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
公開設定は `tailscale serve status --json` の `Services` にある `svc:readest` で確認します。
認証、同期、ブラウザーの保存領域を使う通常操作では HTTPS URL を使います。
認証・同期 API・本ファイル用の公開 URL は、起動時に同じ Service の公開元へ更新します。
ブラウザーのローカルデータは公開元ごとに分かれ、自動移行しません。
サーバーへ同期済みの本と読書状態は、新しい公開元で同じアカウントにログインして取得します。

同じ HTTPS 公開元で、`/` は Web アプリへ転送します。
`/auth/v1/` と `/rest/v1/` は Supabase へ転送します。
`/readest-files/` は本のファイルを保存する SeaweedFS へ転送します。
`/nas-books/` は読み取り専用の OPDS 配信サービスへ転送します。
ホストへ公開するコンテナーポートは `127.0.0.1:3080` だけです。

アカウントはこの Web 版で作成します。メール確認は省略し、SMTP は使いません。
別のブラウザーでも同じ HTTPS URL を開き、同じアカウントにログインして同期します。
公式 Readest クラウドのアカウントやデータは、この環境へ自動で移行しません。

## NAS 本棚から選んで取り込む

本棚の取り込みメニューから Online Library を開き、Readest の公開元 URL に
`/nas-books/?opds` を付けてカタログを登録します。
フォルダーを開いて本を選び、Download を押すと通常のライブラリーへ取り込みます。
Settings → Integrations の Readest Cloud と、Books・Reading progress・Annotations の同期を有効にします。
この構成での接続先はセルフホストの同期用バックエンドです。
ほかの端末は本棚情報を受け取り、本文は開いた本だけダウンロードします。
オフラインで読む本は、接続中に取り込みまたはダウンロードを完了させます。

原本は NAS に残します。取り込み操作をした端末が本文を取得し、同期領域へアップロードします。
カタログを閲覧しただけでは、本文を端末や同期領域へコピーしません。
配信するフォルダーは `hosts/jupiter/readest-library.nix` で指定します。
配信プロセスは NAS 上の書籍フォルダーを読み取り専用で参照し、親共有・ほかの共有・ホームは参照できません。

巨大な本棚を起動時に走査しないよう、copyparty の索引とサムネイル生成を無効にします。
一覧は開いたフォルダーの項目から生成します。全階層検索は提供しません。
OPDS 一覧にはページングがなく、一つのフォルダーに項目が集中すると表示に時間がかかります。
NAS にアクセスできない間も、Readest に保存済みの本は通常どおり利用できます。

配信サービスは systemd のシステムサービスです。

```bash
systemctl status readest-library
journalctl -u readest-library -n 50
```

配信は Unix socket を介して既存の nginx から行います。
NAS 用の TCP ポートや別の HTTPS 公開元は追加しません。
このカタログには Readest のログイン認証を掛けず、専用サービスへ接続できる tailnet 内の端末へ公開します。

## 停止と再起動

```bash
systemctl --user stop readest-serve readest
systemctl --user start readest-serve
systemctl --user restart readest
```

停止時は Compose の `down` でコンテナーとネットワークを除去します。
PostgreSQL と SeaweedFS の named volume、および `.env` は保持します。
停止時は `svc:readest` の広告とプロキシ設定も解除します。
再起動すると同じ Service を再び公開します。

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

ストレージ容量と翻訳枠は、実用上使い切れない大きな上限を Nix モジュールで指定します。
実際の空き容量と外部翻訳サービス側の制限は残ります。
外部翻訳・音声サービスの認証情報やメール受信経路はこの構成に含めません。

上流 CDN の CJK Web フォントは、独自ドメインでは CORS 制限を受けます。
必要ならフォントを別途配信し、`.env` の `FONT_BASE_URL` をその URL にします。
システムフォントと Google Fonts はこの制限の対象外です。
