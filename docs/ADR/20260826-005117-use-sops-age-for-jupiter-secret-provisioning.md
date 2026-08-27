# SOPS と 2 種類の age 鍵で Jupiter の秘密を配送する

| | |
|---|---|
| **Status** | accepted |
| **Date** | 2026-08-26 |
| **Decision-makers** | shishi |
| **Consulted** | N/A |
| **Informed** | N/A |

## Context and Problem Statement

導入前の Jupiter 初回インストールは、LUKS パスフレーズ、ログインパスワード、
SSH 秘密鍵、GPG 秘密鍵を平文の `secrets/` から配送していました。
`secrets/` は Git 管理外なので、再インストールには別経路で秘密を復元する必要があります。

初回インストール後は、Synology NAS の `//mars/shishi` を
`/mnt/mars/shishi` から利用可能にします。SMB パスワードと Tailscale OAuth client
secret を public repository や Nix store へ平文で入れず、Jupiter が無人で
復号できる必要があります。

## Decision Drivers

* 暗号化した秘密を public repository で管理できること
* `nixos-anywhere` の初回インストールを再現できること
* Jupiter が起動後に必要な実行時 secret だけを無人で復号できること
* Jupiter 用の鍵が漏れても、LUKS パスフレーズへ到達できないこと
* 秘密値を repository、ログ、Nix store へ平文で入れないこと
* NAS が停止していても Jupiter の起動を妨げないこと

## Considered Options

1. SOPS と sops-nix を使い、管理用と Jupiter 用の age 鍵を分ける
2. agenix で秘密ごとの age ファイルを管理する
3. age と systemd の復号処理を独自実装する

## Decision Outcome

**Chosen option**: "SOPS と sops-nix を使い、管理用と Jupiter 用の age 鍵を分ける"。
SOPS は初期インストール用の複数の値を構造化して管理できます。
sops-nix は実行時 secret を activation 時に `/run/secrets` へ配置できます。

管理用 age 鍵を信頼の起点にします。管理用秘密鍵は checkout 内の
`secrets/management-age-key.txt` に mode `0600` で置き、Git 管理しません。
別途、パスワードマネージャーへバックアップします。`SOPS_AGE_KEY_FILE` を指定した
場合は、そのファイルを代わりに使います。

Jupiter 用 age 秘密鍵は、管理用 age 鍵で暗号化して repository に保存します。
初回インストール時に `/var/lib/sops-nix/key.txt` へ配送します。
Jupiter 用鍵は日常運用で必要な SMB 資格情報と Tailscale OAuth client secret だけを
復号できます。

### Secret Boundaries

| 秘密 | 暗号化先 | Jupiter での状態 |
|---|---|---|
| LUKS パスフレーズ | 管理用 age 鍵 | 保持しない |
| ログイン平文パスワード | 管理用 age 鍵 | yescrypt ハッシュだけ保持 |
| Jupiter 用 age 秘密鍵 | 管理用 age 鍵 | `/var/lib/sops-nix/key.txt` に保持 |
| SSH 秘密鍵 | 管理用 age 鍵 | `~/.ssh` に保持 |
| GPG 秘密鍵 export | 管理用 age 鍵 | import と署名検証後に export を削除 |
| SMB 資格情報 | Jupiter 用 age 鍵 | `/run/secrets` へ復号 |
| Tailscale OAuth client secret | Jupiter 用 age 鍵 | `/run/secrets` へ復号 |
| 公開鍵と fingerprint | 暗号化しない | 必要な場所に保持 |

管理用鍵は、暗号化された Jupiter 用秘密鍵を経由して全秘密を復旧できます。
この決定の目的は管理者を制限することではありません。
Jupiter から初期インストール専用の秘密へ到達できないようにします。

### Architecture

`secrets/bootstrap.yaml` は管理用 age 公開鍵だけを recipient にし、
初回インストール専用の秘密と Jupiter 用 age 秘密鍵を格納します。
`secrets/runtime.yaml` は Jupiter 用 age 公開鍵だけを recipient にし、
SMB 資格情報と Tailscale OAuth client secret を格納します。
`.sops.yaml` には、両ファイルの暗号化に使う公開鍵だけを記録します。

