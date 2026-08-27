# Tailscale OAuth client で Jupiter を無人登録する

| | |
|---|---|
| **Status** | accepted |
| **Date** | 2026-08-27 |
| **Decision-makers** | shishi |
| **Consulted** | N/A |
| **Informed** | N/A |

## Context and Problem Statement

Jupiter は Tailscale daemon を起動しますが、tailnet への登録には対話操作が必要です。
再インストール後も暗号化済み repository から無人登録できる資格情報が必要です。

## Decision Drivers

* 90 日を超えて再インストールに利用できること
* ブラウザーログインや都度の auth key 発行を不要にすること
* 資格情報を public repository と Nix store へ平文で入れないこと
* Jupiter を永続ノードとして登録すること
* Tailscale SSH を宣言的に有効化すること

## Considered Options

1. `auth_keys` scope の OAuth client secret を SOPS で管理する
2. reusable auth key を SOPS で管理する
3. 再インストールごとに one-off auth key またはブラウザーログインを使う

## Decision Outcome

**Chosen option**: "`auth_keys` scope の OAuth client secret を SOPS で管理する"。
通常の auth key は最長 90 日で失効します。OAuth client secret は revoke するまで
新しい登録に利用できるため、再インストール時の対話操作を除去できます。

OAuth client で登録するノードには tag が必要です。Jupiter は `tag:jupiter` の
永続ノードとして登録します。`authKeyParameters.ephemeral` は `false`、
`preauthorized` は `true` にします。Tailscale SSH は `extraSetFlags` の `--ssh` で
起動時に有効化します。

OAuth client secret は `secrets/runtime.yaml` で暗号化します。sops-nix は
`/run/secrets/tailscale-oauth-secret` に `root:root`、mode `0400` で復号します。
secret の登録と更新は既存の secrets workflow に集約します。具体的な操作は
[Jupiter secrets runbook](../jupiter-secrets-runbook.md) に記載します。
tailnet の通信ポリシーと SSH ポリシーは Tailscale 管理画面で管理し、この
repository には格納しません。

### Consequences

**Positive:**

* auth key の 90 日上限に依存せず Jupiter を再登録できる
* `tailscaled-autoconnect` が未登録状態を検知して tailnet へ参加する
* OAuth client の API 権限を `auth_keys` scope に限定できる
* secret の登録時に SOPS と age の内部手順を利用者へ露出しない

**Negative:**

* Jupiter の root を侵害した攻撃者は OAuth client secret を読み取れる
* OAuth client secret の漏えい時は、revoke まで `tag:jupiter` のノードを登録できる
* 現行 NixOS module は登録時に `authKeyFile` の内容を root service の
  `tailscale up --auth-key` 引数へ展開するため、短時間だけ process argv に現れる
* OAuth client と `tag:jupiter` を Tailscale 管理画面で先に作成する必要がある

**Neutral:**

* Jupiter は shishi 所有ではなく `tag:jupiter` 所有のノードになる
* tag の通信権限は既存の tailnet policy に従う
* ローカルユーザーは信頼境界内とし、上流 module の process argv 展開を許容する

### Confirmation

workflow test で `init-secrets` の暗号化更新、既存 secret の保持、入力値をログへ出さないこと、
不正入力時の無変更を検証します。Nix check では secret の復号先と mode、OAuth 登録パラメーター、
`tag:jupiter`、Tailscale SSH の設定を検証します。実際のノード登録と SSH 接続は
Tailscale の control plane を使うため、OAuth client 作成後に実機で確認します。

## Pros and Cons of the Options

### OAuth client secret

* Good, because revoke するまで新しいノード登録に利用できる
* Good, because scope と tag で API 権限を限定できる
* Bad, because 漏えい時に繰り返しノードを登録される
* Bad, because OAuth client で登録するノードには tag が必須

### Reusable auth key

* Good, because NixOS module の `authKeyFile` へ直接渡せる
* Bad, because auth key は最長 90 日で失効する
* Bad, because 期限後の再インストールには新しい key が必要

### One-off auth key またはブラウザーログイン

* Good, because 長期の登録資格情報を Jupiter に保持しない
* Good, because Jupiter を shishi 所有のノードとして登録できる
* Bad, because 再インストールごとに対話操作が必要

## More Information

* [OAuth clients](https://tailscale.com/docs/features/oauth-clients)
* [Auth keys](https://tailscale.com/docs/features/access-control/auth-keys)
* [SOPS と 2 種類の age 鍵で Jupiter の秘密を配送する](20260826-005117-use-sops-age-for-jupiter-secret-provisioning.md)
* [Jupiter secrets runbook](../jupiter-secrets-runbook.md)
