# jupiter: NixOS 初期インストール手順書

## 0. 目的と完了条件

未インストールの Jupiter に NixOS を配置し、LUKS で暗号化されたシステムを
初回起動できる状態にする。Secure Boot の鍵と initrd SSH ホスト鍵は
インストール中に作成するが、Secure Boot の有効化と LUKS2 ボリュームへの TPM2 登録は扱わない。

この手順書の完了後は
[Secure Boot／TPM2 手順書](jupiter-secure-boot-runbook.md)へ進む。
秘密情報の作成と更新は
[Jupiter の秘密情報手順書](jupiter-secrets-runbook.md)を使う。

コマンドブロックは Bash 構文で記載する。現在のシェルが fish の場合は、
先に `bash` を起動してから実行する。

## 1. 前提と対象の確認

次の実機情報は 2026-08-22 に確認済みである。

- `hosts/jupiter/hardware-configuration.nix` は実機の
  `nixos-generate-config --show-hardware-config --no-filesystems` の出力そのもの。
  スタブではない
- ディスクは `nvme0n1`(KINGSTON OM8PGP41024Q-A0 / 953.9 GB)1 本。
  `hosts/jupiter/disko.nix` の `device` と一致している。**§2.3 の `disko` フェーズは
  これを実際に消去する。**別のディスクを指していれば取り返しがつかないので、
  機体を変えるときはここだけ確認し直す
- USB イーサは `enp198s0f3u1`、ドライバーは `r8152`。`boot.initrd.availableKernelModules`
  に含まれている
- TPM は `/dev/tpm0`、メジャーバージョン 2。Secure Boot は `disabled`

**USB イーサネットアダプタは挿しっぱなしにする。** 「復旧が要るときに挿す」は
成立しない — 復旧が要るのは TPM 解錠に失敗して遠隔にいるときで、その瞬間に挿す手は
そこに無い。少なくとも、失敗しうる再起動
([Secure Boot／TPM2 手順書 §6](jupiter-secure-boot-runbook.md) が挙げる操作)の
**前**には挿してあること。挿さっていなければ initrd のリンクは
上がらず、復旧手段は物理コンソールだけになる。内蔵は Intel AX210 の無線のみで、
initrd に無線を入れると wpa_supplicant と資格情報を initrd へ持ち込むことになる
ため、そこまではしない。

この手順書は、対象マシンにまだ NixOS がインストールされていない場合だけ使う。

フェーズ分割と対象機上での鍵生成は 2026-08-21 に検証用 VM で通しリハーサルした。
SOPS を使う現行ラッパーはフィクスチャで自動テストしているが、実機への現行
`nixos-anywhere` は未確認である。確認済みの範囲は後段に明記する。

### なぜ素直に流すと失敗するか

`boot.lanzaboote.enable = true;` と
`hostKeys = [ "/var/lib/initrd-ssh/ssh_host_ed25519_key" ];` はどちらも、
対象マシンに既に `/var/lib/sbctl`(sbctl の鍵)と
`/var/lib/initrd-ssh/ssh_host_ed25519_key`(initrd SSH のホストキー)が
存在することを前提にしている。lanzaboote の `lzbt install` は
`--public-key` / `--private-key`(既定値 `/var/lib/sbctl/keys/db/db.{pem,key}`)を
渡され、nixpkgs の `initrd-ssh.nix` は `boot.initrd.secrets` 経由で
`append-initrd-secrets` に `cp -a` させる。新規インストール先にはどちらも
無い。しかも **disko がディスクを消去・暗号化し root ファイルシステムを展開した後**の
ブートローダ設置段で落ちるため、ブート不能な中途半端な状態で止まる。

稼働中の Jupiter に sudo で入って鍵を生成する通常の経路
([Secure Boot／TPM2 手順書 §2.1・§2.2](jupiter-secure-boot-runbook.md))は、
初回インストールでは前提が崩れる。鍵が無いと起動できず、鍵を作るには
そのマシンに到達している必要がある、という循環になるため。

### 採る方法と、採らなかった方法

**`nixos-anywhere` を `--phases` で 2 回に分け、その間に鍵を `/mnt` へ作る。**

- 初期インストール用の秘密は SOPS で暗号化して Git 管理する。
- リポジトリのラッパーは `secrets/bootstrap.yaml` 全体を tmpfs へ復号・検証し、フェーズごとに
  配送する秘密だけを絞る。手動の秘密配送オプションは受け付けない。
