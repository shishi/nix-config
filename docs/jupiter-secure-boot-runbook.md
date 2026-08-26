# jupiter: Secure Boot + TPM2 自動解錠 runbook

## 0. 前提

対象は実機 `jupiter`(NixOS)で Secure Boot を有効化し、TPM2 で LUKS を自動解錠
できるようにする作業。VirtualBox VM(仮想 TPM 2.0、OVMF、systemd 261)での検証
に基づく。実機固有の手順(firmware メニューの操作、NIC ドライバ名など)で
未確認のものは、その場で「未確認」と明記する。

パス表記は 2 系統ある。`/mnt/c/...` は WSL 側のシェル、`/c/...` は §3.x の
`VBoxManage` を Windows 側のシェルで実行するもの。

現在の到達点: Secure Boot 有効化と PCR7 での TPM2 enroll(フェーズ A)は
VM で成立している。カーネル更新に追従させる `systemd-pcrlock`(フェーズ B)は
§8 の理由により未対応で、`hosts/jupiter/default.nix` に該当の宣言は入っていない。

## 1. 何が宣言済みで、何を手で打つのか

`hosts/jupiter/default.nix` と `hosts/jupiter/disko.nix` に宣言済み。**既に
インストール済みのホストでは**、§3.1・§3.2 の鍵生成を先に済ませたうえで
`nixos-rebuild` を実行すれば反映される。
**初回インストール(まだ NixOS が入っていない実機)にはこの前提は当てはま
らない** — `boot.lanzaboote.enable` と `hostKeys` は `/var/lib/sbctl` /
`/var/lib/initrd-ssh/...` の実在を前提にしており、無いとインストールが
失敗する。詳細は §2 のゲート 4 を参照:

- `boot.loader.systemd-boot.enable = false;` / `boot.lanzaboote.enable = true;`
  (`pkiBundle = "/var/lib/sbctl";`)
- `boot.loader.efi.canTouchEfiVariables = true;`
- `boot.initrd.systemd.enable = true;`(TPM2 自動解錠には systemd initrd が前提)
- `boot.initrd.availableKernelModules`(`e1000` = VM 用 + USB イーサの集合。
  実機に有線ポートが無いため、遠隔復旧は USB アダプタ前提。詳細は §2 のゲート 3。
  `e1000` は VM リハーサル用として残し、消さない)
- `boot.initrd.network.enable = true;` と `boot.initrd.network.ssh`
  (`port = 2222`、`hostKeys` は `/var/lib/initrd-ssh/ssh_host_ed25519_key`
  を指す絶対パス指定。実体(鍵ファイル)は宣言できないので手で生成する
  (§3.2)。`authorizedKeys` は本体ユーザーの鍵を流用)
- `boot.initrd.systemd.network.networks."99-ethernet-default-dhcp"` を
  **自前で宣言している**。`networking.networkmanager.enable = true` が
  `networking.useDHCP` を false にし、それに連動して nixpkgs 由来の
  同名デフォルトが initrd 側から消えるため(実測)。
  **この宣言を消すと、ドライバが入っていてリンクが上がっても IP が来ず、
  §6 の遠隔復旧が死ぬ。** 外形は NIC ドライバ欠落と同じなので切り分けを誤る。
  `flake/checks.nix` の `boot-contract` がこの宣言の存在と中身を固定している。
- `fileSystems."/".options = [ "x-systemd.device-timeout=infinity" ];`
- `hosts/jupiter/disko.nix` の
  `disko.devices.disk.main.content.partitions.luks.content.settings.crypttabExtraOpts`
  `= [ "tpm2-device=auto" ];`(TPM2 自動解錠の取得口。無いと enroll しても
  起動時にパスフレーズを聞かれる)
- `hosts/jupiter/disko.nix` の `passwordFile = "/tmp/secret.key";`
  (インストール時の非対話暗号化。`nixos-anywhere --disk-encryption-keys /tmp/secret.key <src>` とペア。**`settings` の配下に置かないこと** —
  置くと `boot.initrd.luks.devices.cryptroot.keyFile` へ伝播し、
  systemd が LUKS2 ヘッダのトークン探索に到達せず TPM 自動解錠が死ぬ)

宣言できない(このマシン固有の秘密や、firmware/NVRAM の状態そのものに
依存するため)ので手で打つ必要があるもの:

- Secure Boot の鍵の生成(`sbctl create-keys`)。`/var/lib/sbctl` に生成され、
  この public repo にはコミットしない。
- initrd SSH のホストキー生成(`ssh-keygen`。§3.2)。`hostKeys` の絶対パスと
  ファイル名を一字一句一致させる必要がある。
- Setup Mode への出入り(firmware/NVRAM の操作)。
- 鍵の enroll(`sbctl enroll-keys --microsoft`)。
- Secure Boot の有効化そのもの(firmware/NVRAM の操作)。
- LUKS ボリュームの TPM2 enroll(`systemd-cryptenroll`)。
- (§8。現在未対応)`systemd-pcrlock make-policy` と
  `systemd-cryptenroll --tpm2-pcrlock=...`。

## 2. インストール前ゲート

**ゲート 2・3 は実機で確認済み(2026-08-22)。作業は残っていない。**

- `hosts/jupiter/hardware-configuration.nix` は実機の
  `nixos-generate-config --show-hardware-config --no-filesystems` の出力そのもの。
  スタブではない
- ディスクは `nvme0n1`(KINGSTON OM8PGP41024Q-A0 / 953.9 GB)1 本。
  `hosts/jupiter/disko.nix` の `device` と一致している。**手順 2 の disko phase は
  これを実際に消去する。**別のディスクを指していれば取り返しがつかないので、
  機体を変えるときはここだけ確認し直す
- USB イーサは `enp198s0f3u1` / driver `r8152`。`boot.initrd.availableKernelModules`
  に含まれている
- TPM は `/dev/tpm0`、version major 2。Secure Boot は `disabled`

**USB イーサネットアダプタは挿しっぱなしにする。** 「復旧が要るときに挿す」は
成立しない — 復旧が要るのは TPM 解錠に失敗して遠隔にいるときで、その瞬間に挿す手は
そこに無い。少なくとも、失敗しうる再起動(§7 が挙げるブートローダ・Secure Boot
構成を変える操作)の**前**には挿してあること。挿さっていなければ initrd のリンクは
上がらず、復旧手段は物理コンソールだけになる。内蔵は Intel AX210 の無線のみで、
initrd に無線を入れると wpa_supplicant と資格情報を initrd へ持ち込むことになる
ため、そこまではしない。

**ゲート 4(初回インストール専用。対象マシンにまだ NixOS がインストール
されていない場合のみ適用)**

phase 分割と target 上での鍵生成は 2026-08-21 に検証用 VM で通しリハーサルした。
SOPS を使う現行 wrapper は fixture で自動テストしているが、実機への現行
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
無い。しかも **disko がディスクを消去・暗号化し rootfs を展開した後**の
ブートローダ設置段で落ちるため、ブート不能な中途半端な状態で止まる。