管理用 age 秘密鍵は Jupiter へ配送しません。Jupiter 用 age 秘密鍵だけでは
`secrets/bootstrap.yaml` を復号できないため、Jupiter は LUKS パスフレーズなどの
初回インストール専用の秘密へ到達できません。一方、Jupiter の root はホストへ
配置された SSH 鍵、GPG 鍵、実行時 secret を読み取れるため、これらは
Jupiter の侵害から保護する境界には含めません。

初回インストールでは、bootstrap から必要な秘密だけを対象フェーズへ配送します。
起動後は sops-nix が Jupiter 用 age 秘密鍵を使い、実行時 secret を
`/run/secrets` に配置します。秘密の作成・更新と初回インストールの具体的な操作は、
[Jupiter secrets runbook](../jupiter-secrets-runbook.md) と
[Jupiter NixOS 初期インストール runbook](../jupiter-install-runbook.md) に記載します。

### Consequences

**Positive:**

* 初回インストールに必要な秘密を暗号化したまま Git で管理できる
* Jupiter は SMB 資格情報を無人で復号できる
* Jupiter は Tailscale の登録資格情報を無人で復号できる
* Jupiter 用 age 鍵の漏えいだけでは LUKS パスフレーズを復号できない
* SSH と GPG を含む初回セットアップを自動化できる
* NAS の停止が Jupiter の起動を妨げない

**Negative:**

* 管理用 age 秘密鍵が復旧の信頼の起点になるため、ローカルファイルとバックアップを保護する必要がある
* 初回利用前に `init-secrets` を実行し、暗号化済み YAML を commit する必要がある
* sops-nix と SOPS が新しい依存になる
* SSH と GPG の秘密鍵は Jupiter 上に保持するため、Jupiter の root 侵害からは保護できない
* Jupiter の root 侵害時は、Tailscale OAuth client secret も漏えいする
* SMB パスワード変更後は、既存 CIFS セッションの再接続が必要になる

**Neutral:**

* `/etc/fstab` は直接編集せず、NixOS の `fileSystems` から生成する
* GPG export は配送形式であり、正常な import 後は Jupiter に残さない

### Confirmation

自動テストでは次を確認します。

* 管理用と Jupiter 用の recipient、秘密鍵の配置先、所有者、mode
* 暗号化ファイルの構造と、平文が暗号文やログへ混入しないこと
* 初回インストールでのフェーズ別配送、配送用一時ディレクトリの削除、
  異常時に対象ホストを変更しないこと
* SMB automount、Tailscale 登録、GPG import の宣言と失敗時の挙動

実際の NAS 接続、Tailscale 登録、`nixos-anywhere` によるインストールは、
外部システムまたは実機を使って確認します。

## Pros and Cons of the Options

### SOPS と sops-nix

SOPS の YAML に初期インストール用と実行時用の秘密を分けます。
sops-nix が実行時用の秘密を NixOS activation で復号します。

* Good, because 複数の秘密を構造化して管理できる
* Good, because 秘密ごとに所有者、mode、復号先を宣言できる
* Good, because 初期インストーラーが値を個別に抽出できる
* Bad, because SOPS と sops-nix の依存が増える

### agenix

age で暗号化した秘密ファイルを NixOS activation で復号します。

* Good, because age に特化しており構成が単純
* Good, because NixOS と Home Manager の統合がある
* Bad, because 初期インストール用の値ごとにファイルと配送処理が増える
* Bad, because 今回の構造化データの抽出には SOPS より自作処理が増える

### age と systemd の独自実装

age CLI で暗号化し、独自の systemd unit で復号します。

* Good, because 外部の NixOS 秘密管理モジュールを追加しない
* Bad, because 原子的な更新、権限、順序、失敗時処理を独自に保守する
* Bad, because sops-nix と同等の安全性をテストで裏付ける負担が大きい

## More Information

* [sops-nix](https://github.com/Mic92/sops-nix)
* [SOPS](https://github.com/getsops/sops)
* [agenix](https://github.com/ryantm/agenix)
* [Tailscale OAuth client で Jupiter を無人登録する](20260827-203526-use-tailscale-oauth-client-for-jupiter-enrollment.md)
* [Jupiter secrets runbook](../jupiter-secrets-runbook.md)
* [Jupiter NixOS 初期インストール runbook](../jupiter-install-runbook.md)
