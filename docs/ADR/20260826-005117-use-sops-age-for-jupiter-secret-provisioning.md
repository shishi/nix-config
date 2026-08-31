# SOPS と 2 種類の age 鍵で Jupiter の秘密を配送する

| | |
|---|---|
| **状態** | 承認済み |
| **日付** | 2026-08-26 |
| **決定者** | shishi |
| **相談先** | なし |
| **共有先** | なし |

## 背景と課題

導入前の Jupiter 初回インストールは、LUKS パスフレーズ、ログインパスワード、
SSH 秘密鍵、GPG 秘密鍵を平文の `secrets/` から配送していました。
`secrets/` は Git 管理外なので、再インストールには別経路で秘密を復元する必要があります。

初回インストール後は、Synology NAS の `//mars/shishi` を
`/mnt/mars/shishi` から利用可能にします。SMB パスワードと Tailscale OAuth
クライアントシークレットを公開リポジトリや Nix ストアへ平文で入れず、Jupiter が無人で
復号できる必要があります。

## 判断基準

* 暗号化した秘密情報を公開リポジトリで管理できること
* `nixos-anywhere` の初回インストールを再現できること
* Jupiter が起動後に必要な実行時の秘密情報だけを無人で復号できること
* Jupiter 用の鍵が漏れても、LUKS パスフレーズへ到達できないこと
* 秘密値をリポジトリ、ログ、Nix ストアへ平文で入れないこと
* NAS が停止していても Jupiter の起動を妨げないこと

## 検討した選択肢

1. SOPS と sops-nix を使い、管理用と Jupiter 用の age 鍵を分ける
2. agenix で秘密ごとの age ファイルを管理する
3. age と systemd の復号処理を独自実装する

## 決定

**採用:** SOPS と sops-nix を使い、管理用と Jupiter 用の age 鍵を分けます。
SOPS は初期インストール用の複数の値を構造化して管理できます。
sops-nix は実行時の秘密情報をアクティベーション時に `/run/secrets` へ配置できます。

管理用 age 鍵を信頼の起点にします。管理用秘密鍵はチェックアウト内の
`secrets/management-age-key.txt` にパーミッション `0600` で置き、Git 管理しません。
別途、パスワードマネージャーへバックアップします。`SOPS_AGE_KEY_FILE` を指定した
場合は、そのファイルを代わりに使います。

Jupiter 用 age 秘密鍵は、管理用 age 鍵で暗号化してリポジトリに保存します。
初回インストール時に `/var/lib/sops-nix/key.txt` へ配送します。
Jupiter 用鍵は日常運用で必要な SMB 資格情報と Tailscale OAuth
クライアントシークレットだけを復号できます。

### 秘密情報の境界

| 秘密 | 暗号化先 | Jupiter での状態 |
|---|---|---|
| LUKS パスフレーズ | 管理用 age 鍵 | 保持しない |
| ログイン平文パスワード | 管理用 age 鍵 | yescrypt ハッシュだけ保持 |
| Jupiter 用 age 秘密鍵 | 管理用 age 鍵 | `/var/lib/sops-nix/key.txt` に保持 |
| SSH 秘密鍵 | 管理用 age 鍵 | `~/.ssh` に保持 |
| GPG 秘密鍵のエクスポート | 管理用 age 鍵 | インポートと署名検証後にエクスポートを削除 |
| SMB 資格情報 | Jupiter 用 age 鍵 | `/run/secrets` へ復号 |
| Tailscale OAuth クライアントシークレット | Jupiter 用 age 鍵 | `/run/secrets` へ復号 |
| 公開鍵とフィンガープリント | 暗号化しない | 必要な場所に保持 |

管理用鍵は、暗号化された Jupiter 用秘密鍵を経由して全秘密を復旧できます。
この決定の目的は管理者を制限することではありません。
Jupiter から初期インストール専用の秘密へ到達できないようにします。

### 構成

`secrets/bootstrap.yaml` は管理用 age 公開鍵だけを暗号化先にし、
初回インストール専用の秘密と Jupiter 用 age 秘密鍵を格納します。
`secrets/runtime.yaml` は Jupiter 用 age 公開鍵だけを暗号化先にし、
SMB 資格情報と Tailscale OAuth クライアントシークレットを格納します。
`.sops.yaml` には、両ファイルの暗号化に使う公開鍵だけを記録します。

管理用 age 秘密鍵は Jupiter へ配送しません。Jupiter 用 age 秘密鍵だけでは
`secrets/bootstrap.yaml` を復号できないため、Jupiter は LUKS パスフレーズなどの
初回インストール専用の秘密へ到達できません。一方、Jupiter の root はホストへ
配置された SSH 鍵、GPG 鍵、実行時の秘密情報を読み取れるため、これらは
Jupiter の侵害から保護する境界には含めません。