稼働中の jupiter に sudo で入って鍵を生成する通常の経路(§3.1・§3.2)は、
初回インストールでは前提が崩れる。鍵が無いと起動できず、鍵を作るには
そのマシンに到達している必要がある、という循環になるため。

### 採る方法と、採らなかった方法

**`nixos-anywhere` を `--phases` で 2 回に分け、その間に鍵を `/mnt` へ作る。**

- 初期インストール用の秘密は SOPS で暗号化して Git 管理する。
- リポジトリの wrapper は phase ごとに必要な秘密だけを tmpfs へ復号する。
  手動の秘密配送オプションは受け付けない。
- sbctl の鍵と initrd host key は target 上で生成する。Secure Boot の秘密鍵を
  ワークステーションへ経由させず、ディスク上の配置も手作業しない。
- **任意コマンドを実行するフックは無い**(nixos-anywhere 1.13.0)。target 上で
  処理を挟むには phase を分割するしかない。
- **`boot.lanzaboote.enable` や `hostKeys` を初回だけ外す案は採らない。**
  宣言を成立させられないのは設計が間違っているサインなので、宣言の方を
  そのまま通す。

### 手順

**手順 0: 暗号化済みの秘密を準備する**

この操作は暗号文を初めて作るときだけ行う。既に `.sops.yaml`、
`secrets/bootstrap.yaml`、`secrets/runtime.yaml` が Git に入っていれば再実行しない。
`init-secrets` は既存の 3 ファイルを上書きしない。

前提は `~/.ssh/id_ed25519` と、global Git 設定の `user.signingkey` が参照する
GPG 署名秘密鍵である。リポジトリのルートで実行し、LUKS、ログイン、SMB の
各パスワードを 2 回ずつ入力する。入力値と秘密鍵は表示しない。

```bash
nix run .#init-secrets
```

初回実行は管理用 age 秘密鍵を `~/.config/sops/age/keys.txt` に mode `0600` で
生成する。この鍵は bootstrap 用秘密と、そこに格納した Jupiter 用 age 秘密鍵の
信頼の起点である。**パスワードマネージャーへバックアップし、リポジトリには
入れない。** earth とバックアップの両方を失うと、暗号文から初期インストール用の
秘密を復旧できない。

次の 3 ファイルは暗号文と公開 recipient だけを含む。3 ファイルを同じ commit に
含める。wrapper は bootstrap と runtime が Git 追跡済みでなければ停止する。

```bash
git add .sops.yaml secrets/bootstrap.yaml secrets/runtime.yaml
git commit -m 'chore(secrets): add encrypted Jupiter inputs'
```

秘密値、age 秘密鍵、復号結果を `git diff` やチャットへ貼らない。

**手順 1: installer を起動して root に鍵を置く**

**USB イーサネットアダプタを挿してから起動する。** この機体に有線 LAN ポートは
無く、`nixos-anywhere` はワークステーションから対象機の sshd へ繋ぐので、対象機が
先に IP を持っている必要がある。アドレスを配るのは **NetworkManager**
(上流 `installation-cd-minimal.nix` の既定。生成された toplevel の
`multi-user.target.wants/` に `NetworkManager.service` があること、`dhcpcd` の
unit は無いことを実測)なので、アダプタが挿さっていれば DHCP で付く。
無線しか無い状態だと、コンソールで `nmtui` などを手で叩くまでネットワークに
出られない。

起動したらコンソールで IP を確認する。インストール中に画面を見るのは通常ここ
だけである。途中で再起動してアドレスが変わった疑いが出たら、install phase の前に
もう一度確認する。installer 起動前の Secure Boot 無効化、初回起動での LUKS
パスフレーズ入力、§3.5 / §3.7 の firmware 操作には
別途コンソールが要る。

```bash
ip -brief addr show
```

以降の `<target>` はこの IP。`<port>` は対象機の sshd のポートで、既定の 22 なら
`--ssh-port` / `-p` は省いてよい(リハーサルでは VM の NAT ポート転送を挟んだ
ため明示した)。

**`root` に公開鍵を置く。実機のコンソールでは打たない。**
`nixos-anywhere` は disko と install の両フェーズで `root@` へ接続するが、素の
`nixos-minimal` ISO には root の `authorized_keys` が無い。installer の `root` と
`nixos` は空パスワードで、空パスワードでの SSH ログインは sshd が拒否するため、
コンソールで `nixos` に `passwd` を 1 回実行してから、**ワークステーション側で**
次を実行する。

```bash
ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null nixos@<target> 'sudo install -d -m700 /root/.ssh; curl -Ls github.com/shishi.keys | sudo tee /root/.ssh/authorized_keys'
```

**この 1 行にも host key のオプションを付ける。** 付けずに実行すると installer の
使い捨て host key が `known_hosts` に残り、インストール後に同じアドレスへ繋いだ
ときに `REMOTE HOST IDENTIFICATION HAS CHANGED` で拒否される(実測: 付け忘れて
実際にこうなった)。インストール後の機体は installer とは別の host key を出す。

installer の `nixos` は wheel に属し `security.sudo.wheelNeedsPassword` が false
なので、`sudo` はパスワードを聞かない。実機で打つのは `passwd` だけになる。

疎通を確認してから先へ進む。

```bash
ssh -p <port> -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@<target> true && echo ok
```

**`StrictHostKeyChecking=no` と `UserKnownHostsFile=/dev/null` は、この手順書で
installer へ繋ぐ `ssh` すべてに付ける**(手順 1〜4 の各コマンドにも書いてある)。
ISO の `/etc/ssh` は tmpfs で **installer の host key は起動のたびに作り直される**
ため(焼き込んであるのは `authorized_keys` であって host key ではない)、
`known_hosts` に記録すると installer の 2 回目の起動でも、インストール後の
jupiter へ同じアドレスで繋ぐときにも `REMOTE HOST IDENTIFICATION HAS CHANGED`
になる。記録しなければどちらも起きない。`nixos-anywhere` も内部で同じ 2 つを
使う。

**`BatchMode=yes` は疎通確認にだけ付ける。** 鍵が拒否されたときに ssh が
パスワード入力へフォールバックして無言に待ち続けるのを防ぐため(実測: 付けずに
5 分ハングした)。`Permission denied (publickey)` の原因は 2 つ — ISO に鍵が
焼けていない場合と、ワークステーション側の秘密鍵が passphrase 付きで
`ssh-agent` に入っていない場合(`BatchMode=yes` は passphrase 入力も封じる)。
後者なら `ssh-add -l` に鍵が出ない。

手順 3 は target 上で `nix run` を使うので、**`nix-command` と `flakes` を
コマンドラインで明示する**(手順 3 のコマンドに入れてある)。素の
`nixos-minimal` ISO ではどちらも有効になっていない(実測: `nix config show` が
`nix-command` 不足で失敗する)。

**手順 2: ディスクを作る(disko phase)**

ワークステーション側の nix-config checkout で実行する。wrapper は管理用 age 鍵で
bootstrap を tmpfs 上へ復号・検証し、disko へ渡すのは LUKS パスフレーズだけである。
値を引数、ログ、Nix store、永続ファイルへ出さない。検査に失敗した場合は disko を
開始しない。

