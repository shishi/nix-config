# バイナリキャッシュの運用

CI は NixOS システムの実行時依存全体をビルドし、上流キャッシュにない成果物だけを Cloudflare R2 に保存します。取得先と署名公開鍵の正本は `shared/nix-caches.nix` です。

## 人間の初期操作

1. Cloudflare で R2 を有効にし、課金設定を完了します。
2. Standard のバケット `nix-config` を作り、Cloudflare 管理下の専用ドメインを接続します。開発用の `r2.dev` は使いません。
3. 対象バケットだけに Object Read & Write 権限を持つ R2 API token を作成します。
4. 準備された Nix 署名秘密鍵を指定して `scripts/configure-r2-cache.py` を devShell から実行します。S3 endpoint と認証情報を入力すると、スクリプトが GitHub Secrets と Variables に登録します。認証情報をチャットや Git に保存しないでください。

初期登録後の CI では手動操作は不要です。GitHub Secrets は `R2_ACCESS_KEY_ID`、`R2_SECRET_ACCESS_KEY`、`NIX_CACHE_SIGNING_KEY`、Variables は `R2_ENDPOINT`、`R2_BUCKET`、`R2_PUBLIC_URL` を使用します。署名秘密鍵は宣言した公開鍵と一致する必要があります。

## 保存と検証

CI は最初に小さな一時オブジェクトを書き込み、公開 HTTPS から読み取り、削除します。署名秘密鍵と宣言した公開鍵の一致も確認します。失敗時はシステム全体のビルドへ進みません。

公開処理は全依存を上流と R2 に照合します。取得エラーを欠落と扱わず、照合が全部成功してから不足分を署名します。圧縮した NAR のアップロード完了後に `.narinfo` を公開します。通常の `nix copy` は参照先も同じ保存先に要求するため、R2 には個別オブジェクトを保存します。

公開後は空の隔離ストアへ全依存を復元し、期待するパス集合との一致、内容と署名を検証します。ローカルビルドとリモートビルダーを禁止して実行します。通常のシステム適用でもキャッシュを使用できるよう、Nix の `always-allow-substitutes` を宣言しています。

## 容量と保持

R2 Standard の無料枠は月 10 GB-month、Class A 操作 100 万回、Class B 操作 1,000 万回です。超過分は従量課金です。保持世代の増加により無料枠を超える場合があります。[料金の正本](https://developers.cloudflare.com/r2/pricing/)を確認してください。

成果物単位の期限切れ削除は設定しません。参照先だけを削除すると、残したシステムも取得できなくなります。保持世代を減らす場合は、残すシステムの全依存を保護したうえで別途整理します。
