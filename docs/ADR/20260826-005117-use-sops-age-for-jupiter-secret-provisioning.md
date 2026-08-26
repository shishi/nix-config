# SOPS と 2 種類の age 鍵で Jupiter の秘密を配送する

| | |
|---|---|
| **Status** | accepted |
| **Date** | 2026-08-26 |
| **Decision-makers** | shishi |
| **Consulted** | Codex |
| **Informed** | N/A |

## Context and Problem Statement

Jupiter の初回インストールは、LUKS パスフレーズ、ログインパスワード、
SSH 秘密鍵、GPG 秘密鍵を平文の `secrets/` から配送しています。
`secrets/` は Git 管理外なので、再インストールには別経路で秘密を復元する必要があります。

初回インストール後は、Synology NAS の `//mars/shishi` を
`/mnt/mars/shishi` から利用可能にします。SMB パスワードを public repository や
Nix store へ平文で入れず、Jupiter が無人で復号できる必要があります。

## Decision Drivers

* 暗号化した秘密を public repository で管理できること
* `nixos-anywhere` の初回インストールを再現できること
* Jupiter が起動後に SMB 資格情報だけを無人で復号できること
* Jupiter 用の鍵が漏れても、LUKS パスフレーズへ到達できないこと
* 秘密値をログ、コマンドライン引数、Nix store へ平文で入れないこと
* NAS が停止していても Jupiter の起動を妨げないこと

## Considered Options

1. SOPS と sops-nix を使い、管理用と Jupiter 用の age 鍵を分ける
2. agenix で秘密ごとの age ファイルを管理する
3. age と systemd の復号処理を独自実装する

## Decision Outcome

**Chosen option**: "SOPS と sops-nix を使い、管理用と Jupiter 用の age 鍵を分ける"。
SOPS は初期インストール用の複数の値を構造化して管理できます。
sops-nix は SMB 資格情報を activation 時に `/run/secrets` へ配置できます。

管理用 age 鍵を信頼の起点にします。管理用秘密鍵は earth の
`~/.config/sops/age/keys.txt` に mode `0600` で置き、repository へ入れません。
別途、パスワードマネージャーへバックアップします。

Jupiter 用 age 秘密鍵は、管理用 age 鍵で暗号化して repository に保存します。
初回インストール時に `/var/lib/sops-nix/key.txt` へ配送します。
Jupiter 用鍵は日常運用で必要な SMB 資格情報だけを復号できます。

### Secret Boundaries

| 秘密 | 暗号化先 | Jupiter での状態 |
|---|---|---|
| LUKS パスフレーズ | 管理用 age 鍵 | 保持しない |
| ログイン平文パスワード | 管理用 age 鍵 | yescrypt ハッシュだけ保持 |
| Jupiter 用 age 秘密鍵 | 管理用 age 鍵 | `/var/lib/sops-nix/key.txt` に保持 |
| SSH 秘密鍵 | 管理用 age 鍵 | `~/.ssh` に保持 |
| GPG 秘密鍵 export | 管理用 age 鍵 | import と署名検証後に export を削除 |
| SMB 資格情報 | Jupiter 用 age 鍵 | `/run/secrets` へ復号 |
| 公開鍵と fingerprint | 暗号化しない | 必要な場所に保持 |

管理用鍵は、暗号化された Jupiter 用秘密鍵を経由して全秘密を復旧できます。
この決定の目的は管理者を制限することではありません。
Jupiter から初期インストール専用の秘密へ到達できないようにします。

### Components and Data Flow

`nix run .#init-secrets` は次を実行します。

1. SSH 鍵と GPG 署名鍵を入力前に検査する
2. 管理用 age 鍵がなければ earth に生成する
3. Jupiter 用 age 鍵を生成する
4. LUKS、ログイン、SMB のパスワードを画面へ表示せずに受け取る
5. SSH 秘密鍵を読み、設定済みの GPG 署名鍵を export する
6. tmpfs 上で `secrets/bootstrap.yaml` と `secrets/runtime.yaml` を暗号化する
7. trap で一時平文を削除する

