# jupiter: 秘密情報の作成・更新手順書

## 0. 目的と対象

Jupiter の初期インストール用と実行時用の秘密情報を、平文を Git、
ログ、Nix ストアに残さず作成・更新する。リポジトリ内の暗号文の作成・更新には
`nix run .#init-secrets` だけを使い、SOPS ファイルをエディターで直接編集しない。

秘密の分離方針は
[SOPS と 2 種類の age 鍵で Jupiter の秘密を配送する](ADR/20260826-005117-use-sops-age-for-jupiter-secret-provisioning.md)
に記録する。

## 1. 鍵と暗号文

- `secrets/management-age-key.txt`
  - 管理用 age 秘密鍵
  - Git 管理対象外、パーミッション `0600`
  - `secrets/bootstrap.yaml` を復号
- `jupiter-age-key`
  - `secrets/bootstrap.yaml` 内に暗号化して保管
  - インストール時に `/var/lib/sops-nix/key.txt` へ配置
  - `secrets/runtime.yaml` を復号
- `secrets/bootstrap.yaml`
  - LUKS、ログイン、SSH、GPG、Jupiter 用 age 秘密鍵
- `secrets/runtime.yaml`
  - SMB 資格情報、Tailscale OAuth クライアントシークレット

管理用 age 鍵はパスワードマネージャーにもバックアップする。
ローカルファイルとバックアップの両方を失うと、`secrets/bootstrap.yaml` を復旧できない。
別の鍵を使う場合だけ `SOPS_AGE_KEY_FILE` を指定する。

SOPS は値を暗号化するが、YAML の項目名、値の型、暗号文の長さは隠さない。
文字列の暗号文にはパディングがないため、平文の UTF-8 バイト数を判別できる。
ASCII だけの値ではバイト数と文字数が一致する。暗号文だけでは値を復元したり、
推測した値が正しいか検証したりできないが、長さを秘密として扱ってはならない。

`init-secrets` は、新しく入力する LUKS パスフレーズとログインパスワードを
15 文字以上 128 文字以下に制限する。既存値を空 Enter で維持する場合は、
現在値が 15 文字未満でも変更しない。入力しやすさと強度は次の方針で両立する。

- ログイン／RDP 用: 7776 語以上の単語リストから均等に無作為選択した 4〜5 語
- LUKS 用: 7776 語以上の単語リストから均等に無作為選択した 6 語
- 2 つの値は分け、起動前でも入力できる英小文字を中心にする

人が考えた文章、固有名詞、既知の引用文は使わない。文字数は入力を拒否する下限であり、
強度そのものを保証しない。

## 2. 初期作成

前提:

- `~/.ssh/id_ed25519`
- グローバル Git 設定の `user.signingkey` が参照する GPG 署名秘密鍵
- `auth_keys` スコープと `tag:jupiter` を持つ、`tskey-client-` で始まる
  Tailscale OAuth クライアントシークレット（クライアント ID や通常の認証キーではない）
- `.sops.yaml`、`secrets/bootstrap.yaml`、`secrets/runtime.yaml` がすべて未作成であること

リポジトリのルートで実行する。

```bash
nix run .#init-secrets
```

LUKS、ログイン、SMB のパスワードと Tailscale OAuth クライアントシークレットを
それぞれ 2 回入力する。アプリは管理用と Jupiter 用の age 鍵を生成し、
tmpfs 上で暗号化する。入力値と秘密鍵は表示しない。

作成後、暗号文と暗号化先の公開鍵だけを Git 管理する。

```bash
git add .sops.yaml secrets/bootstrap.yaml secrets/runtime.yaml
```

`secrets/management-age-key.txt` がステージまたは追跡対象になっていないことを
確認してからコミットする。

## 3. 既存値の更新

3 つの暗号化済みファイルと管理用 age 鍵がある状態で実行する。

```bash
nix run .#init-secrets
```

アプリは次の順で値を確認する。

1. LUKS パスフレーズ
2. ログインパスワード
3. SMB パスワード
4. Tailscale OAuth クライアントシークレット

空 Enter は既存値を維持する。値を入力した項目だけ確認入力へ進み、
対応する暗号文だけを更新する。SSH、GPG、Jupiter 用 age 鍵は更新しない。
すべて空 Enter の場合は暗号文を変更しない。
空 Enter は削除ではない。暗号文内の必須値を空文字にするか項目ごと削除すると、
不正な形式として停止する。

