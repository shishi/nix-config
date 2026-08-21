# jupiter: Secure Boot + TPM2 自動解錠 runbook

## 0. 前提

対象は実機 `jupiter`(NixOS)で Secure Boot を有効化し、TPM2 で LUKS を自動解錠
できるようにする作業。VirtualBox VM(仮想 TPM 2.0、OVMF、systemd 261)での検証
に基づく。実機固有の手順(firmware メニューの操作、NIC ドライバ名など)で
未確認のものは、その場で「未確認」と明記する。

現在の到達点: Secure Boot 有効化と PCR7 での TPM2 enroll(フェーズ A)は
VM で成立している。カーネル更新に追従させる `systemd-pcrlock`(フェーズ B)は
§8 の理由により未対応で、`hosts/jupiter/default.nix` に該当の宣言は入っていない。

## 1. 何が宣言済みで、何を手で打つのか

`hosts/jupiter/default.nix` と `hosts/jupiter/disko.nix` に宣言済み。**既に
インストール済みのホストでは** `nixos-rebuild` を実行するだけで反映される。
**初回インストール(まだ NixOS が入っていない実機)にはこの前提は当てはま
らない** — `boot.lanzaboote.enable` と `hostKeys` は `/var/lib/sbctl` /
`/var/lib/initrd-ssh/...` の実在を前提にしており、無いとインストールが
失敗する。詳細は §2 のゲート 4 を参照:

- `boot.loader.systemd-boot.enable = false;` / `boot.lanzaboote.enable = true;`
  (`pkiBundle = "/var/lib/sbctl";`)
- `boot.loader.efi.canTouchEfiVariables = true;`
- `boot.initrd.systemd.enable = true;`(TPM2 自動解錠には systemd initrd が前提)
- `boot.initrd.availableKernelModules = [ "e1000" ];`(VM の NIC ドライバ名。
  実機は §2 で確認して置き換える)
- `boot.initrd.network.enable = true;` と `boot.initrd.network.ssh`
  (`port = 2222`、`hostKeys` は `/var/lib/initrd-ssh/ssh_host_ed25519_key`
  を指す絶対パス指定。実体(鍵ファイル)は宣言できないので手で生成する
  (§3.2)。`authorizedKeys` は本体ユーザーの鍵を流用)
- `boot.initrd.systemd.network.networks."30-initrd-remote-recovery-ethernet-dhcp"`
  (`matchConfig.Type = "ether"; DHCP = "yes";`)
- `fileSystems."/".options = [ "x-systemd.device-timeout=infinity" ];`
- `hosts/jupiter/disko.nix` の
  `disko.devices.disk.main.content.partitions.luks.content.settings.crypttabExtraOpts`
  `= [ "tpm2-device=auto" ];`(TPM2 自動解錠の取得口。無いと enroll しても
  起動時にパスフレーズを聞かれる)

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

`hosts/jupiter/hardware-configuration.nix` は現在スタブで、2 段のゲートを
コメントとして持っている。

**ゲート 2**: installer から起動した実機で

```
nixos-generate-config --no-filesystems --show-hardware-config
```

を実行し、その出力で `hosts/jupiter/hardware-configuration.nix` のスタブを
実物に置き換える。

**ゲート 3**: `nixos-generate-config` が生成する
`boot.initrd.availableKernelModules` はストレージ・入力系
(`nvme` / `xhci_pci` / `usb_storage` / `sd_mod` 相当)が中心で、NIC ドライバは
含まれない。initrd でネットワークが要るのは §6 の遠隔復旧経路(initrd SSH)の
ためであり、ゲート 2 だけでは自動的に得られない。実機で NIC ドライバ名を
確認し、`hosts/jupiter/default.nix` の `boot.initrd.availableKernelModules` を
実機の値に置き換える。

```
basename $(readlink /sys/class/net/<iface>/device/driver)
```

VM(NIC `enp0s3`)の値は `e1000`。**実機 jupiter のドライバ名は未確認。**
インストール時に上記コマンドで確認し、`boot.initrd.availableKernelModules` を
実機の値に置き換えること。置き換えないと、実機の NIC がそのドライバに
対応していない限り initrd でリンクが上がらず、§6 の復旧経路が機能しない。

