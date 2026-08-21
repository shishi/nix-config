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

`hosts/jupiter/default.nix` に宣言済み(`nixos-rebuild` で自動的に反映される):

- `boot.loader.systemd-boot.enable = false;` / `boot.lanzaboote.enable = true;`
  (`pkiBundle = "/var/lib/sbctl";`)
- `boot.loader.efi.canTouchEfiVariables = true;`
- `boot.initrd.systemd.enable = true;`(TPM2 自動解錠には systemd initrd が前提)
- `boot.initrd.availableKernelModules = [ "e1000" ];`(VM の NIC ドライバ名。
  実機は §2 で確認して書き換える)
- `boot.initrd.network.enable = true;` と `boot.initrd.network.ssh`
  (`port = 2222`、ホストキーは `/var/lib/initrd-ssh/` に手動生成、
  `authorizedKeys` は本体ユーザーの鍵を流用)
- `boot.initrd.systemd.network.networks."30-initrd-remote-recovery-ethernet-dhcp"`
  (`matchConfig.Type = "ether"; DHCP = "yes";`)
- `fileSystems."/".options = [ "x-systemd.device-timeout=infinity" ];`

宣言できない(このマシン固有の秘密や、firmware/NVRAM の状態そのものに
依存するため)ので手で打つ必要があるもの:

- Secure Boot の鍵の生成(`sbctl create-keys`)。`/var/lib/sbctl` に生成され、
  この public repo にはコミットしない。
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
確認し、`hosts/jupiter/default.nix` の `boot.initrd.availableKernelModules` に
追記する。

```
basename $(readlink /sys/class/net/<iface>/device/driver)
```

VM(NIC `enp0s3`)の値は `e1000`。**実機 jupiter のドライバ名は未確認。**
インストール時に上記コマンドで確認し、`boot.initrd.availableKernelModules` を
実機の値に置き換えること。置き換えないと、実機の NIC がそのドライバに
対応していない限り initrd でリンクが上がらず、§6 の復旧経路が機能しない。

## 3. フェーズ A: 鍵の生成 → Secure Boot 有効化 → TPM2 enroll

### 3.1 鍵の生成

`sbctl` は PATH に無いので `nix run` で呼ぶ。

```
sudo nix run nixpkgs#sbctl -- create-keys
sudo nix run nixpkgs#sbctl -- status
```

`/var/lib/sbctl/keys/{PK,KEK,db}/*.{key,pem}` が生成され、`status` は
`Setup Mode: Disabled`(まだ Setup Mode ではない)と出る。

### 3.2 `nixos-rebuild switch` で lanzaboote を適用する

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

### 3.3 Setup Mode に入る

**ここだけ VM と実機で手順が違う。**

VM:

```
VB="/c/Program Files/Oracle/VirtualBox/VBoxManage.exe"
"$VB" controlvm jupiter-anywhere-test acpipowerbutton
# showvminfo --machinereadable の VMState="poweroff" を確認してから次へ
"$VB" modifynvram jupiter-anywhere-test enrollorclpk
"$VB" startvm jupiter-anywhere-test --type headless
```

起動後、LUKS のパスフレーズを入力してログインできる状態にする。

実機: firmware(UEFI)のセットアップメニューから Secure Boot の設定に入り、
既存の PK をクリアして Setup Mode に切り替える。**具体的なメニュー操作は
firmware ベンダー依存であり未確認。**

確認(共通):

```
sudo nix run nixpkgs#sbctl -- status
```

`Setup Mode: Enabled` を確認してから次に進む。`sbctl` の `✗`/`✓` 記号は
見た目が反転して見えることがあるので、記号ではなく後続の文字列
(`Enabled`/`Disabled`)を読むこと。

### 3.4 鍵を enroll する

```
sudo nix run nixpkgs#sbctl -- enroll-keys --microsoft
```

`--microsoft` は省略できない。省略すると Microsoft の option ROM 検証鍵が
入らず、環境によっては起動しなくなる。

確認: `sudo nix run nixpkgs#sbctl -- status` で `Setup Mode: Disabled` /
`Vendor Keys: microsoft` を確認する。

### 3.5 Secure Boot を有効化する

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

§3.5 のとおり Secure Boot の有効化で PCR 7 の値が変わる。enroll を先に
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

```
sudo cryptsetup token export --token-id=0 /dev/disk/by-partlabel/disk-main-luks
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
上げないため、initrd の sshd は listening していても外部から到達不能になる
(TCP は確立するのに SSH バナーが一切返らない)。§2 のゲート 3 で NIC
ドライバを確認・宣言することが、この節の手順全体の前提になる。

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
  繋がっているか」を判別できる。`/var/lib/initrd-ssh/ssh_host_ed25519_key.pub`
  のフィンガープリントと `ssh-keyscan` の結果を比較する。

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