```bash
nix run .#nixos-anywhere -- --flake .#jupiter --target-host root@<target> --ssh-port <port> --phases disko
```

wrapper は `hosts/jupiter/disko.nix` の `passwordFile = "/tmp/secret.key"` に対応する
引数を内部で追加する。呼び出し側から秘密配送用の引数を追加してはならない。

`### Done! ###` で終わり、`/mnt` に ESP と btrfs subvolume がマウントされた
状態で止まる。確認:

```bash
ssh -p <port> -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@<target> 'findmnt -R /mnt -o TARGET,SOURCE,FSTYPE'
```

期待: `/mnt`(`@root`)・`/mnt/boot`(vfat)・`/mnt/home`・`/mnt/nix`・`/mnt/.swap`。

**手順 3: 鍵を `/mnt` に作る**

`ssh -p <port> -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@<target>` で入り、
target 上で実行する。

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

最初の `rm` は手順 3 をやり直す場合だけ実行する。初回は不要である。

`sbctl create-keys` は installer 自身の `/var/lib/sbctl` に書く(出力先は
変えない)。生成されるのは `GUID` と `keys/{PK,KEK,db}/*.{key,pem}`。
`cp -a` で所有者と mode がそのまま `/mnt` 側へ移る。

最後の `ssh-keygen -lf` が出すフィンガープリントは §6.2 の照合に使う。
パスワードマネージャーなど、復旧時に Jupiter 以外から読める場所へ保存する。
公開鍵の指紋は秘密ではないが、機体を特定する情報なので public repository には
入れない。`/var/lib` は暗号化された `/` の上にあり、initrd で止まった状態では
参照できない。

確認:

```bash
find /mnt/var/lib/sbctl /mnt/var/lib/initrd-ssh -printf '%M %u:%g %p\n'
```

期待: sbctl の鍵 6 本が `-r-------- root:root`、
`ssh_host_ed25519_key` が `-rw------- root:root`。

**手順 4: インストール(install phase)**

**先に手順 2 の `findmnt -R /mnt` をもう一度実行し、`/mnt` と `cryptroot` が
生きていることを確かめる。** 手順 2〜4 の間に対象機が再起動・電源断していると
マウントも `cryptroot` も失われる。**そのときは手順 2 の disko phase と
手順 3 の鍵生成を再実行する。**
`authorized_keys` は ISO に焼き込んであるので、手順 1 まで戻る必要は無い。

**`findmnt` が期待どおりのマウントを返さなかったとき(接続エラーを含む)は、
手順 2 を再実行する前に相手を確かめる。** 対象機のコンソールで
`ip -brief addr show` を見て、`<target>` がその installer の現在のアドレスで
あることを確認する。DHCP でアドレスが移り、旧アドレスを別のホストが取って
いることがある。そのとき `findmnt` は接続エラーではなく「ssh は通るが
マウントが出ない」形になる。**手順 2 は disko = 再フォーマットなので、別の
ホストに対して実行してはならない。**

ワークステーション側で実行する。

```bash
nix run .#nixos-anywhere -- --flake .#jupiter --target-host root@<target> --ssh-port <port> --phases install
```

`Successfully installed Lanzaboote.` と `installation finished!` が出れば、
ゲート 4 が問題にしていた失敗点は通過している。

wrapper は tmpfs 上で bootstrap を復号し、SSH 鍵、GPG export、ログイン用
yescrypt ハッシュ、Jupiter 用 age 鍵を構成する。runtime も Jupiter 用鍵で
復号検証してから、必要な配送引数と `home/shishi` の所有者修正を内部で追加する。
一時平文は成功時と失敗時の両方で削除する。

確認(手順 5 の停止前に):

```bash
ssh -p <port> -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@<target> 'find /mnt/home/shishi/.ssh -maxdepth 1 -printf "%M %U:%G %p\n" | sort; find /mnt/var/lib/secrets /mnt/var/lib/sops-nix -maxdepth 1 -printf "%M %U:%G %p\n" | sort'
```

期待: shishi の `.ssh` と秘密鍵は `1000:100`、Jupiter 用 age 鍵とログイン用
ハッシュは `root:root` である。秘密鍵、age 鍵、GPG export、ハッシュの mode は
`0600`、SSH 公開鍵は `0644` である。

mode だけでは 0 バイトのファイルを見分けられないので、中身が空でないことも見る
(**値そのものは表示しない**)。

```bash
ssh -p <port> -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@<target> 'test -s /mnt/var/lib/secrets/shishi-password-hash && test -s /mnt/var/lib/sops-nix/key.txt && test -s /mnt/home/shishi/.ssh/id_ed25519 && test -s /mnt/home/shishi/gpg-secret.asc && echo secrets-ok || echo secrets-INCOMPLETE'
```

**この手順が失敗して手順 2 をやり直した場合は、必ず手順 3 も実行し直す。**
disko phase は再フォーマットするため、`/mnt` 上に作った鍵も消える。

**手順 5: 停止して installer メディアを外す**

```bash
ssh -p <port> -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@<target> 'swapoff -a; umount -R /mnt && cryptsetup close cryptroot'
```

`umount` と `cryptsetup close` が成功したことを確認してから再起動する。
**`--phases reboot` は使わない**(下の boot 項目の始末をする前に再起動すると
installer が再び立ち上がる)。

**`nixos-install` は EFI の boot 項目を作らない。** 実機(2026-08-22)の
`efibootmgr` は `BootOrder: 0002,0003` で、0002 は disko が消した Windows の
項目、0003 が installer の USB だった。NixOS の項目は無い。ESP には
フォールバック経路(`EFI/BOOT/BOOTX64.EFI`)が置かれるので、**USB を抜けば**
0002 が失敗してフォールバックでディスクから起動する。

USB を抜かずに済ませるなら、firmware 変数に項目を作る。ローダは
`EFI/systemd/systemd-bootx64.efi`(lanzaboote が署名版に差し替えたもの)。

```
efibootmgr -c -d /dev/nvme0n1 -p 1 -L 'NixOS Boot Manager' -l '<systemd-boot のパス>'
efibootmgr -b 0002 -B     # 消えた Windows の項目を消す
efibootmgr                # BootOrder の先頭が新しい項目であることを確認
```

`-l` に渡すパスは ESP からの相対で、区切りはバックスラッシュ。

初回起動では TPM2 がまだ未 enroll なので、コンソールで LUKS パスフレーズを
聞かれる。`init-secrets` で入力した値を使う。

wrapper の一時平文は trap が削除する。ワークステーション側に手動で消す平文
ファイルは無い。

**`known_hosts` に installer の鍵が残っていたら消す。** インストール後の機体は
installer とは別の host key を出すので、素の `ssh` は
`REMOTE HOST IDENTIFICATION HAS CHANGED` で止まる。

```bash
ssh-keygen -R <target>
```

消したあと接続すると新しい鍵の受理を聞かれる。**受理する前に、対象機が出している
指紋と照合する。**

```bash
ssh-keyscan <target> | ssh-keygen -lf -
```

