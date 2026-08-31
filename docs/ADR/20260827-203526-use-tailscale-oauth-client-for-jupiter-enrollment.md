# Tailscale OAuth クライアントで Jupiter を無人登録する

| | |
|---|---|
| **状態** | 承認済み |
| **日付** | 2026-08-27 |
| **決定者** | shishi |
| **相談先** | なし |
| **共有先** | なし |

## 背景と課題

Jupiter は Tailscale デーモンを起動しますが、tailnet への登録には対話操作が必要です。
再インストール後も暗号化済みリポジトリから無人登録できる資格情報が必要です。

## 判断基準

* 90 日を超えて再インストールに利用できること
* ブラウザーログインや都度の認証キー発行を不要にすること
* 資格情報を公開リポジトリと Nix ストアへ平文で入れないこと
* Jupiter を永続ノードとして登録すること
* Tailscale SSH を宣言的に有効化すること

## 検討した選択肢

1. `auth_keys` スコープの OAuth クライアントシークレットを SOPS で管理する
2. 再利用可能な認証キーを SOPS で管理する
3. 再インストールごとに 1 回限りの認証キーまたはブラウザーログインを使う

## 決定

**採用:** `auth_keys` スコープの OAuth クライアントシークレットを SOPS で管理します。
通常の認証キーは最長 90 日で失効します。OAuth クライアントシークレットは失効させるまで
新しい登録に利用できるため、再インストール時の対話操作を除去できます。

OAuth クライアントで登録するノードにはタグが必要です。Jupiter は `tag:jupiter` の
永続ノードとして登録します。`authKeyParameters.ephemeral` は `false`、
`preauthorized` は `true` にします。Tailscale SSH は `extraSetFlags` の `--ssh` で
起動時に有効化します。

OAuth クライアントシークレットは `secrets/runtime.yaml` で暗号化します。sops-nix は
`/run/secrets/tailscale-oauth-secret` に `root:root`、パーミッション `0400` で復号します。
秘密情報の登録と更新は既存の処理に集約します。具体的な操作は
[Jupiter の秘密情報手順書](../jupiter-secrets-runbook.md) に記載します。
tailnet の通信ポリシーと SSH ポリシーは Tailscale 管理画面で管理し、この
リポジトリには格納しません。

### 影響

**良い影響:**

* 認証キーの 90 日上限に依存せず Jupiter を再登録できる
* `tailscaled-autoconnect` が未登録状態を検知して tailnet へ参加する
* OAuth クライアントの API 権限を `auth_keys` スコープに限定できる
* 秘密情報の登録時に SOPS と age の内部手順を利用者へ露出しない

**悪い影響:**

* Jupiter の root を侵害した攻撃者は OAuth クライアントシークレットを読み取れる
* OAuth クライアントシークレットの漏えい時は、失効させるまで `tag:jupiter` のノードを登録できる
* 現行の NixOS モジュールは登録時に `authKeyFile` の内容を root サービスの
  `tailscale up --auth-key` 引数へ展開するため、短時間だけプロセスの引数に現れる
* OAuth クライアントと `tag:jupiter` を Tailscale 管理画面で先に作成する必要がある

**中立的な影響:**

* Jupiter は shishi 所有ではなく `tag:jupiter` 所有のノードになる
* タグの通信権限は既存の tailnet ポリシーに従う
* ローカルユーザーは信頼境界内とし、上流モジュールがプロセスの引数へ展開することを許容する

### 確認方法

処理のテストでは `jupiter-secrets` の暗号化更新、既存の秘密情報の保持、入力値をログへ出さないこと、
不正入力時の無変更を検証します。Nix の検査では秘密情報の復号先とパーミッション、OAuth 登録パラメーター、
`tag:jupiter`、Tailscale SSH の設定を検証します。実際のノード登録と SSH 接続は
Tailscale のコントロールプレーンを使うため、OAuth クライアント作成後に実機で確認します。

## 各選択肢の比較

### OAuth クライアントシークレット

* 利点: 失効させるまで新しいノード登録に利用できる
* 利点: スコープとタグで API 権限を限定できる
* 欠点: 漏えい時に繰り返しノードを登録される
* 欠点: OAuth クライアントで登録するノードにはタグが必須

### 再利用可能な認証キー

* 利点: NixOS モジュールの `authKeyFile` へ直接渡せる
* 欠点: 認証キーは最長 90 日で失効する
* 欠点: 期限後の再インストールには新しいキーが必要

### 1 回限りの認証キーまたはブラウザーログイン

* 利点: 長期の登録資格情報を Jupiter に保持しない
* 利点: Jupiter を shishi 所有のノードとして登録できる
* 欠点: 再インストールごとに対話操作が必要

## 参考資料

* [OAuth クライアント](https://tailscale.com/docs/features/oauth-clients)
* [認証キー](https://tailscale.com/docs/features/access-control/auth-keys)
* [SOPS と 2 種類の age 鍵で Jupiter の秘密を配送する](20260826-005117-use-sops-age-for-jupiter-secret-provisioning.md)
* [Jupiter の秘密情報手順書](../jupiter-secrets-runbook.md)