**ゲート 4(初回インストール専用。対象マシンにまだ NixOS がインストール
されていない場合のみ適用)**: `boot.lanzaboote.enable = true;` と
`hostKeys = [ "/var/lib/initrd-ssh/ssh_host_ed25519_key" ];` はどちらも、
対象マシンに既に `/var/lib/sbctl`(sbctl の鍵)と
`/var/lib/initrd-ssh/ssh_host_ed25519_key`(initrd SSH のホストキー)が
存在することを前提にしている。

**未インストールの実機にこの宣言のまま初回インストールすると、
ブートローダ設置段で失敗する。** lanzaboote のソースで確認したところ、
`lzbt install` は `--public-key=${cfg.publicKeyFile}` /
`--private-key=${cfg.privateKeyFile}`(既定値 `${pkiBundle}/keys/db/db.{pem,key}`、
つまり `/var/lib/sbctl/keys/db/db.{pem,key}`)を渡される。新規インストール先には
これが存在しない。同じ段で、§3.2 の `append-initrd-secrets`(initrd SSH の
ホストキーを `cp -a` するコマンド)も `/var/lib/initrd-ssh/...` が無くて失敗する。
しかも disko がディスクを消去・暗号化して rootfs を展開した**後**にこれが
起きるので、ブート不能な中途半端な状態で止まる。

さらに §3.1 の `sbctl create-keys` は「稼働中の jupiter で sudo が使える」ことを
前提に書かれているが、初回インストールの場面ではその稼働中の jupiter に到達する
手段そのものが無い(鍵が無いと起動しない→鍵を作るには起動している必要がある、
という循環)。

**採用する方針: `nixos-anywhere --extra-files <dir>` で、インストール前に
鍵を先置きする。** 宣言(`hostKeys`・`lanzaboote.enable`)を初回インストールの
ためだけに無効化するのは設計が間違っているサインなので、宣言をそのまま成立
させる方を採る。この repo は既に `--disk-encryption-keys` を使っているので、
同じ仕組みの延長になる。

手順:

1. インストールを実行する手元のマシンで一時ディレクトリを作り、その中に
   `var/lib/sbctl/` と `var/lib/initrd-ssh/` を用意する(`nixos-anywhere
   --extra-files` は指定したディレクトリの中身をそのままインストール先の
   `/` へコピーする)。

   ```
   mkdir -p /tmp/jupiter-extra-files/var/lib/sbctl
   mkdir -p /tmp/jupiter-extra-files/var/lib/initrd-ssh
   ```

2. `sbctl create-keys` の出力先を直接そこへ向ける公式オプションは確認して
   いないため、生成後にコピーする。

   ```
   sudo nix run nixpkgs#sbctl -- create-keys
   sudo cp -a /var/lib/sbctl/. /tmp/jupiter-extra-files/var/lib/sbctl/
   ```

3. initrd 用ホストキーを §3.2 と同じ手順で、直接このディレクトリの下に作る。

   ```
   sudo ssh-keygen -t ed25519 -N "" \
     -f /tmp/jupiter-extra-files/var/lib/initrd-ssh/ssh_host_ed25519_key
   sudo chmod 600 /tmp/jupiter-extra-files/var/lib/initrd-ssh/ssh_host_ed25519_key
   ```

4. **パーミッションが保たれるかは未確認。** `--extra-files` が所有者・モード
   (特に秘密鍵の 600)を保持してコピーするのかは、この runbook では実測して
   いない。インストール後、実機側で次のコマンドで実際の所有者・モードを
   確認すること。

   ```
   ls -l /var/lib/sbctl/keys/db/ /var/lib/initrd-ssh/
   ```

   `root:root` かつ秘密鍵が `600` になっていなければ、保持されなかった
   ということなので次で矯正する。

   ```
   sudo chown -R root:root /var/lib/sbctl /var/lib/initrd-ssh
   sudo chmod 600 /var/lib/initrd-ssh/ssh_host_ed25519_key
   sudo find /var/lib/sbctl/keys -name "*.key" -exec chmod 600 {} +
   ```

5. `nixos-anywhere` 実行時に `--extra-files` を追加する(既存の
   `--disk-encryption-keys` と併用)。

   ```
   nixos-anywhere --extra-files /tmp/jupiter-extra-files \
     --disk-encryption-keys /tmp/secret.key <local-secret-path> \
     --flake <flake-path>#jupiter root@<target-ip>
   ```