初回起動時に `import-shishi-gpg-secret.service` が GPG export を自動 import する。
unit は ownertrust を設定して実際の clearsign を検証し、成功した場合だけ export を
削除する。手動 import は不要である。失敗時は unit を失敗状態にして export を残す。

```bash
systemctl show import-shishi-gpg-secret.service --property=Result --value
test ! -e ~/gpg-secret.asc
```

期待値は `success` で、GPG export は存在しない。`failed` の場合は export が残るので、
unit の journal を調べてから再実行する。

ログインパスワードから生成した yescrypt ハッシュを使うのは、shishi の初回作成時だけ
である。`mutableUsers = true` なので、インストール後の変更は Jupiter 上で `passwd` を
実行する。暗号文のログインパスワードを変えても、既存ユーザーには反映しない。

Jupiter は起動時に SMB 資格情報を `/run/secrets/smb-mars-shishi` へ復号する。
`/mnt/mars/shishi` へのアクセスが systemd automount を起動するため、NAS が停止中でも
Jupiter の boot は継続する。資格情報の内容は表示せず、mode と接続だけを確認する。

```bash
sudo stat -c '%a %U:%G %n' /run/secrets/smb-mars-shishi
ls /mnt/mars/shishi >/dev/null
```

期待する mode と所有者は `400 root:root` である。実 NAS 接続は手動確認であり、
このリポジトリの自動テストでは未確認である。

### SMB パスワードの変更

`secrets/runtime.yaml` は既存の Jupiter 用 age 鍵を維持したまま更新する。
作業用ディレクトリと SOPS のエディター一時ファイルは `/dev/shm` に限定する。
次はワークステーション側の nix-config checkout で、`sops` と `jq` が使える
devShell から実行する。

```bash
set -o pipefail
umask 077
rotation_tmp=$(mktemp -d /dev/shm/jupiter-smb-rotation.XXXXXXXX) && chmod 700 "$rotation_tmp" && trap 'rm -rf -- "$rotation_tmp"' EXIT HUP INT TERM
SOPS_AGE_KEY_FILE="$HOME/.config/sops/age/keys.txt" sops --decrypt --output-type json secrets/bootstrap.yaml | jq -jer '."jupiter-age-key"' > "$rotation_tmp/jupiter-age-key.txt"
chmod 600 "$rotation_tmp/jupiter-age-key.txt"
TMPDIR="$rotation_tmp" SOPS_AGE_KEY_FILE="$rotation_tmp/jupiter-age-key.txt" sops secrets/runtime.yaml
git add secrets/runtime.yaml && git commit -m 'chore(secrets): rotate SMB credentials'
rm -rf -- "$rotation_tmp" && trap - EXIT HUP INT TERM
```

エディターでは `smb-mars-shishi` の値を `username=shishi` と
`password=<新しい値>` の 2 行で維持する。変更を push し、Jupiter 側で checkout を
更新して `nh os switch` を実行する。その後、既存 CIFS セッションを切断して
automount から再接続する。

```bash
sudo systemctl stop mnt-mars-shishi.mount
sudo systemctl restart mnt-mars-shishi.automount
ls /mnt/mars/shishi >/dev/null
```

実 NAS への接続とパスワード変更後の再接続は、自動テストでは未確認である。

### この後どこへ進むか

**§3.1(`sbctl create-keys`)と §3.2(`ssh-keygen`)は実行しない。**
鍵は手順 3 で既に作られている。**§3.3(`nixos-rebuild switch`)も不要**で、
lanzaboote は `nixos-install` の時点で既に適用されている。

**次は §3.5 だが、無条件に実行しないこと。** まず §3.5 末尾の
`sbctl status` で Setup Mode を確認する。`Setup Mode: Enabled` なら §3.5 の
NVRAM 操作(VM の `modifynvram <vm> inituefivarstore` / 実機の firmware メニューでの
PK クリア)は**行わず** §3.6 へ進む。`Disabled` のときだけ §3.5 の操作を行う。
`inituefivarstore` は UEFI 変数ストアを初期化するので、既に enroll 済みの
PK / KEK / db もまとめて消える。不要に実行すると §3.6 からやり直しになる。

§3.4 以降の VM 用コマンドには、前ラウンドの検証用 VM 名 `jupiter-anywhere-test`
がそのまま書かれている。**自分の VM 名へ読み替えること。** 別の VM を対象に
`modifynvram` を打っても、その VM が VirtualBox に登録されたまま残っていれば
エラーにならず黙って成功し、手元の VM の状態は変わらないまま先へ進んでしまう。

### リハーサルで確認した終状態

新規作成した検証用 VM で phase 分割と鍵の先置きを実行し、続けて §3.6 → §3.7 →
§4.1〜§4.4 → §5.1 を通した結果(**§4.5 の wipe → 再 enroll は通していない**。
§4.5 自身の未確認注記はそのまま残る):

- `bootctl status` が §3.7 の「期待:」ブロックと一致
- LUKS token JSON が §4.4 の「期待(該当部分)」と一致
- 稼働中の `/var/lib/initrd-ssh/ssh_host_ed25519_key.pub` のフィンガープリントが、
  target の `/mnt` に作った鍵のものと一致
- ハードリセット後、キー入力ゼロで自動解錠(§5.1)

**§3.5(Setup Mode に入る)は初回のリハーサルでは通していない。** VM が新規作成で
NVRAM が空だったため、初回起動の時点で既に `Setup Mode: Enabled` だった。
`inituefivarstore` の方は、鍵の先置きを実測する再インストールの前段で実行して
確認している(§3.5)。

つまり、**インストール時に署名に使った鍵と、後から UEFI へ enroll する鍵が
同一である**ことまで確認できている。ここがゲート 4 の要点で、鍵を作り直すと
`nixos-install` が作った最初の世代(NixOS の generation 1)の UKI が
検証できなくなる。

SOPS を使う現行 wrapper の fixture テストは自動化している。一方、現行 wrapper での
実機 `nixos-anywhere` は未確認である。この runbook を使う実インストールは手動確認に
なる。

### 実機で違うところ

- **手順 1 の直後、手順 2 に入る前に、ゲート 2 と ゲート 3 を済ませる。**
  ゲート 2 の `nixos-generate-config` は手順 1 の SSH 経路で実行できるはず
  (**実機で未確認**。リハーサルではスタブのまま通した)。
- **§3.5 の PK クリアは、実機では実際に必要になることが多い。** 判定基準は
  VM と同じく「この後どこへ進むか」に書いた `sbctl status` の結果であって、
  実機かどうかではない。リハーサル VM が初回起動時点で
  `Setup Mode: Enabled` だったのは新規 NVRAM の性質で、PK が enroll 済みの
  実機は通常 `Disabled` を返す。そのとき firmware のメニューで PK をクリアする
  (**メニュー操作はベンダー依存で未確認**)。