- sbctl の鍵と initrd ホスト鍵は対象機上で生成する。Secure Boot の秘密鍵を
  ワークステーションへ経由させず、ディスク上の配置も手作業しない。
- **任意コマンドを実行するフックは無い**(nixos-anywhere 1.13.0)。対象機上で
  処理を挟むにはフェーズを分割するしかない。
- **`boot.lanzaboote.enable` や `hostKeys` を初回だけ外す案は採らない。**
  宣言を成立させられないのは設計が間違っているサインなので、宣言の方を
  そのまま通す。

## 2. インストール手順

### 2.1 暗号化済みの秘密を準備する

[秘密情報手順書](jupiter-secrets-runbook.md) に従い、暗号化済みの
`.sops.yaml`、`secrets/bootstrap.yaml`、`secrets/runtime.yaml` と、
Git 管理対象外の管理用 age 鍵を準備する。3 つの暗号化済みファイルを
同じコミットに含めてから次へ進む。

### 2.2 インストーラーを起動して root に鍵を置く

**USB イーサネットアダプタを挿してから起動する。** この機体に有線 LAN ポートは
無く、`nixos-anywhere` はワークステーションから対象機の sshd へ繋ぐので、対象機が
先に IP を持っている必要がある。アドレスを配るのは **NetworkManager**
(上流 `installation-cd-minimal.nix` の既定。生成された toplevel の
`multi-user.target.wants/` に `NetworkManager.service` があること、`dhcpcd` の
ユニットは無いことを実測)なので、アダプタが挿さっていれば DHCP で付く。
無線しか無い状態だと、コンソールで `nmtui` などを手で叩くまでネットワークに
出られない。

起動したらコンソールで IP を確認する。インストール中に画面を見るのは通常ここ
だけである。途中で再起動してアドレスが変わった疑いが出たら、`install` フェーズの前に
もう一度確認する。インストーラー起動前の Secure Boot 無効化、初回起動での LUKS
パスフレーズ入力、Secure Boot／TPM2 手順書 §2.5・§2.7 のファームウェア操作には
別途コンソールが要る。

```bash
ip -brief addr show
```

以降の `<target>` はこの IP。`<port>` は対象機の sshd のポートで、既定の 22 なら
`--ssh-port` / `-p` は省いてよい(リハーサルでは VM の NAT ポート転送を挟んだ
ため明示した)。

**`root` に自分の公開鍵を置く。実機のコンソールでは打たない。**
`nixos-anywhere` は disko と install の両フェーズで `root@` へ接続するが、素の
`nixos-minimal` ISO には root の `authorized_keys` が無い。インストーラーの `root` と
`nixos` は空パスワードで、空パスワードでの SSH ログインは sshd が拒否するため、
コンソールで `nixos` として `sudo passwd root` を 1 回実行してから、
**ワークステーション側で** `ssh-copy-id` を実行する(いま設定した root の
パスワードを 1 回だけ尋ねられる。以降の `ssh` と `jupiter-install` はすべて
鍵で認証する)。

```bash
ssh-copy-id -p <port> -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@<target>
```

**この 1 行にもホスト鍵のオプションを付ける。** 付けずに実行するとインストーラーの
使い捨てホスト鍵が `known_hosts` に残り、インストール後に同じアドレスへ繋いだ
ときに `REMOTE HOST IDENTIFICATION HAS CHANGED` で拒否される(実測: 付け忘れて
実際にこうなった)。インストール後の機体はインストーラーとは別のホスト鍵を出す。

インストーラーの `nixos` は wheel に属し `security.sudo.wheelNeedsPassword` が false
なので、`sudo` はパスワードを聞かない。実機で打つのは `sudo passwd root` だけになる。

疎通を確認してから先へ進む。

```bash
ssh -p <port> -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@<target> true && echo ok
```