初回インストールでは、`secrets/bootstrap.yaml` から必要な秘密だけを対象フェーズへ配送します。
起動後は sops-nix が Jupiter 用 age 秘密鍵を使い、実行時の秘密情報を
`/run/secrets` に配置します。秘密の作成・更新と初回インストールの具体的な操作は、
[Jupiter の秘密情報手順書](../jupiter-secrets-runbook.md) と
[Jupiter の NixOS 初期インストール手順書](../jupiter-install-runbook.md) に記載します。

### 影響

**良い影響:**

* 初回インストールに必要な秘密を暗号化したまま Git で管理できる
* Jupiter は SMB 資格情報を無人で復号できる
* Jupiter は Tailscale の登録資格情報を無人で復号できる
* Jupiter 用 age 鍵の漏えいだけでは LUKS パスフレーズを復号できない
* SSH と GPG を含む初回セットアップを自動化できる
* NAS の停止が Jupiter の起動を妨げない

**悪い影響:**

* 管理用 age 秘密鍵が復旧の信頼の起点になるため、ローカルファイルとバックアップを保護する必要がある
* 初回利用前に `jupiter-secrets` を実行し、暗号化済み YAML をコミットする必要がある
* sops-nix と SOPS が新しい依存になる
* SSH と GPG の秘密鍵は Jupiter 上に保持するため、Jupiter の root 侵害からは保護できない
* Jupiter の root 侵害時は、Tailscale OAuth クライアントシークレットも漏えいする
* SMB パスワード変更後は、既存 CIFS セッションの再接続が必要になる
* SOPS は YAML の項目名、値の型、暗号文の長さを隠さない。パディングされない
  文字列では、暗号文から平文の UTF-8 バイト数を判別できる

**中立的な影響:**

* `/etc/fstab` は直接編集せず、NixOS の `fileSystems` から生成する
* GPG エクスポートは配送形式であり、正常なインポート後は Jupiter に残さない
* 暗号文の更新と、稼働中の Jupiter にあるログインパスワードまたは LUKS
  キースロットの更新は別の操作になる

### 確認方法

自動テストでは次を確認します。

* 管理用と Jupiter 用の暗号化先、秘密鍵の配置先、所有者、パーミッション
* 暗号化ファイルの構造と、平文が暗号文やログへ混入しないこと
* 初回インストールでのフェーズ別配送、配送用一時ディレクトリの削除、
  異常時に対象ホストを変更しないこと
* SMB 自動マウント、Tailscale 登録、GPG インポートの宣言と失敗時の挙動

実際の NAS 接続、Tailscale 登録、`nixos-anywhere` によるインストールは、
外部システムまたは実機を使って確認します。

## 各選択肢の比較

### SOPS と sops-nix

SOPS の YAML に初期インストール用と実行時用の秘密情報を分けます。
sops-nix が実行時用の秘密情報を NixOS のアクティベーション時に復号します。

* 利点: 複数の秘密情報を構造化して管理できる
* 利点: 秘密情報ごとに所有者、パーミッション、復号先を宣言できる
* 利点: 初期インストーラーが値を個別に抽出できる
* 欠点: SOPS と sops-nix の依存が増える

### agenix

age で暗号化した秘密ファイルを NixOS のアクティベーション時に復号します。

* 利点: age に特化しており構成が単純
* 利点: NixOS と Home Manager の統合がある
* 欠点: 初期インストール用の値ごとにファイルと配送処理が増える
* 欠点: 今回の構造化データの抽出には SOPS より自作処理が増える

### age と systemd の独自実装

age CLI で暗号化し、独自の systemd ユニットで復号します。

* 利点: 外部の NixOS 秘密管理モジュールを追加しない
* 欠点: 原子的な更新、権限、順序、失敗時処理を独自に保守する
* 欠点: sops-nix と同等の安全性をテストで裏付ける負担が大きい

## 参考資料

* [sops-nix](https://github.com/Mic92/sops-nix)
* [SOPS](https://github.com/getsops/sops)
* [SOPS 3.13.3 の AES-GCM 実装](https://github.com/getsops/sops/blob/v3.13.3/aes/cipher.go)
* [cryptsetup 2.8.6 FAQ](https://gitlab.com/cryptsetup/cryptsetup/-/blob/v2.8.6/FAQ.md)
* [cryptsetup 2.8.6 luksAddKey](https://gitlab.com/cryptsetup/cryptsetup/-/blob/v2.8.6/man/cryptsetup-luksAddKey.8.adoc)
* [cryptsetup 2.8.6 open](https://gitlab.com/cryptsetup/cryptsetup/-/blob/v2.8.6/man/cryptsetup-open.8.adoc)
* [cryptsetup 2.8.6 luksRemoveKey](https://gitlab.com/cryptsetup/cryptsetup/-/blob/v2.8.6/man/cryptsetup-luksRemoveKey.8.adoc)
* [agenix](https://github.com/ryantm/agenix)
* [Tailscale OAuth クライアントで Jupiter を無人登録する](20260827-203526-use-tailscale-oauth-client-for-jupiter-enrollment.md)
* [Jupiter の秘密情報手順書](../jupiter-secrets-runbook.md)
* [Jupiter の NixOS 初期インストール手順書](../jupiter-install-runbook.md)