- **`<target>` と `<port>`** は実機の値にする。
- **インストール前に firmware で Secure Boot を無効にする。** NixOS の installer ISO は
  Microsoft の鍵でも自前の db 鍵でも署名されていないため、Secure Boot が有効なままだと
  起動せず、既存のディスクへフォールバックする(VM で実測)。有効化は §3.7 で
  自分の鍵を enroll した後に行う。

## 3. フェーズ A: 鍵の生成 → Secure Boot 有効化 → TPM2 enroll

**ゲート 4(§2)の手順で初回インストールした場合、§3.1・§3.2・§3.3 は
実行しない。** §3.5 は条件付きで、既に Setup Mode に入っていれば飛ばす
(条件はゲート 4 の「この後どこへ進むか」に書いた)。 鍵は既に存在し、lanzaboote も
`nixos-install` の時点で適用済みである。この状態で §3.1 を実行すると
`sbctl create-keys` が既存鍵に対してどう振る舞うかは未確認であり、§3.2 の
`ssh-keygen -f` は既存ファイルに対して `Overwrite (y/n)?` と対話で聞いて
くる(この runbook の他の手順は非対話実行を前提にしている)。§6.2 の照合に
使うフィンガープリントは、ゲート 4 の手順 3 で控えたものを使う。

以下の §3.1〜§3.3 は、**既に NixOS が動いているマシンに後から lanzaboote を
導入する場合**の手順である。

### 3.1 鍵の生成

`sbctl` は PATH に無いので `nix run` で呼ぶ。

```
sudo nix run nixpkgs#sbctl -- create-keys
sudo nix run nixpkgs#sbctl -- status
```

`/var/lib/sbctl/keys/{PK,KEK,db}/*.{key,pem}` が生成され、`status` は
`Setup Mode: Disabled`(まだ Setup Mode ではない)と出る。

### 3.2 initrd SSH host key の生成

`hosts/jupiter/default.nix` の `boot.initrd.network.ssh.hostKeys` が参照する
鍵は、宣言だけでは生成されない。生成しないと `nixos-rebuild switch`
(nixpkgs の `initrd-ssh.nix` が `boot.initrd.secrets` 経由で
`append-initrd-secrets` に `cp -a` させる)がソース不在で非 0 終了し、
rebuild 全体が失敗する。

```
sudo mkdir -p /var/lib/initrd-ssh
sudo ssh-keygen -t ed25519 -N "" -f /var/lib/initrd-ssh/ssh_host_ed25519_key
sudo chmod 600 /var/lib/initrd-ssh/ssh_host_ed25519_key
```

ファイル名は `hostKeys` の宣言(絶対パス)と一字一句一致させること。ずれて
いると同じ非 0 終了で rebuild が失敗する。

後で §6.2 の照合に使うため、公開鍵のフィンガープリントをここで控えておく。
(`/var/lib` は暗号化された `/` の上にあり、initrd で足止めされている状況
では未マウントのため、そのときに取りに行くことはできない。)

```
ssh-keygen -lf /var/lib/initrd-ssh/ssh_host_ed25519_key.pub
```

### 3.3 `nixos-rebuild switch` で lanzaboote を適用する

```
sudo nixos-rebuild switch --flake <flake-path>#jupiter
```

確認:

```
sudo nix run nixpkgs#sbctl -- verify
```

`/boot/EFI/Linux/*.efi`(lanzaboote が作る UKI。実際に起動に使われるもの)は
signed になる。`/boot/EFI/nixos/kernel-*.efi`(lanzaboote の署名対象外の
旧来イメージ)が unsigned のまま残るのは正常。

### 3.4 headless VM でパスフレーズを入力する方法(VM リハーサル専用の付録)

**この節は VM リハーサル専用の手順。実機ではコンソールから直接パスフレーズ
を打てばよく、この節のスキャンコード操作は使わない。** 別のパスフレーズを
使う場合にスキャンコード列をどう組むかはここには書かない(実際に組んで
動作を確かめていないため)。組む必要が生じたら、実際に動かして確認した
上で書き足すこと。

以降の節(§3.5, §5.1 など)で `startvm --type headless` で起動した VM に
LUKS パスフレーズを入力する必要が複数回出てくる。ヘッドレスなので通常の
コンソール入力はできず、`VBoxManage controlvm <vm> keyboardputscancode` で
スキャンコード列を直接送る。

```
VBoxManage controlvm jupiter-anywhere-test keyboardputscancode <hex...>
```

スキャンコードは PS/2 keyboard scan code set 1 で、1 キーにつき「押す
(make code)」と「離す(break code。make code に `0x80` を加えた値)」の
2 バイトを送る。実測で使ったパスフレーズ `rehearsal` + Enter に対応する列
(r e h e a r s a l + Enter とデコードして確認済み、動作確認済み):

```
13 93 12 92 23 a3 12 92 1e 9e 13 93 1f 9f 1e 9e 26 a6 1c 9c
```

### 3.5 Setup Mode に入る

**ここだけ VM と実機で手順が違う。**

VM では `modifynvram <vm> inituefivarstore` を使う。UEFI 変数ストアを初期化する
操作で、実行後に `sbctl status` が `Setup Mode: Enabled` を返すことを確認した。
**enroll 済みの PK / KEK / db もこれで消える。**

副次的に、既にインストール済みの VM で実行した直後は installer の ISO から
起動した(それ以前は ISO を入れても既存ディスクへフォールバックしていた)。
**EFI のブートエントリが消えたことが理由かどうかは未確認。** ISO から起動させたい
だけなら `modifyvm <vm> --boot1 dvd` を先に試すこと。

`modifynvram <vm> enrollorclpk` は使わない。コマンド名は「Oracle の PK を
enroll する」と読め、字面からは Setup Mode を**抜ける**操作に見える。
**実行して確かめていない。**

VM:

```
VB="/c/Program Files/Oracle/VirtualBox/VBoxManage.exe"
"$VB" controlvm jupiter-anywhere-test acpipowerbutton
# showvminfo --machinereadable の VMState="poweroff" を確認してから次へ
"$VB" modifynvram jupiter-anywhere-test inituefivarstore
"$VB" startvm jupiter-anywhere-test --type headless
```

起動後、§3.4 の方法で LUKS のパスフレーズを入力してログインできる状態に
する。

実機: firmware(UEFI)のセットアップメニューから Secure Boot の設定に入り、
既存の PK をクリアして Setup Mode に切り替える。**具体的なメニュー操作は
firmware ベンダー依存であり未確認。**

確認(共通):

```
sudo nix run nixpkgs#sbctl -- status
```

`Setup Mode: Enabled` を確認してから次に進む。`sbctl` の `✗`/`✓` 記号は
見た目が反転して見えることがあるので、記号ではなく後続の文字列
(`Enabled`/`Disabled`)を読むこと。**想定と違ったら、先に進まずに止まる
こと。**

### 3.6 鍵を enroll する

```
sudo nix run nixpkgs#sbctl -- enroll-keys --microsoft
```

`--microsoft` は省略できない。省略すると Microsoft の option ROM 検証鍵が
入らず、環境によっては起動しなくなる。