**`StrictHostKeyChecking=no` と `UserKnownHostsFile=/dev/null` は、この手順書で
インストーラーへ繋ぐ `ssh` すべてに付ける**(§2.2〜§2.5 の各コマンドにも書いてある)。
ISO の `/etc/ssh` は tmpfs で **インストーラーのホスト鍵は起動のたびに作り直される**
ため、`known_hosts` に記録するとインストーラーの 2 回目の起動でも、インストール後の
jupiter へ同じアドレスで繋ぐときにも `REMOTE HOST IDENTIFICATION HAS CHANGED`
になる。記録しなければどちらも起きない。`jupiter-install` も同じ 2 つを
`nixos-anywhere` の SSH 接続へ渡す(SSH host key の扱いは wrapper が固定しており、
`--ssh-option` は受け付けない)。

この手順は自宅 LAN を信頼境界に含め、初回の SSH ホスト鍵を別経路では照合しない。
信頼できないネットワーク越しのインストールは、この手順と `jupiter-install` の
対象外である。

**`BatchMode=yes` は疎通確認にだけ付ける。** 鍵が拒否されたときに ssh が
パスワード入力へフォールバックして無言に待ち続けるのを防ぐため(実測: 付けずに
5 分ハングした)。`Permission denied (publickey)` の原因は 2 つ — ISO に鍵が
焼けていない場合と、ワークステーション側の秘密鍵がパスフレーズ付きで
`ssh-agent` に入っていない場合(`BatchMode=yes` はパスフレーズ入力も封じる)。
後者なら `ssh-add -l` に鍵が出ない。

§2.4 は対象機上で `nix run` を使うので、**`nix-command` と `flakes` を
コマンドラインで明示する**(§2.4 のコマンドに入れてある)。素の
`nixos-minimal` ISO ではどちらも有効になっていない(実測: `nix config show` が
`nix-command` 不足で失敗する)。

### 2.3 ディスクを作る(`disko` フェーズ)

ワークステーション側の nix-config チェックアウトで実行する。ラッパーは管理用 age 鍵で
`secrets/bootstrap.yaml` を tmpfs 上へ復号・検証し、disko へ渡すのは LUKS パスフレーズだけである。
値を引数、ログ、Nix ストア、永続ファイルへ出さない。検査に失敗した場合は disko を
開始しない。

```bash
nix run .#jupiter-install -- --target-host root@<target> --ssh-port <port> --phases disko
```

ラッパーは `hosts/jupiter/disko.nix` の `passwordFile = "/tmp/secret.key"` に対応する
引数を内部で追加する。呼び出し側から秘密配送用の引数を追加してはならない。

`### Done! ###` で終わり、`/mnt` に ESP と Btrfs サブボリュームがマウントされた
状態で止まる。確認:

```bash
ssh -p <port> -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@<target> 'findmnt -R /mnt -o TARGET,SOURCE,FSTYPE'
```

期待: `/mnt`(`@root`)・`/mnt/boot`(vfat)・`/mnt/home`・`/mnt/nix`・`/mnt/.swap`。

### 2.4 鍵を `/mnt` に作る

`ssh -p <port> -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@<target>` で入り、
対象機上で実行する。

```bash
rm -rf /var/lib/sbctl
nix --extra-experimental-features "nix-command flakes" run nixpkgs#sbctl -- create-keys
mkdir -p /mnt/var/lib
cp -a /var/lib/sbctl /mnt/var/lib/
mkdir -p /mnt/var/lib/initrd-ssh
ssh-keygen -t ed25519 -N "" -f /mnt/var/lib/initrd-ssh/ssh_host_ed25519_key
chmod 600 /mnt/var/lib/initrd-ssh/ssh_host_ed25519_key
ssh-keygen -lf /mnt/var/lib/initrd-ssh/ssh_host_ed25519_key.pub
```

最初の `rm` は §2.4 をやり直す場合だけ実行する。初回は不要である。

`sbctl create-keys` はインストーラー自身の `/var/lib/sbctl` に書く(出力先は
変えない)。生成されるのは `GUID` と `keys/{PK,KEK,db}/*.{key,pem}`。
`cp -a` で所有者とパーミッションがそのまま `/mnt` 側へ移る。

最後の `ssh-keygen -lf` が出すフィンガープリントは
[Secure Boot／TPM2 手順書 §5.2](jupiter-secure-boot-runbook.md) の照合に使う。
パスワードマネージャーなど、復旧時に Jupiter 以外から読める場所へ保存する。
公開鍵の指紋は秘密ではないが、機体を特定する情報なので公開リポジトリには
入れない。`/var/lib` は暗号化された `/` の上にあり、initrd で止まった状態では
参照できない。

確認:

```bash
find /mnt/var/lib/sbctl /mnt/var/lib/initrd-ssh -printf '%M %u:%g %p\n'
```

期待: sbctl の鍵 6 本が `-r-------- root:root`、
`ssh_host_ed25519_key` が `-rw------- root:root`。

### 2.5 インストール(`install` フェーズ)

**先に §2.3 の `findmnt -R /mnt` をもう一度実行し、`/mnt` と `cryptroot` が
生きていることを確かめる。** §2.3〜§2.5 の間に対象機が再起動・電源断していると
マウントも `cryptroot` も失われる。インストーラーの tmpfs に置いた
`/root/.ssh/authorized_keys` も消える。**そのときは §2.2 のパスワード設定と
root への公開鍵配置からやり直し、§2.3 の `disko` フェーズと §2.4 の鍵生成を
再実行する。**

**`findmnt` が期待どおりのマウントを返さなかったとき(接続エラーを含む)は、
§2.3 を再実行する前に相手を確かめる。** 対象機のコンソールで
`ip -brief addr show` を見て、`<target>` がそのインストーラーの現在のアドレスで
あることを確認する。DHCP でアドレスが移り、旧アドレスを別のホストが取って
いることがある。そのとき `findmnt` は接続エラーではなく「ssh は通るが
マウントが出ない」形になる。**§2.3 は disko = 再フォーマットなので、別の
ホストに対して実行してはならない。**

ワークステーション側で実行する。

```bash
nix run .#jupiter-install -- --target-host root@<target> --ssh-port <port> --phases install
```

`Successfully installed Lanzaboote.` と `installation finished!` が出れば、
初回インストールで鍵が存在しない問題は通過している。

ラッパーは tmpfs 上で `secrets/bootstrap.yaml` を復号し、SSH 鍵、GPG エクスポート、ログイン用
yescrypt ハッシュ、Jupiter 用 age 鍵を構成する。`secrets/runtime.yaml` も Jupiter 用鍵で
復号検証してから、必要な配送引数と `home/shishi` の所有者修正を内部で追加する。
一時平文は成功時と失敗時の両方で削除する。

確認(§2.6 の停止前に):

```bash
ssh -p <port> -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@<target> 'find /mnt/home/shishi/.ssh -maxdepth 1 -printf "%M %U:%G %p\n" | sort; find /mnt/var/lib/secrets /mnt/var/lib/sops-nix -maxdepth 1 -printf "%M %U:%G %p\n" | sort'
```

期待: shishi の `.ssh` と秘密鍵は `1000:100`、Jupiter 用 age 鍵とログイン用
ハッシュは `root:root` である。秘密鍵、age 鍵、GPG エクスポート、ハッシュのパーミッションは
`0600`、SSH 公開鍵は `0644` である。

パーミッションだけでは 0 バイトのファイルを見分けられないので、中身が空でないことも見る
(**値そのものは表示しない**)。

```bash
ssh -p <port> -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@<target> 'test -s /mnt/var/lib/secrets/shishi-password-hash && test -s /mnt/var/lib/sops-nix/key.txt && test -s /mnt/home/shishi/.ssh/id_ed25519 && test -s /mnt/home/shishi/gpg-secret.asc && echo secrets-ok || echo secrets-INCOMPLETE'
```

**この手順が失敗して §2.3 をやり直した場合は、必ず §2.4 も実行し直す。**
`disko` フェーズは再フォーマットするため、`/mnt` 上に作った鍵も消える。

### 2.6 停止してインストーラーメディアを外す

```bash
ssh -p <port> -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@<target> 'swapoff -a; umount -R /mnt && cryptsetup close cryptroot'
```

`umount` と `cryptsetup close` が成功したことを確認してから再起動する。
**`--phases reboot` は使わない**(下の起動項目の始末をする前に再起動すると
インストーラーが再び立ち上がる)。

**`nixos-install` は EFI の起動項目を作らない。** 実機(2026-08-22)の
`efibootmgr` は `BootOrder: 0002,0003` で、0002 は disko が消した Windows の
項目、0003 がインストーラーの USB だった。NixOS の項目は無い。ESP には
フォールバック経路(`EFI/BOOT/BOOTX64.EFI`)が置かれるので、**USB を抜けば**
0002 が失敗してフォールバックでディスクから起動する。