3 つの暗号化済みファイルの一部だけが存在する場合や、管理用 age 鍵で
`secrets/bootstrap.yaml` を復号できない場合は停止する。既存の暗号文がある状態で
管理用 age 鍵を再生成してはならない。バックアップから同じ鍵を復元する。

この操作が更新するのはリポジトリの暗号文だけである。稼働中の Jupiter にある
ログインパスワードと LUKS キースロットは自動では変わらない。どちらかを更新する場合は
§5 で実機と暗号文を同じ値にする。SMB パスワードは §6 の適用と再接続まで実行する。

## 4. 破棄して作り直す

`.sops.yaml`、`secrets/bootstrap.yaml`、`secrets/runtime.yaml` は 1 セットとして扱う。
1 ファイルだけを削除すると `init-secrets` は部分的な状態として拒否する。
やり直す前に、3 ファイルが同じコミットに保存済みで、管理用 age 鍵のバックアップが
あることを確認する。誤って単体で削除した場合も、3 ファイルすべてを同じコミットから
復元し、異なる世代を混在させない。

暗号文だけを作り直し、管理用 age 鍵を維持する場合は、3 ファイルをすべて削除して
`init-secrets` を実行する。

```bash
rm -- .sops.yaml secrets/bootstrap.yaml secrets/runtime.yaml
nix run .#init-secrets
```

LUKS、ログイン、SMB、Tailscale の 4 項目を再入力し、SSH・GPG 鍵を既存ソースから
再取得して、Jupiter 用 age 鍵を新しく生成する。このため、稼働中の Jupiter にある
`/var/lib/sops-nix/key.txt` では新しい `secrets/runtime.yaml` を復号できない。この操作は
再インストールと組み合わせ、新しい Jupiter 用鍵をインストール時に配送する。

管理用 age 鍵も作り直す場合は、暗号文 3 ファイルと管理用鍵をすべて削除してから実行する。
次のコマンドは既定パスを使う場合である。`SOPS_AGE_KEY_FILE` を指定している場合は、
末尾の管理用鍵パスを、指定先の実ファイルへ置き換える。

```bash
rm -- .sops.yaml secrets/bootstrap.yaml secrets/runtime.yaml secrets/management-age-key.txt
nix run .#init-secrets
```

古い管理用鍵のバックアップがなければ、古い `secrets/bootstrap.yaml` は復号できなくなる。
新しい管理用鍵はパスワードマネージャーへ改めてバックアップする。

管理用鍵だけを削除しても再初期化にはならない。既存の暗号文を維持するなら
バックアップから同じ鍵を復元し、作り直すなら暗号文 3 ファイルも一緒に削除する。
個別の秘密情報だけを削除する操作には対応しない。不要になった値は「既存値の更新」で
別の値へ置き換える。

この再作成は、漏えいした資格情報の失効処理ではない。Git 履歴の古い暗号文と古い鍵を
持つ主体は古い値を復号できる。漏えい対応では各秘密情報自体も変更し、Tailscale OAuth
クライアントなどの外部資格情報を提供元で失効させて再発行する。

## 5. 既存 Jupiter のログインパスワードと LUKS パスフレーズの変更

### 5.1 ログインパスワード

`secrets/bootstrap.yaml` のログインパスワードは、初回インストールで shishi を
作成するときだけ使う。稼働中の Jupiter は `mutableUsers = true` なので、暗号文を
更新して `nh os switch` を実行しても既存ユーザーのパスワードを変更しない。

Jupiter でログインパスワードを変更する。

```bash
passwd
```

続いて「既存値の更新」を実行し、ログインパスワードに同じ新しい値を入力する。
ほかの 3 項目は空 Enter で維持する。SSH 接続を残したまま、画面ロックの解除または
RDP 接続で新しい値を確認する。暗号文は次回の再インストールに備えてコミットする。

### 5.2 LUKS パスフレーズ