**この経路(ゲート 4 全体)は VM で実測していない。** 検証用 VM
(`jupiter-anywhere-test`)は lanzaboote を導入する前に既にインストール
済みだったため、初回インストール経路(disko によるディスク消去から
`nixos-anywhere` 完走まで)を一度も通っていない。実機で初めて実行する前に、
可能なら別の検証用 VM でこのゲート 4 の手順そのものを一度リハーサルする
ことを推奨する。

## 3. フェーズ A: 鍵の生成 → Secure Boot 有効化 → TPM2 enroll

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

### 3.4 headless VM でパスフレーズを入力する方法

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
(r e h e a r s a l + Enter とデコードして確認済み):

```
13 93 12 92 23 a3 12 92 1e 9e 13 93 1f 9f 1e 9e 26 a6 1c 9c
```

実機や別のパスフレーズを使う場合は、US 配列の PS/2 scan code set 1 の表で
文字ごとの make code を調べ、対応する break code(make code + `0x80`)と
ペアにして並べる。

### 3.5 Setup Mode に入る

**ここだけ VM と実機で手順が違う。**

**`modifynvram <vm> enrollorclpk` が実際に Setup Mode へ入る操作かは
未確認。** このコマンドはこのラウンドで一度も実行していない(検証時点で
VM は前回セッションから既に Setup Mode に入っていたため、実行せず確認
だけで先へ進んだ)。コマンド名は「Oracle の PK を enroll する」と読め、
字面からは Setup Mode を**抜ける**操作に見える。Setup Mode に**入る**なら、
UEFI 変数ストアを初期化する `inituefivarstore` の方が筋が通る。**断定は
しない**: どちらが正しいか未確定という前提で実行し、直後に必ず結果を
確認すること。

VM:

```
VB="/c/Program Files/Oracle/VirtualBox/VBoxManage.exe"
"$VB" controlvm jupiter-anywhere-test acpipowerbutton
# showvminfo --machinereadable の VMState="poweroff" を確認してから次へ
"$VB" modifynvram jupiter-anywhere-test enrollorclpk
# 未確認。上記のとおり inituefivarstore の可能性がある
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

```
printf '%s' '<現在のLUKSパスフレーズ>' | sudo systemd-cryptenroll \
  --unlock-key-file=/dev/stdin \
  --tpm2-device=auto --tpm2-pcrs=7 \
  /dev/disk/by-partlabel/disk-main-luks
```

（`disk-main-luks` は `hosts/jupiter/disko.nix` の `disko.devices.disk.main`
とパーティション `luks` から disko の命名規則で決まる partlabel で、実機でも
同名になる。パスフレーズそのものはこのファイルに書かない。実行時に現在の
LUKS パスフレーズへ読み替えること。）

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
sudo systemd-cryptenroll --wipe-slot=tpm2 /dev/disk/by-partlabel/disk-main-luks
printf '%s' '<現在のLUKSパスフレーズ>' | sudo systemd-cryptenroll \
  --unlock-key-file=/dev/stdin --tpm2-device=auto --tpm2-pcrs=7 \
  /dev/disk/by-partlabel/disk-main-luks
```

**この 2 コマンド構成そのものは未確認。**「1 コマンドにまとめないこと」
という制約だけが確認済みで、実際にこの手順で wipe → 再 enroll を通した
確認はしていない。

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
  その当のマシンにログインする必要が生じてしまう(循環)。代わりに §3.2 で
  控えたフィンガープリントを使い、`ssh-keyscan -p <port> <host> |
  ssh-keygen -lf -` の結果と比較する。

### 6.3 パスフレーズ投入

```
( printf '<現在のLUKSパスフレーズ>\n'; sleep 90 ) | timeout 150 ssh -tt -p <port> root@<host>
```

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
`hosts/jupiter/default.nix` に `measuredBoot` 相当の宣言はコミットしていない
(`flake/checks.nix` の契約 check も同様に未追加)。

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
2. `hosts/jupiter/default.nix` で `measuredBoot.enable = false;` にして
   `nixos-rebuild switch`
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
