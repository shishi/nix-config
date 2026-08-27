# jupiter: secrets runbook

## 0. 目的と対象

Jupiter の初期インストール用 secret と実行時 secret を、平文を Git、
ログ、Nix store に残さず作成・更新する。操作には `nix run .#init-secrets`
だけを使い、SOPS ファイルをエディターで直接編集しない。

秘密の分離方針は
[SOPS と 2 種類の age 鍵で Jupiter の秘密を配送する](ADR/20260826-005117-use-sops-age-for-jupiter-secret-provisioning.md)
に記録する。

## 1. 鍵と暗号文

- `secrets/management-age-key.txt`
  - 管理用 age 秘密鍵
  - Git 管理対象外、mode `0600`
  - `secrets/bootstrap.yaml` を復号
- `jupiter-age-key`
  - `bootstrap.yaml` 内に暗号化して保管
  - インストール時に `/var/lib/sops-nix/key.txt` へ配置
  - `secrets/runtime.yaml` を復号
- `secrets/bootstrap.yaml`
  - LUKS、ログイン、SSH、GPG、Jupiter 用 age 秘密鍵
- `secrets/runtime.yaml`
  - SMB 資格情報、Tailscale OAuth client secret

管理用 age 鍵はパスワードマネージャーにもバックアップする。
ローカルファイルとバックアップの両方を失うと、bootstrap を復旧できない。
別の鍵を使う場合だけ `SOPS_AGE_KEY_FILE` を指定する。

## 2. 初期作成

前提:

- `~/.ssh/id_ed25519`
- global Git 設定の `user.signingkey` が参照する GPG 署名秘密鍵
- `auth_keys` scope と `tag:jupiter` を持つ、`tskey-client-` で始まる
  Tailscale OAuth client secret（client ID や通常の auth key ではない）
- `.sops.yaml`、`bootstrap.yaml`、`runtime.yaml` がすべて未作成であること

リポジトリのルートで実行する。

```bash
nix run .#init-secrets
```

LUKS、ログイン、SMB のパスワードと Tailscale OAuth client secret を
それぞれ 2 回入力する。app は管理用と Jupiter 用の age 鍵を生成し、
tmpfs 上で暗号化する。入力値と秘密鍵は表示しない。

作成後、暗号文と公開 recipient だけを Git 管理する。

```bash
git add .sops.yaml secrets/bootstrap.yaml secrets/runtime.yaml
```

`secrets/management-age-key.txt` が staged または追跡対象になっていないことを
確認してから commit する。

## 3. 既存値の更新

3 つの暗号化済みファイルと管理用 age 鍵がある状態で実行する。

```bash
nix run .#init-secrets
```

app は次の順で値を確認する。

1. LUKS パスフレーズ
2. ログインパスワード
3. SMB パスワード
4. Tailscale OAuth client secret

空 Enter は既存値を維持する。値を入力した項目だけ確認入力へ進み、
対応する暗号文だけを更新する。SSH、GPG、Jupiter 用 age 鍵は更新しない。
すべて空 Enter の場合は暗号文を変更しない。

3 つの暗号化済みファイルの一部だけが存在する場合や、管理用 age 鍵で
bootstrap を復号できない場合は停止する。既存の暗号文がある状態で
管理用 age 鍵を再生成してはならない。バックアップから同じ鍵を復元する。

## 4. SMB パスワードの変更

「既存値の更新」を実行し、SMB パスワードだけ新しい値を入力する。
ほかの 3 項目は空 Enter で維持する。変更した `runtime.yaml` を commit、push し、
Jupiter 側で checkout を更新して `nh os switch` を実行する。

既存の CIFS セッションを切断し、automount から再接続する。

```bash
sudo systemctl stop mnt-mars-shishi.mount
sudo systemctl restart mnt-mars-shishi.automount
ls /mnt/mars/shishi >/dev/null
```

接続後も資格情報の内容は表示せず、mode と所有者だけ確認する。

```bash
sudo stat -c '%a %U:%G %n' /run/secrets/smb-mars-shishi
```

期待値は `400 root:root` である。実 NAS 接続とパスワード変更後の再接続は
自動テストでは確認しない。

## 5. 失敗時の復旧

入力不一致、途中の EOF、復号失敗、SOPS 更新失敗では既存の暗号文を変更しない。
原因を直し、同じ `nix run .#init-secrets` を再実行する。

暗号化済みファイルの一部だけが存在する場合は、不足ファイルを同じ commit から
復元する。管理用 age 鍵を失った場合は、パスワードマネージャーのバックアップから
`secrets/management-age-key.txt` へ復元し、mode `0600` にする。
既存の暗号文を維持したまま、新しい管理用 age 鍵を生成してはならない。