確認は **`sbctl status` の `Setup Mode` を当てにしない。** 実機(2026-08-22)では
`enroll-keys` が成功して `Vendor Keys: microsoft` になった後も、`Setup Mode` は
`Enabled` のままだった。EFI 変数を直接見ると PK は書けている。

```bash
for v in PK KEK db; do f=$(ls /sys/firmware/efi/efivars/${v}-* 2>/dev/null | head -1); echo "$v: $(stat -c%s "$f" 2>/dev/null || echo 変数なし) bytes"; done
```

期待: PK / KEK / db がいずれも数百バイト以上で存在すること(実機の実測値は
PK 1258 / KEK 4332 / db 8895)。**`SetupMode` が 1 のままでも、PK が非空なら
§3.7 へ進んでよい。** この firmware は Secure Boot を有効化する時点で
Setup Mode を降ろす。

`shishi` のログインシェルは fish なので、上のような変数代入を含むブロックを
`ssh <target> '...'` に直接渡すと fish が解釈して失敗する。
`ssh <target> 'bash -s' < script` の形で渡す。

### 3.7 Secure Boot を有効化する

**enroll してから有効化する。** 有効化すると PCR 7(secure-boot-policy)の値が
変わるため、§4 の TPM2 enroll は必ずこの後に行う。

VM:

```
VB="/c/Program Files/Oracle/VirtualBox/VBoxManage.exe"
"$VB" controlvm jupiter-anywhere-test acpipowerbutton
# poweroff を確認してから
"$VB" modifynvram jupiter-anywhere-test listvars
"$VB" modifynvram jupiter-anywhere-test queryvar --name=PK
# PK エントリが空でないことを確認してから有効化する
"$VB" modifynvram jupiter-anywhere-test secureboot --enable
"$VB" startvm jupiter-anywhere-test --type headless
```

ホスト側 NVRAM ストアへの反映には遅延があるため、`enroll-keys` の直後に
間を置かず `secureboot --enable` を呼ぶと
`Secure boot is not available because the platform key (PK) is not enrolled`
で失敗することがある。`listvars`/`queryvar --name=PK` で PK の実在を確認
してから有効化すること。`modifynvram <vm> secureboot` は引数無しでは使えず、
`--enable`/`--disable` の指定が必須(クエリ用途には使えない)。

実機: firmware 設定で Secure Boot を有効に切り替える(**未確認**、firmware 依存)。

LUKS のパスフレーズを入力して起動後、確認:

```
bootctl status
```

期待:

```
   Secure Boot: enabled (user)
  TPM2 Support: yes
  Measured UKI: yes
   Measured OS: yes
```

## 4. TPM2 で LUKS を enroll する(PCR 7)

### 4.1 `--tpm2-pcrs=7` を省略できない理由

systemd 258 で `systemd-cryptenroll` の既定 PCR 集合が「PCR なし」に変わった
(jupiter の systemd は 261)。**省略すると、何にも縛られない TPM2 鍵がその
まま追加される。** 解錠は成功し続けるので、Secure Boot の状態やブート
ローダの改変に対して何も検証していないことに誰も気づかない。必ず
`--tpm2-pcrs=7` を明示する。

### 4.2 実行順序

§3.7 のとおり Secure Boot の有効化で PCR 7 の値が変わる。enroll を先に
行うと、その後の有効化で enroll した内容が無効(解錠できない)ポリシーに
なる。**Secure Boot 有効化 → enroll の順を守る。**

### 4.3 enroll の実行方法

LUKS2 は新規 keyslot の追加時にも既存の資格情報での認証を要求するため、
非対話 SSH で標準入力の無いまま実行すると、既存パスフレーズの入力待ちで
無期限にハングする。`--unlock-key-file=/dev/stdin` で現在のパスフレーズを
渡す。

管理用 age 鍵で `secrets/bootstrap.yaml` を復号し、`jq` が抽出した LUKS 値だけを
標準入力で送る。コマンドライン、画面、永続ファイルには出さない。
ワークステーション側の nix-config checkout で、`sops` と `jq` が使える
devShell から実行する。

```bash
set -o pipefail
SOPS_AGE_KEY_FILE="$HOME/.config/sops/age/keys.txt" sops --decrypt --output-type json secrets/bootstrap.yaml | jq -jer '."luks-passphrase"' | ssh <target> 'sudo systemd-cryptenroll --unlock-key-file=/dev/stdin --tpm2-device=auto --tpm2-pcrs=7 /dev/disk/by-partlabel/disk-main-luks'
```

`sudo` は NOPASSWD(`nixos/sudo.nix`)なので標準入力を奪わない。奪う設定に
変えると、パスフレーズが sudo に食われて enroll が既存鍵の入力待ちでハングする。

（`disk-main-luks` は `hosts/jupiter/disko.nix` の `disko.devices.disk.main` と
パーティション `luks` から disko の命名規則で決まる partlabel で、実機でも
同名になる。）

期待: `New TPM2 token enrolled as key slot 1.`

### 4.4 封印の検証

`cryptsetup luksDump` は `cryptsetup 2.8.6` では `Keyslot: N` の 1 行しか
出さず、`tpm2-pcrs` 等の詳細を表示しない。生の token JSON を見る。

まず `luksDump` でトークン一覧を確認し、`systemd-tpm2` token の ID を確定
する(§4.5 の wipe → 再 enroll を経るとトークン番号がずれることがあるため、
`0` を決め打ちしない)。

```
sudo cryptsetup luksDump /dev/disk/by-partlabel/disk-main-luks
```

`Tokens:` セクションに出ている ID(以下 `<N>`)を使って、生の token JSON を
見る。

```
sudo cryptsetup token export --token-id=<N> /dev/disk/by-partlabel/disk-main-luks
```

期待(該当部分): `"tpm2-pcrs":[7]` と `"tpm2-pcr-bank":"sha256"`。

**`tpm2-primary-alg` は見ない。** VM では `"ecc"`、実機(Minisforum V3 / 2026-08-22)
では `"rsa"` になった。`systemd-cryptenroll` が TPM の対応に合わせて選ぶ値で、
封印が PCR 7 に縛られているかとは無関係。ここを期待値に含めると、正しく enroll
できているのに失敗と判断して §4.5 の wipe → 再 enroll をやり直すことになる。

### 4.5 wipe と enroll は別コマンドに分ける

既存の TPM2 keyslot を同じ PCR セットのまま再 enroll しようとすると、
`This PCR set is already enrolled, executing no operation.` と出て黙って
何も起きないことがある。PCR セットを変える、または壊れた enrollment を
作り直すときは、`--wipe-slot=tpm2` で既存の TPM2 keyslot を消すコマンドと、
新規に enroll するコマンドを分けて実行する。

```bash
ssh <target> 'sudo systemd-cryptenroll --wipe-slot=tpm2 /dev/disk/by-partlabel/disk-main-luks'
set -o pipefail
SOPS_AGE_KEY_FILE="$HOME/.config/sops/age/keys.txt" sops --decrypt --output-type json secrets/bootstrap.yaml | jq -jer '."luks-passphrase"' | ssh <target> 'sudo systemd-cryptenroll --unlock-key-file=/dev/stdin --tpm2-device=auto --tpm2-pcrs=7 /dev/disk/by-partlabel/disk-main-luks'
```