USB を抜かずに済ませるなら、ファームウェア変数に項目を作る。ローダーは
`EFI/systemd/systemd-bootx64.efi`(lanzaboote が署名版に差し替えたもの)。

```
efibootmgr
efibootmgr -c -d /dev/nvme0n1 -p 1 -L 'NixOS Boot Manager' -l '<systemd-boot のパス>'
efibootmgr
```

`-l` に渡すパスは ESP からの相対で、区切りはバックスラッシュ。
新しい `NixOS Boot Manager` が BootOrder の先頭にあることを確認する。
消去済み OS の起動項目は起動に必須ではない。削除する場合は、表示された
ラベルと対象ディスクを照合してから、実際の起動項目 ID を `efibootmgr -b <ID> -B`
へ渡す。過去の実測 ID を再利用しない。

## 3. 初回起動後の確認

初回起動では TPM2 がまだ未登録なので、コンソールで LUKS パスフレーズを
聞かれる。秘密情報手順書で登録した値を使う。

ラッパーの一時平文は終了時の処理が削除する。ワークステーション側に手動で消す平文
ファイルは無い。

**`known_hosts` にインストーラーの鍵が残っていたら消す。** インストール後の機体は
インストーラーとは別のホスト鍵を出すので、素の `ssh` は
`REMOTE HOST IDENTIFICATION HAS CHANGED` で止まる。

```bash
ssh-keygen -R <target>
```

消したあと接続すると新しい鍵の受理を聞かれる。**受理する前に、対象機が出している
指紋と照合する。**

```bash
ssh-keyscan <target> | ssh-keygen -lf -
```

初回起動時に `import-shishi-gpg-secret.service` が GPG エクスポートを自動インポートする。
ユニットは ownertrust を設定して実際のクリア署名を検証し、成功した場合だけエクスポートを
削除する。手動インポートは不要である。失敗時はユニットを失敗状態にしてエクスポートを残す。

```bash
systemctl show import-shishi-gpg-secret.service --property=Result --value
test ! -e ~/gpg-secret.asc
```

期待値は `success` で、GPG エクスポートは存在しない。`failed` の場合は
エクスポートが残るので、ユニットのジャーナルを調べてから再実行する。

ログインパスワードから生成した yescrypt ハッシュを使うのは、shishi の初回作成時だけ
である。`mutableUsers = true` なので、暗号文のログインパスワードを変えても
既存ユーザーには反映しない。インストール後は
[秘密情報手順書 §5.1](jupiter-secrets-runbook.md) に従い、Jupiter 上のパスワードと
暗号文を別々に同じ値へ更新する。

Jupiter は起動時に SMB 資格情報を `/run/secrets/smb-mars-shishi` へ復号する。
`/mnt/mars/shishi` へのアクセスが systemd の自動マウントを起動するため、NAS が停止中でも
Jupiter の起動は継続する。資格情報の内容は表示せず、パーミッションと接続だけを確認する。

```bash
sudo stat -c '%a %U:%G %n' /run/secrets/smb-mars-shishi
ls /mnt/mars/shishi >/dev/null
```

期待するパーミッションと所有者は `400 root:root` である。実 NAS 接続は手動確認であり、
このリポジトリの自動テストでは未確認である。

## 4. Secure Boot／TPM2 手順への引き継ぎ

インストール時に sbctl 鍵と initrd SSH ホスト鍵を作成し、Lanzaboote まで
適用している。この経路では、[Secure Boot／TPM2 手順書](jupiter-secure-boot-runbook.md)
の鍵生成と `nixos-rebuild switch` を繰り返さない。

初回起動時点では Secure Boot は無効で、TPM2 も未登録である。
LUKS パスフレーズで起動した後、Secure Boot／TPM2 手順書の
「セットアップモードに入る」から続ける。既にセットアップモードの場合は、PK を消去せず
鍵の登録へ進む。

## 5. 検証済み範囲と制限

フェーズ分割と対象機上での鍵生成は VirtualBox VM で確認済みである。
SOPS を使うラッパーはフィクスチャで自動テストしている。
現行ラッパーによる実機の `nixos-anywhere` は未確認である。

実機では `<target>` と `<port>` を実際の値へ置き換える。
インストーラー起動前は Secure Boot を無効にする。ファームウェアメニューの操作は
ベンダー依存であり、この手順書では確認していない。