暗号文を更新する前に、データのバックアップと LUKS ヘッダーのバックアップを用意する。
`<secure-backup-path>` は Jupiter の暗号化ボリューム外にある保護済みの保存先とする。
ヘッダーのバックアップと作成時点で有効なパスフレーズが揃うと、後からその値を
削除してもデータを復号できるため、バックアップ自体も秘密情報として扱う。

```bash
sudo cryptsetup luksHeaderBackup --header-backup-file <secure-backup-path>/jupiter-luks-header.before.img /dev/disk/by-partlabel/disk-main-luks
```

Jupiter の LUKS2 へ新しいパスフレーズを追加する。新しい値は古い値と異なるものにする。
`Keyslots:` セクションを確認し、0〜31 のうち表示されない番号を `<N>` とする。
変更前のパスフレーズ用キースロットと、`Tokens:` にある `systemd-tpm2` の参照先も
記録する。

```bash
sudo cryptsetup luksDump /dev/disk/by-partlabel/disk-main-luks
sudo cryptsetup luksAddKey --verify-passphrase --new-key-slot <N> /dev/disk/by-partlabel/disk-main-luks
```

`luksAddKey` は、既存のパスフレーズまたは利用可能な LUKS2 トークンで
ボリュームキーを取得した後、新しいパスフレーズを 2 回確認する。
TPM2 トークンによる自動解錠を避け、追加したキースロットだけで新しい値を検証する。
この確認はデバイスを新たに開かない。

```bash
sudo cryptsetup open --test-passphrase --disable-external-tokens --key-slot <N> /dev/disk/by-partlabel/disk-main-luks
```

確認後に「既存値の更新」を実行し、LUKS パスフレーズへ同じ新しい値を入力する。
ほかの 3 項目は空 Enter で維持し、暗号文をコミットする。最後に古い値を入力して、
古いキースロットだけを削除する。

```bash
sudo cryptsetup luksRemoveKey /dev/disk/by-partlabel/disk-main-luks
sudo cryptsetup luksDump /dev/disk/by-partlabel/disk-main-luks
sudo cryptsetup luksHeaderBackup --header-backup-file <secure-backup-path>/jupiter-luks-header.after.img /dev/disk/by-partlabel/disk-main-luks
```

`luksRemoveKey` に新しい値を入力してはならない。新しいキースロットの追加と検証、
暗号文の更新がすべて成功するまで古い値を削除しない。パスフレーズ用キースロットの
変更ではボリュームキーと TPM2 トークンを変えないため、TPM2 の再登録は不要である。
最後の `luksDump` では、`Keyslots:` に追加した `<N>` が残り、旧パスフレーズ用の
キースロットが消えたことを確認する。`Tokens:` の `systemd-tpm2` と参照先キースロットも
変更前と同じであることを確認する。
変更後のヘッダーバックアップを確認してから、変更前のバックアップを安全に破棄する。

## 6. SMB パスワードの変更

「既存値の更新」を実行し、SMB パスワードだけ新しい値を入力する。
ほかの 3 項目は空 Enter で維持する。変更した `secrets/runtime.yaml` をコミットしてプッシュし、
Jupiter 側でチェックアウトを更新して `nh os switch` を実行する。

既存の CIFS セッションを切断し、自動マウントから再接続する。

```bash
sudo systemctl stop mnt-mars-shishi.mount
sudo systemctl restart mnt-mars-shishi.automount
ls /mnt/mars/shishi >/dev/null
```

接続後も資格情報の内容は表示せず、パーミッションと所有者だけ確認する。

```bash
sudo stat -c '%a %U:%G %n' /run/secrets/smb-mars-shishi
```

期待値は `400 root:root` である。実 NAS 接続とパスワード変更後の再接続は
自動テストでは確認しない。

## 7. 失敗時の復旧

入力不一致、途中の EOF、復号失敗、SOPS 更新失敗では既存の暗号文を変更しない。
原因を直し、同じ `nix run .#init-secrets` を再実行する。

暗号化済みファイルの一部だけが存在する場合は、3 ファイルすべてを同じコミットから
復元する。管理用 age 鍵を失った場合は、パスワードマネージャーのバックアップから
`SOPS_AGE_KEY_FILE` の指定先へ復元する。未指定なら
`secrets/management-age-key.txt` へ復元し、パーミッション `0600` にする。
既存の暗号文を維持したまま、新しい管理用 age 鍵を生成してはならない。