**wipe した状態で再起動すると initrd の解錠待ちになる。** そこを抜けるには
§6 の initrd SSH でパスフレーズを入れる必要がある。管理用 age 鍵と
`secrets/bootstrap.yaml` の両方を復旧可能な状態にしてから wipe する。

**この 2 コマンド構成を VM で通した。** `--wipe-slot=tpm2` の直後に
`luksDump` の `Tokens:` が空になり、再起動すると initrd で解錠待ちになる。
initrd SSH で解錠して起動したあと `--tpm2-device=auto --tpm2-pcrs=7` で
enroll し直すと `0: systemd-tpm2` が戻る。

## 5. 動作確認

### 5.1 リセット後の自動解錠

電源断相当のリセット後、スキャンコードを一切送らずに SSH をポーリングして
到達すれば、自動解錠が成立している。パスフレーズの入力は不要。
(「スキャンコード」は §3.4 で説明する、`VBoxManage controlvm ... keyboardputscancode`
で送るキー入力のこと。ここで送らずに到達する、
という意味。)

### 5.2 カーネル更新後も自動解錠が維持されるか

`nixos-rebuild switch` でカーネルを更新し、再起動して §5.1 と同様に確認する。
`cryptsetup token export` の `"tpm2-pcrs":[7]` はカーネル更新後も維持される。

**既知の制限**: カーネル更新後の再起動が、TPM 関連の初期化
(`Starting Early TPM SRK Setup...`)の段階でハングする場合がある(LUKS の
パスフレーズ入力プロンプトにすら到達しない停止であり、TPM2/PCR7 の
enrollment 自体の問題ではない)。原因は特定できていない。長時間(10 分程度)
応答が無い場合はハードリセットして再試行すること。**それでも同じ箇所で
ハングする場合は、この runbook が想定していない別の原因を疑うこと。**

## 6. 復旧手順(initrd SSH)

### 6.0 先に確認すること: USB イーサネットアダプタが挿さっているか

**この機体に有線 LAN ポートは無く、initrd に無線は入れていない。**
USB イーサネットアダプタが挿さっていなければ、initrd 側の遠隔復旧は
**存在しない** — 物理コンソールへ行くしかない。ドライバやネットワーク定義の
切り分けに入る前に、まずアダプタの装着を確認すること。

### 6.1 前提: NIC ドライバが無いと復旧経路自体が機能しない

initrd でネットワークが使えるには、NIC ドライバが initrd に含まれている
必要がある。無いと NIC が検出されず `systemd-networkd` は loopback しか
上げない。

**「到達不能」の見え方は環境によって違う。**

- **VM(VirtualBox NAT)では、TCP は確立するのに SSH バナーが一切返ら
  ない。** VirtualBox の NAT はホスト側で TCP を accept してからゲストへ
  転送する実装のため、ゲストに IP が無く誰も listen していなくても、
  host 側からの接続自体は成立して見える。実測(2026-08-21、VM でこの
  状態を再現)では 75〜90 秒程度で `Connection reset by peer` になった。
- **実機で NIC ドライバが欠けている場合はこれと異なる。** NAT のような
  中間の accept が無いため、リンクが上がっていない NIC への到達は ARP
  解決自体が失敗し、接続拒否かタイムアウトになると考えられる(**未確認**。
  実機でこの状態を実測してはいない)。

読むのは TPM 解錠に失敗して遠隔から入れない最中であることが多い。VM の
症状(TCP 確立・バナー無し)を実機でも同じものだと思って切り分けを進めると
誤る。§2 のゲート 3 で NIC ドライバを確認・宣言することが、この節の手順
全体の前提になる。

### 6.2 接続方法

```
ssh -tt -p <port> root@<host>
```

- **`root@` で入る。** `shishi@` では `Permission denied (publickey)` になる。
  initrd の `AuthorizedKeysFile` は `/etc/ssh/authorized_keys.d/root` のみで、
  `boot.initrd.network.ssh.authorizedKeys` は initrd に単一しか存在しない
  root ユーザーの authorized_keys として展開される。
- **`-tt`(`RequestTTY=force`)が要る。** 無いと公開鍵認証は成功するが、
  `command="systemctl default"` が pty 無しで実行されるためパスフレーズの
  プロンプトがどこにも出力されず、接続がハングしたまま応答しなくなる。
- **ポート**: initrd の sshd は guest:2222 で listen する。本体 sshd
  (guest:22)とは別ポートなので、host 側の到達経路(NAT/ファイアウォール)は
  本体 sshd 用の転送とは別に用意する必要がある。VM では
  `host:2223 → guest:2222` の NAT 規則を使った。**実機でこのポートに
  どう到達するかは環境依存であり未確認。**
- host key のフィンガープリントで「本体 sshd ではなく initrd sshd に
  繋がっているか」を判別できる。**`/var/lib/initrd-ssh/ssh_host_ed25519_key.pub`
  は暗号化された `/`(btrfs `@root`)の上にあり、initrd で足止めされている
  状況ではまだマウントされていない。** そこへ読みに行くには、解錠したい
  その当のマシンにログインする必要が生じてしまう(循環)。代わりに §3.2(ゲート 4 で
  初回インストールした場合はゲート 4 の手順 3)で控えた
  フィンガープリントを使い、`ssh-keyscan -p <port> <host> | ssh-keygen -lf -` の結果と比較する。

### 6.3 パスフレーズ投入

管理用 age 鍵で bootstrap を復号し、`jq` が抽出した LUKS 値だけを pipe へ流す。
画面へ表示せず、永続ファイルにも保存しない。ワークステーション側の nix-config
checkout で、`sops` と `jq` が使える devShell から実行する。

```bash
set -o pipefail
SOPS_AGE_KEY_FILE="$HOME/.config/sops/age/keys.txt" sops --decrypt --output-type json secrets/bootstrap.yaml | jq -jer '."luks-passphrase" + "\n"' | { cat; sleep 90; } | timeout 150 ssh -tt -p <port> root@<host>
```

`sleep 90` は、プロンプトが出るより先に標準入力が閉じて ssh が終了するのを
防ぐため。`-tt` は擬似端末を強制する指定で、これが無いと
`systemd-tty-ask-password-agent` がプロンプトを出さない。

次のプロンプトが出力される。

```
🔐 Please enter passphrase for disk disk-main-luks (cryptroot): (press TAB for no echo)
```

投入後、`Connection to <host> closed.`(exit 0)で切断されるのは
`switch-root` によって initrd の sshd が停止したことによる正常終了であり、
異常ではない。

### 6.4 `x-systemd.device-timeout=infinity` の効果

`fileSystems."/".options` に設定済み。initrd SSH が最初から機能せず、
コンソールから手動でパスフレーズを入れるまで長時間待たされる状況でも、
パスフレーズのプロンプトは崩れず、cryptsetup 関連の unit がタイムアウトで
失敗することはない。

### 6.5 VM のハングとの切り分け

