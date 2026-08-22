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
  (インストール時の非対話暗号化。`nixos-anywhere --disk-encryption-keys
  /tmp/secret.key <src>` とペア。**`settings` の配下に置かないこと** —
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
  `hosts/jupiter/disko.nix` の `device` と一致している。**手順 1 の disko phase は
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

**2026-08-21 に検証用 VM で通しリハーサル済み。** 以下は実際に実行して
結果を確認した手順である(確認できていない箇所はその旨を明記する)。

**ただし手順 0 はその後に書き換えられている。** リハーサル時の手順 0 は
「素の ISO を起動してコンソールで鍵を手打ちする」だった。現行の手順 0
(鍵を焼き込んだ ISO を自分でビルドする)は、ISO の生成とファイル名までしか
実測していない。

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

- **sbctl の鍵と initrd host key の先置きには `--extra-files` を使わない**
  (ユーザーの SSH / GPG 秘密鍵には手順 0b・手順 3 で使う)。先置き自体は
  これでも間に合う(コピーは disko の後・`nixos-install` の前に行われる)。
  sbctl に使わないのは、そのディスク上レイアウトをワークステーション側で
  手作りすることになり、Secure Boot の秘密鍵もワークステーションを経由するため。
  `sbctl create-keys` に自分の既定パスへ書かせれば、どちらも起きない。
- **任意コマンドを実行するフックは無い**(nixos-anywhere 1.13.0)。target 上で
  処理を挟むには phase を分割するしかない。
- **`boot.lanzaboote.enable` や `hostKeys` を初回だけ外す案は採らない。**
  宣言を成立させられないのは設計が間違っているサインなので、宣言の方を
  そのまま通す。

### 手順

**手順 0: installer を起動して root に鍵を置く**

**USB イーサネットアダプタを挿してから起動する。** この機体に有線 LAN ポートは
無く、`nixos-anywhere` はワークステーションから対象機の sshd へ繋ぐので、対象機が
先に IP を持っている必要がある。アドレスを配るのは **NetworkManager**
(上流 `installation-cd-minimal.nix` の既定。生成された toplevel の
`multi-user.target.wants/` に `NetworkManager.service` があること、`dhcpcd` の
unit は無いことを実測)なので、アダプタが挿さっていれば DHCP で付く。
無線しか無い状態だと、コンソールで `nmtui` などを手で叩くまでネットワークに
出られない。

起動したらコンソールで IP を確認する。**手順 0〜3 で画面を見るのは通常ここ
だけ**(途中で再起動してアドレスが変わった疑いが出たら、手順 3 でもう一度要る)。
手順 0 より前の firmware での Secure Boot 無効化(§2「実機で違うところ」)、
手順 4 の初回起動での LUKS パスフレーズ入力、§3.5 / §3.7 の firmware 操作には
別途コンソールが要る。

```
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

```
ssh nixos@<target> 'sudo install -d -m700 /root/.ssh; curl -Ls github.com/shishi.keys | sudo tee /root/.ssh/authorized_keys'
```

installer の `nixos` は wheel に属し `security.sudo.wheelNeedsPassword` が false
なので、`sudo` はパスワードを聞かない。実機で打つのは `passwd` だけになる。

疎通を確認してから先へ進む。

```
ssh -p <port> -o BatchMode=yes -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null root@<target> true && echo ok
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

手順 2 は target 上で `nix run` を使うので、**`nix-command` と `flakes` を
コマンドラインで明示する**(手順 2 のコマンドに入れてある)。素の
`nixos-minimal` ISO ではどちらも有効になっていない(実測: `nix config show` が
`nix-command` 不足で失敗する)。

**手順 0b: 鍵を用意する(ワークステーション側)**

dotfiles の `setup.sh` は private repo(`agent-memory`)を clone し、
`.gitconfig.linux` は `commit.gpgsign = true` を宣言する。初回起動後の作業には
SSH 秘密鍵と GPG 秘密鍵が要るので、手順 3 で一緒に置く。

初回ログイン用のパスワードハッシュも同じ経路で置く。`nixos/users.nix` は
public repo なのでパスワードを宣言しておらず、このファイルが無いと shishi は
パスワード未設定のまま起動する。**その状態では autoLogin で上がったセッションの
ロックを解除できない**(SSH 鍵で入って `sudo passwd shishi` で入れ直せる)。

受け渡し用のディレクトリは `secrets/extra-files` にする。`secrets/` は
`.gitignore` 済みなので、鍵もパスフレーズも repo の中の 1 箇所に収まり、
片付けもそこを消すだけで済む。ホームディレクトリに散らさない。
中の構成は**インストール先の `/` からの相対パス**で、先頭に `/` を付けない。

```
secrets/extra-files/home/shishi/.ssh/id_ed25519            (0600)
secrets/extra-files/home/shishi/.ssh/id_ed25519.pub        (0644)
secrets/extra-files/home/shishi/gpg-secret.asc             (0600)
secrets/extra-files/var/lib/secrets/shishi-password-hash   (0600)
```

**mode はそのまま保存されるので、ここで正しくしておく**(所有者は保存されない。
手順 3 参照)。**`secrets/extra-files` 全体に `chmod -R 700` をかけないこと。**
`secrets/extra-files` の下のディレクトリの mode は、そのままインストール後の同じパスの
mode になる。`secrets/extra-files/home` を 0700 にすると shishi が自分の home へ辿れず
ログインが壊れる。`secrets/extra-files/var` と `secrets/extra-files/var/lib` も同じで、
0700 にすると /var 配下を読む全サービスが壊れる。

```
mkdir -p secrets/extra-files/home/shishi/.ssh secrets/extra-files/var/lib/secrets
chmod 755 secrets/extra-files secrets/extra-files/home secrets/extra-files/var secrets/extra-files/var/lib
chmod 700 secrets/extra-files/home/shishi secrets/extra-files/home/shishi/.ssh
chmod 700 secrets/extra-files/var/lib/secrets
```

SSH 鍵はコピーする。構成表には載っているが、GPG やパスワードと違って
生成コマンドが無いので置き忘れやすい。置き忘れると初回起動後に
`setup.sh` の private repo clone が認証できない。

```
cp ~/.ssh/id_ed25519 ~/.ssh/id_ed25519.pub secrets/extra-files/home/shishi/.ssh/
chmod 600 secrets/extra-files/home/shishi/.ssh/id_ed25519
chmod 644 secrets/extra-files/home/shishi/.ssh/id_ed25519.pub
```

GPG は keyring を丸ごと運ばず、armored のエクスポートを 1 ファイル置いて初回起動後に
import する。

```
gpg --export-secret-keys --armor <signingkey> > secrets/extra-files/home/shishi/gpg-secret.asc
chmod 600 secrets/extra-files/home/shishi/gpg-secret.asc
test -s secrets/extra-files/home/shishi/gpg-secret.asc || echo 'gpg export が空 -- <signingkey> を確認する'
```

`<signingkey>` を打ち間違えても `gpg` は非 0 で終わるが、リダイレクトが先に
空ファイルを作るので、mode だけを見る確認では気づけない。

パスワードハッシュは `mkpasswd` で作る。`-s` は標準入力から読む指定で、
これが無いと端末のない環境では入力待ちのまま止まる。平文を端末に出さないため、
入力はシェルの silent read で受けてパイプで渡す。末尾の改行は NixOS 側が
chomp するので残ってよい。

**このブロックは bash で実行する。** fish は `IFS= read -rsp` も `if ... fi` も
解釈できないので途中で止まる(ハッシュは作られない)。**`bash` の 1 行を先に
実行し、プロンプトが出てから残りを貼ること。** まとめて貼ると、後続行が
親シェルの入力バッファに残ったまま `read` に食われる。

書き込みは生成に成功したときだけ行う。リダイレクトはコマンドの実行前に
ファイルを truncate するので、`nix run` が失敗すると **0 バイトのファイルが
mode 600 で残る**。それは手順 3 の mode 確認を通ってしまう。

```
bash                       # fish 等から実行する場合は先に bash へ入る
IFS= read -rsp 'new password: ' pw; echo
IFS= read -rsp 'retype: ' pw2; echo
if [ -z "$pw" ] || [ "$pw" != "$pw2" ]; then
  echo 'empty or mismatched -- 生成しない'
elif hash=$(printf '%s' "$pw" | nix run nixpkgs#mkpasswd -- -m yescrypt -s) \
     && [ "${hash#\$y\$}" != "$hash" ]; then
  printf '%s\n' "$hash" > secrets/extra-files/var/lib/secrets/shishi-password-hash
  chmod 600 secrets/extra-files/var/lib/secrets/shishi-password-hash
else
  echo 'mkpasswd failed -- 生成しない'
fi
unset pw pw2 hash
exit
```

出力は `$y$` で始まる 1 行になる。**このファイルの中身をこの手順書や
レビュー用の記録に貼らないこと。**

**手順 1: ディスクを作る(disko phase だけ)**

**LUKS のパスフレーズは `secrets/luks-passphrase` に置く。** `secrets/` は
`.gitignore` 済みなのでコミットされない。**値をこの手順書にも、チャットにも、
レビュー用の記録にも書かない。**

```
mkdir -p secrets
install -m 600 /dev/null secrets/luks-passphrase
# エディタで開いてパスフレーズを 1 行書く
```

エディタが付ける末尾の改行は下の `$(cat ...)` が落とす。改行を含んだまま鍵に
すると、initrd の対話プロンプトからは入力できない値になる。

ワークステーション側(nix-config のチェックアウト内)で実行する。

```
[ -s secrets/luks-passphrase ] || { echo 'パスフレーズが空'; exit 1; }
printf '%s' "$(cat secrets/luks-passphrase)" > /tmp/luks.key
chmod 600 /tmp/luks.key
nix run .#nixos-anywhere -- --flake .#jupiter \
  --target-host root@<target> --ssh-port <port> \
  --disk-encryption-keys /tmp/secret.key /tmp/luks.key \
  --phases disko
```

`--disk-encryption-keys <remote> <local>` の remote 側は
`hosts/jupiter/disko.nix` の `passwordFile` と一字一句一致させる
(`/tmp/secret.key`)。ずれると disko が対話パスワードを聞きに行く。

`### Done! ###` で終わり、`/mnt` に ESP と btrfs subvolume がマウントされた
状態で止まる。確認:

```
ssh -p <port> -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  root@<target> 'findmnt -R /mnt -o TARGET,SOURCE,FSTYPE'
```

期待: `/mnt`(`@root`)・`/mnt/boot`(vfat)・`/mnt/home`・`/mnt/nix`・`/mnt/.swap`。

**手順 2: 鍵を `/mnt` に作る**

`ssh -p <port> -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@<target>` で入り、
target 上で実行する。

```
rm -rf /var/lib/sbctl   # 手順 2 を 2 回目以降に実行するときだけ必要
nix --extra-experimental-features "nix-command flakes" run nixpkgs#sbctl -- create-keys
mkdir -p /mnt/var/lib
cp -a /var/lib/sbctl /mnt/var/lib/
mkdir -p /mnt/var/lib/initrd-ssh
ssh-keygen -t ed25519 -N "" -f /mnt/var/lib/initrd-ssh/ssh_host_ed25519_key
chmod 600 /mnt/var/lib/initrd-ssh/ssh_host_ed25519_key
ssh-keygen -lf /mnt/var/lib/initrd-ssh/ssh_host_ed25519_key.pub
```

`sbctl create-keys` は installer 自身の `/var/lib/sbctl` に書く(出力先は
変えない)。生成されるのは `GUID` と `keys/{PK,KEK,db}/*.{key,pem}`。
`cp -a` で所有者と mode がそのまま `/mnt` 側へ移る。

最後の `ssh-keygen -lf` が出すフィンガープリントは §6.2 の照合に使うので
**`secrets/initrd-ssh-fingerprint.txt` に保存する**(`secrets/` は
`.gitignore` 済み。公開鍵の指紋なので秘密ではないが、機体を特定する情報なので
public repo には入れない)。`/var/lib` は暗号化された `/` の上にあり、initrd で
足止めされている状況では未マウントなので、そのときには取りに行けない。

確認:

```
find /mnt/var/lib/sbctl /mnt/var/lib/initrd-ssh -printf '%M %u:%g %p\n'
```

期待: sbctl の鍵 6 本が `-r-------- root:root`、
`ssh_host_ed25519_key` が `-rw------- root:root`。

**手順 3: インストール(install phase)**

**先に手順 1 の `findmnt -R /mnt` をもう一度実行し、`/mnt` と `cryptroot` が
生きていることを確かめる。** 手順 1〜3 の間に対象機が再起動・電源断していると
マウントも `cryptroot` も失われる。**そのときは手順 1(disko phase)から
やり直す。** `authorized_keys` は ISO に焼き込んであるので、鍵を置き直すために
手順 0 まで戻る必要は無い。

**`findmnt` が期待どおりのマウントを返さなかったとき(接続エラーを含む)は、
手順 1 を再実行する前に相手を確かめる。** 対象機のコンソールで
`ip -brief addr show` を見て、`<target>` がその installer の現在のアドレスで
あることを確認する。DHCP でアドレスが移り、旧アドレスを別のホストが取って
いることがある。そのとき `findmnt` は接続エラーではなく「ssh は通るが
マウントが出ない」形になる。**手順 1 は disko = 再フォーマットなので、別の
ホストに対して実行してはならない。**

ワークステーション側で実行する。

```
nix run .#nixos-anywhere -- --flake .#jupiter \
  --target-host root@<target> --ssh-port <port> \
  --extra-files secrets/extra-files --chown home/shishi 1000:100 \
  --phases install
```

`Successfully installed Lanzaboote.` と `installation finished!` が出れば、
ゲート 4 が問題にしていた失敗点は通過している。

`--extra-files` の中身は `nixos-install` の**直前**にコピーされる
(`### Copying extra files ###` が `### Installing NixOS ###` より前に出る)。
tar は `--no-same-owner` で展開されるため、**mode は保存されるが所有者は root に
なる**。`--chown <path> <uid>:<gid>` が `/mnt/<path>` を再帰的に chown して直す。

**ユーザー名ではなく数値を渡すこと。** chown は installer 環境の名前解決で動くため、
installer 上で uid 1000 を持つ `nixos` ユーザーの名前が使われてしまう。
`--chown home/shishi shishi:users` は別人を指す。

`1000:100` は `hosts/jupiter/default.nix` の `users.users.shishi.uid` と
`users.users.shishi.group`(= `users`、gid 100)に対応する。この対応は
`flake/checks.nix` の `install-keys-contract` が**この runbook を grep して**固定する。
config 側だけを見る check では、この行を書き換えたときに落ちない。

確認(手順 4 の停止前に):

```
ssh -p <port> -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  root@<target> 'find /mnt/home -printf "%M %U:%G %p\n" | sort; \
  ls -ld /mnt/var /mnt/var/lib /mnt/var/lib/secrets \
         /mnt/var/lib/secrets/shishi-password-hash'
```

期待: `/mnt/home` は `drwxr-xr-x` の `0:0`(**ここが `drwx------` ならログインが
壊れる**)、その下の `home/shishi` 以下がすべて `1000:100` で、
`.ssh` が `drwx------`、秘密鍵が `-rw-------`。

`/mnt/var` と `/mnt/var/lib` は `drwxr-xr-x` の `root root`、
`/mnt/var/lib/secrets` は `drwx------`、その下のハッシュは `-rw-------`。

mode だけでは 0 バイトのファイルを見分けられないので、中身が空でないことも見る
(**値そのものは表示しない**)。

```
ssh -p <port> -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  root@<target> \
  'test -s /mnt/var/lib/secrets/shishi-password-hash && echo hash-ok || echo hash-EMPTY;
   test -s /mnt/home/shishi/.ssh/id_ed25519 && echo sshkey-ok || echo sshkey-EMPTY;
   test -s /mnt/home/shishi/gpg-secret.asc && echo gpg-ok || echo gpg-EMPTY'
```
`--chown` は home 側にしか効かないので、こちらは root 所有のままで正しい。
**ここを見ないと、鍵は置いたのにハッシュを置き忘れた状態が初回起動まで
表に出ない**(shishi の shadow が `!` になり、どのパスワードも通らなくなる)。

**この手順が失敗して手順 1 をやり直した場合は、必ず手順 2 も実行し直すこと。**
`--phases disko` は再フォーマットなので、`/mnt` 上に作った鍵は消えている。
気づかずに手順 3 だけ再実行すると、このゲートが防いでいる失敗がそのまま再発する。

**手順 4: 停止して installer メディアを外す**

```
ssh -p <port> -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  root@<target> 'swapoff -a; umount -R /mnt && cryptsetup close cryptroot'
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
聞かれる。手順 1 で使ったものを入力する。

**手順 5: 後始末**

ワークステーション側の `/tmp/luks.key` と `secrets/extra-files` を消す。

```
shred -u /tmp/luks.key
rm -rf secrets/extra-files
```

`secrets/luks-passphrase` は §6 の遠隔復旧で要る値なので残す。捨てるなら先に
別の場所へ控える。**`secrets/` を丸ごと消すとパスフレーズも消える。**

初回起動後、対象機で GPG 秘密鍵を import して置いたファイルを消す。

```
gpg --import ~/gpg-secret.asc && shred -u ~/gpg-secret.asc
```

### この後どこへ進むか

**§3.1(`sbctl create-keys`)と §3.2(`ssh-keygen`)は実行しない。**
鍵は手順 2 で既に作られている。**§3.3(`nixos-rebuild switch`)も不要**で、
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

新規作成した検証用 VM で手順 1〜4 を実行し、続けて §3.6 → §3.7 →
§4.1〜§4.4 → §5.1 を通した結果(**§4.5 の wipe → 再 enroll は通していない**。
§4.5 自身の未確認注記はそのまま残る):

- `bootctl status` が §3.7 の「期待:」ブロックと一致
- LUKS token JSON が §4.4 の「期待(該当部分)」と一致
- 稼働中の `/var/lib/initrd-ssh/ssh_host_ed25519_key.pub` のフィンガープリントが、
  手順 2 で `/mnt` に作った鍵のものと一致
- ハードリセット後、キー入力ゼロで自動解錠(§5.1)

**§3.5(Setup Mode に入る)は初回のリハーサルでは通していない。** VM が新規作成で
NVRAM が空だったため、初回起動の時点で既に `Setup Mode: Enabled` だった。
`inituefivarstore` の方は、鍵の先置きを実測する再インストールの前段で実行して
確認している(§3.5)。

つまり、**インストール時に署名に使った鍵と、後から UEFI へ enroll する鍵が
同一である**ことまで確認できている。ここがゲート 4 の要点で、鍵を作り直すと
`nixos-install` が作った最初の世代(NixOS の generation 1)の UKI が
検証できなくなる。

### 実機で違うところ

- **手順 0 の直後、手順 1 に入る前に、ゲート 2 と ゲート 3 を済ませる。**
  ゲート 2 の `nixos-generate-config` は手順 0 の SSH 経路で実行できるはず
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
使うフィンガープリントは、ゲート 4 の手順 2 で控えたものを使う。

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

確認: `sudo nix run nixpkgs#sbctl -- status` で `Setup Mode: Disabled` /
`Vendor Keys: microsoft` を確認する。

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

パスフレーズは手順 1 と同じ `secrets/luks-passphrase` から読む。**コマンド
ラインに直に書かない** — shell history と `/proc/<pid>/cmdline` に残る。
ワークステーション側から実行する。

```
printf '%s' "$(cat secrets/luks-passphrase)" \
  | ssh <target> 'sudo systemd-cryptenroll --unlock-key-file=/dev/stdin \
      --tpm2-device=auto --tpm2-pcrs=7 /dev/disk/by-partlabel/disk-main-luks'
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

期待(該当部分): `"tpm2-pcrs":[7],"tpm2-pcr-bank":"sha256","tpm2-primary-alg":"ecc"`。

### 4.5 wipe と enroll は別コマンドに分ける

既存の TPM2 keyslot を同じ PCR セットのまま再 enroll しようとすると、
`This PCR set is already enrolled, executing no operation.` と出て黙って
何も起きないことがある。PCR セットを変える、または壊れた enrollment を
作り直すときは、`--wipe-slot=tpm2` で既存の TPM2 keyslot を消すコマンドと、
新規に enroll するコマンドを分けて実行する。

```
ssh <target> 'sudo systemd-cryptenroll --wipe-slot=tpm2 \
  /dev/disk/by-partlabel/disk-main-luks'
printf '%s' "$(cat secrets/luks-passphrase)" \
  | ssh <target> 'sudo systemd-cryptenroll --unlock-key-file=/dev/stdin \
      --tpm2-device=auto --tpm2-pcrs=7 /dev/disk/by-partlabel/disk-main-luks'
```

**wipe した状態で再起動すると initrd の解錠待ちになる。** そこを抜けるには
§6 の initrd SSH でパスフレーズを入れる必要があるので、`secrets/luks-passphrase`
を消した後に wipe しないこと。

**この 2 コマンド構成を VM で通した。** `--wipe-slot=tpm2` の直後に
`luksDump` の `Tokens:` が空になり、再起動すると initrd で解錠待ちになる。
initrd SSH で解錠して起動したあと `--tpm2-device=auto --tpm2-pcrs=7` で
enroll し直すと `0: systemd-tpm2` が戻る。

## 5. 動作確認

### 5.1 リセット後の自動解錠

電源断相当のリセット後、スキャンコードを一切送らずに SSH をポーリングして
到達すれば、自動解錠が成立している。パスフレーズの入力は不要。
(「スキャンコード」は §3.4 で説明する、`VBoxManage controlvm ...
keyboardputscancode` で送るキー入力のこと。ここで送らずに到達する、
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
  初回インストールした場合はゲート 4 の手順 2)で控えた
  フィンガープリントを使い、`ssh-keyscan -p <port> <host> |
  ssh-keygen -lf -` の結果と比較する。

### 6.3 パスフレーズ投入

パスフレーズはここでも `secrets/luks-passphrase` から読む。ワークステーション
側(nix-config のチェックアウト内)で実行する。

```
( printf '%s\n' "$(cat secrets/luks-passphrase)"; sleep 90 ) \
  | timeout 150 ssh -tt -p <port> root@<host>
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