`secrets/bootstrap.yaml` は管理用 age 鍵だけを recipient にします。
LUKS、ログイン、SSH、GPG、Jupiter 用 age 秘密鍵を格納します。
`secrets/runtime.yaml` は Jupiter 用 age 鍵を recipient にし、
SMB 資格情報だけを格納します。
`.sops.yaml` は 2 ファイルの recipient を公開鍵で宣言します。
`.gitignore` は暗号化済み YAML だけを許可し、復号物と一時ファイルを除外します。

`nix run .#nixos-anywhere` のラッパーは、処理開始前に管理用 age 鍵と
SOPS の MAC を検証します。bootstrap 全体を tmpfs 上へ復号・検証し、
disko phase へ配送するのは LUKS パスフレーズだけに限定します。
install phase では次の `extra-files` を tmpfs 上に構成します。

* SSH 秘密鍵と、秘密鍵から導出した公開鍵
* GPG 秘密鍵 export
* ログインパスワードから生成した yescrypt ハッシュ
* Jupiter 用 age 秘密鍵

Jupiter は sops-nix を使い、SMB 資格情報を
`/run/secrets/smb-mars-shishi` に `root:root`、mode `0400` で配置します。
`fileSystems` は `//mars/shishi` を `/mnt/mars/shishi` に割り当てます。
`_netdev` と `x-systemd.automount` を使い、アクセス時に接続します。
NAS が停止していても Jupiter の起動は継続します。

初回起動時の systemd oneshot は、GPG export を shishi の keyring へ import します。
export から fingerprint を取得し、ownertrust を設定します。
実際の clearsign に成功した場合だけ export ファイルを削除します。

### Error Handling

* 初期化済みの暗号化ファイルを `init-secrets` で上書きしない
* 必要な SSH 鍵や GPG 鍵がなければ、パスワード入力前に停止する
* 復号や形式検査が失敗した場合は、disko を開始しない
* 一時ファイルには `umask 077` を適用し、tmpfs だけを使用する
* 通常終了、エラー、通常シグナルで一時ファイルを削除する
* GPG 署名検証が失敗した場合は export を保持し、oneshot を失敗させる
* SMB 接続の失敗はマウント要求だけを失敗させ、boot を失敗させない

`SIGKILL` と earth の電源断では trap を実行できません。
tmpfs の内容は再起動後に残りません。

### Consequences

**Positive:**

* 初回インストールに必要な秘密を暗号化したまま Git で管理できる
* Jupiter は SMB 資格情報を無人で復号できる
* Jupiter 用 age 鍵の漏えいだけでは LUKS パスフレーズを復号できない
* SSH と GPG を含む初回セットアップを自動化できる
* NAS の停止が Jupiter の起動を妨げない

**Negative:**

* 管理用 age 秘密鍵が復旧の信頼の起点になるため、earth とバックアップを保護する必要がある
* 初回利用前に `init-secrets` を実行し、暗号化済み YAML を commit する必要がある
* sops-nix と SOPS が新しい依存になる
* SSH と GPG の秘密鍵は Jupiter 上に保持するため、Jupiter の root 侵害からは保護できない
* SMB パスワード変更後は、既存 CIFS セッションの再接続が必要になる

**Neutral:**

* `/etc/fstab` は直接編集せず、NixOS の `fileSystems` から生成する
* GPG export は配送形式であり、正常な import 後は Jupiter に残さない

### Confirmation

次を自動テストします。

* Jupiter の SOPS 鍵パス、秘密の所有者と mode
* `//mars/shishi`、`/mnt/mars/shishi`、CIFS、automount の設定
* 一時的な age、SSH、GPG 鍵を使った暗号化と配送
* 欠損、誤った鍵、壊れた export、空パスワードの拒否
* エラー後に一時平文と秘密のログ出力が残らないこと
* GPG の import、ownertrust、clearsign、成功時だけの export 削除

対象 check の後に `nix flake check`、Nix 評価結果、生成した fstab、diff を確認します。
新規エージェントが要件、ADR、diff、テストを独立レビューします。

実機の NAS 接続と `nixos-anywhere` による実機インストールは、
開発環境の自動テストでは確認できません。

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
* `docs/jupiter-secure-boot-runbook.md`