起動中に SSH が応答しない場合、単純な起動の遅さなのか VM 自体が完全に
ハングしているのかを切り分ける必要がある。数秒間隔でコンソールの
スクリーンショットを 2 枚取り、バイトサイズが完全に同一であればハングと
判定できる(`Ctrl+Alt+F3` 相当のキー入力に画面が無反応なら判定を補強できる)。
ハングと判定したら VM をリセットする。VM 環境固有の既知事象であり、
TPM2/Secure Boot の enrollment 自体の欠陥ではない。**実機でこの種のハングが
起きるかは未確認。**

## 7. ブートローダ変更後は毎回自動解錠を確認する

lanzaboote の再インストール(ブートローダファイルの再生成を伴う操作)は
PCR 7(secure-boot-policy)の値を変える可能性があり、既存の PCR7 のみに
縛った enrollment がその変化で解錠不能になることがある
(`journalctl` に `TPM policy does not match current system state. ...
Operation not permitted` が出る)。

→ **ブートローダ構成を変える操作(lanzaboote 関連ファイルが更新される
`nixos-rebuild switch`/`boot` を含む)の前後では、必ず自動解錠を確認する
こと。** 解錠できなくなっていたら手動でパスフレーズを入力して起動し、§4.5
の手順で TPM2 enrollment を作り直す。

## 8. フェーズ B(`systemd-pcrlock`)— 現在は未対応

VM の仮想 TPM + OVMF では `systemd-pcrlock` が機能する前提を満たせず、
`hosts/jupiter/default.nix` にフェーズ B を有効化する宣言はコミットして
いない(属性パスは実機で有効化する際に確定する。`flake/checks.nix` の
契約 check も同様に未追加)。

### 8.1 実機で試すときに最初に確認すること

**`systemd-pcrlock is-supported` が `yes` を返すことは十分条件ではない。**
正しい前提条件は「イベントログの再生が実際の PCR 値を再現すること」で、
これは `make-policy` を実行して protection mask を読むまで分からない。
VM では `is-supported` が `yes` を返しながら実際には使えなかった。実機で
試すときは次の順で確認する。

1. `systemd-pcrlock` は PATH に無いのでフルパスで呼ぶ
   (`/run/current-system/sw/lib/systemd/systemd-pcrlock`)。
   `sudo <フルパス> is-supported` で `yes` を確認する(必要条件だが十分
   条件ではない)。
2. `sudo <フルパス> make-policy --recovery-pin=show` を実行し、標準出力の
   `PCRs dropped from protection mask:` / `PCRs in protection mask:` を
   確認する。宣言したい PCR(0, 4, 7 など)が dropped 側に出た場合、実機の
   イベントログ実装に VM と同じ制約がある。

   VM での drop 理由: `lock-firmware-code`(PCR 0)/
   `lock-secureboot-authority`(PCR 7)という「現在の状態を無条件に確定
   する」コマンドすら `Event log ... does not match PCR state, refusing`
   で失敗した。個々のイベントは認識されている
   (`allEventsMatched: true`)のに、それらを連結して計算した最終ダイジェスト
   が実際のレジスタ値と一致しない(`hashMatchesEventLog: false`)という、
   vTPM 自身の自己矛盾だった。実機の物理 TPM でこの制約が無いかは未確認。
3. warm reboot(`systemctl reboot`)と、電源断相当のリセットの両方で
   `make-policy` を再実行し、結果が変わらないか確認する。結果が同じで
   あれば、リブート方式の違いではなく TPM/ファームウェアの実装そのものの
   限界であると判断できる。
4. drop が無ければ enroll(§4.5 相当。`--tpm2-pcrlock=/var/lib/systemd/pcrlock.json`
   を指定する形)に進んでよい。drop があれば、フェーズ B の効果が「値の
   変わらない PCR(13/14/15 など)だけを保護する enrollment」に縮退し、
   「カーネル更新に追従する」という中核目的を検証できないので、enroll に
   進む前に判断をユーザーへ戻すこと。

recovery PIN は `make-policy --recovery-pin=show` の実行時に標準出力へ
表示される。既定の `hide`(`pcrlock.json` に暗号化保存)は、ポリシーが古く
なった時点で取り出せなくなるため使わない。

### 8.2 recovery PIN の保管方針

**PIN そのものは本 runbook を含むこの repo のどこにも書かない。** 取得できた
PIN はユーザー本人がオフラインの秘密管理手段に控える。この repo は public
であり、PIN・パスフレーズ・秘密鍵はいかなる形式でもコミットしない。

### 8.3 無効化の順序(未確認)

以下はフェーズ B を実際に enroll していないため未確認。実機でフェーズ B を
成立させた後に無効化するときの参考手順として記載する。

想定している順序:

1. `sudo systemd-cryptenroll --wipe-slot=tpm2 /dev/disk/by-partlabel/disk-main-luks`
2. フェーズ B を有効化した際に `hosts/jupiter/default.nix` に追加した宣言を
   戻して `nixos-rebuild switch`(属性パスは有効化した時点で記録すること)
3. `sudo <systemd-pcrlockのフルパス> remove-policy`

逆順(特に 3 を先に実行する場合)の挙動は未確認。pcrlock ポリシーを先に
消すと keyslot の検証対象(`PolicyAuthorizeNV` が指す NV index の内容)が
失われ、締め出される可能性があると考えているが、実機で確認するまで
保証はない。

## 9. コマンドの既知の制限

| コマンド | 制限 |
|---|---|
| `sbctl <verb>` | PATH に無い。`nix run nixpkgs#sbctl -- <verb>` を使う |
| `systemd-pcrlock <verb>` | PATH に無い。`/run/current-system/sw/lib/systemd/systemd-pcrlock` をフルパスで呼ぶ |
| `systemd-pcrlock has-tpm2` | systemd 261 にこの verb は存在しない。TPM の実在は `/dev/tpm0`・`/dev/tpmrm0` で見る |
| `systemd-pcrlock log --json=short \| grep -c PATTERN` | 1 行 JSON なので `grep -c` は常に 0 か 1 になる。`grep -o PATTERN \| wc -l` で出現回数を数える |
| `VBoxManage showvminfo ... \| grep -i tpm` | 要素名は `TrustedPlatformModule`。`tpm` という文字列を含まないため拾えない |
| `VBoxManage modifynvram <vm> secureboot`(引数無し) | クエリ用途には使えない。`--enable`/`--disable` の指定が必須 |
| `VBoxManage modifynvram <vm> queryvar PK` | `--name=PK` の指定が必須 |
| `cryptsetup luksDump` | `cryptsetup 2.8.6` では `tpm2-pcrs` 等の詳細を表示しない。`cryptsetup token export --token-id=N` で生 JSON を見る |
| 同一 PCR セットでの再 `systemd-cryptenroll` | `This PCR set is already enrolled, executing no operation.` で黙って何もしないことがある。wipe と enroll を分ける |
| initrd SSH に `shishi@` で接続 | `Permission denied (publickey)`。initrd では `root@` のみ |
| initrd SSH に `-tt` を付けない | 公開鍵認証は成功するがプロンプトが出ず無応答のままハングする |
