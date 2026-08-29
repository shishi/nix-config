# jupiter: Secure Boot／TPM2 自動解錠手順書

## 0. 前提

対象は実機 `jupiter`(NixOS)で Secure Boot を有効化し、TPM2 で LUKS を自動解錠
できるようにする作業。VirtualBox VM(仮想 TPM 2.0、OVMF、systemd 261)での検証
に基づく。実機固有の手順(ファームウェアメニューの操作、NIC ドライバー名など)で
未確認のものは、その場で「未確認」と明記する。

パス表記は 2 系統ある。`/mnt/c/...` は WSL 側のシェル、`/c/...` は §2.x の
`VBoxManage` を Windows 側のシェルで実行するもの。

コマンドブロックは Bash 構文で記載する。現在のシェルが fish の場合は、
ワークステーションと Jupiter のどちらでも先に `bash` を起動する。

現在の到達点: Secure Boot 有効化と PCR 7 での TPM2 登録(フェーズ A)は
VM で成立している。カーネル更新に追従させる `systemd-pcrlock`(フェーズ B)は
§7 の理由により未対応で、`hosts/jupiter/default.nix` に該当の宣言は入っていない。

## 1. 何が宣言済みで、何を手で打つのか

`hosts/jupiter/default.nix` と `hosts/jupiter/disko.nix` に宣言済み。既に
インストール済みのホストへ後から適用する場合は、§2.1・§2.2 の鍵生成を
先に済ませ、§2.3 の `nixos-rebuild switch` を実行する。

未インストールの実機では
[NixOS 初期インストール手順書](jupiter-install-runbook.md)を先に完了する。
この経路は `/var/lib/sbctl` と `/var/lib/initrd-ssh` をインストール中に作成する。

- `boot.loader.systemd-boot.enable = false;` / `boot.lanzaboote.enable = true;`
  (`pkiBundle = "/var/lib/sbctl";`)
- `boot.loader.efi.canTouchEfiVariables = true;`
- `boot.initrd.systemd.enable = true;`(TPM2 自動解錠には systemd initrd が前提)
- `boot.initrd.availableKernelModules`(`e1000` = VM 用 + USB イーサの集合。
  実機に有線ポートが無いため、遠隔復旧は USB アダプタ前提。詳細は §5.1。
  `e1000` は VM リハーサル用として残し、消さない)
- `boot.initrd.network.enable = true;` と `boot.initrd.network.ssh`
  (`port = 2222`、`hostKeys` は `/var/lib/initrd-ssh/ssh_host_ed25519_key`
  を指す絶対パス指定。実体(鍵ファイル)は宣言できないので手で生成する
  (§2.2)。`authorizedKeys` は本体ユーザーの鍵を流用)
- `boot.initrd.systemd.network.networks."99-ethernet-default-dhcp"` を
  **自前で宣言している**。`networking.networkmanager.enable = true` が
  `networking.useDHCP` を false にし、それに連動して nixpkgs 由来の
  同名デフォルトが initrd 側から消えるため(実測)。
  **この宣言を消すと、ドライバが入っていてリンクが上がっても IP が来ず、
  §5 の遠隔復旧が死ぬ。** 外形は NIC ドライバ欠落と同じなので切り分けを誤る。
  `flake/checks.nix` の `boot-contract` がこの宣言の存在と中身を固定している。
- `fileSystems."/".options = [ "x-systemd.device-timeout=infinity" ];`
- `hosts/jupiter/disko.nix` の
  `disko.devices.disk.main.content.partitions.luks.content.settings.crypttabExtraOpts`
  `= [ "tpm2-device=auto" ];`(TPM2 自動解錠の取得口。無いと登録しても
  起動時にパスフレーズを聞かれる)
宣言できない(このマシン固有の秘密や、ファームウェア／NVRAM の状態そのものに
依存するため)ので手で打つ必要があるもの:

- Secure Boot の鍵の生成(`sbctl create-keys`)。`/var/lib/sbctl` に生成され、
  この公開リポジトリにはコミットしない。
- initrd SSH のホストキー生成(`ssh-keygen`。§2.2)。`hostKeys` の絶対パスと
  ファイル名を一字一句一致させる必要がある。
- セットアップモードへの出入り(ファームウェア／NVRAM の操作)。
- 鍵の登録(`sbctl enroll-keys --microsoft`)。
- Secure Boot の有効化そのもの(ファームウェア／NVRAM の操作)。
- LUKS2 ボリュームへの TPM2 登録(`systemd-cryptenroll`)。
- (§7。現在未対応)`systemd-pcrlock make-policy` と
  `systemd-cryptenroll --tpm2-pcrlock=...`。

## 2. フェーズ A: 鍵の生成 → Secure Boot 有効化 → LUKS2 ボリュームへの TPM2 登録

**NixOS 初期インストール手順書を完了した場合、§2.1・§2.2・§2.3 は
実行しない。** 鍵は既に存在し、Lanzaboote も `nixos-install` の時点で
適用済みである。§2.5 は条件付きで、既にセットアップモードなら飛ばす。
この状態で §2.1 を実行すると
`sbctl create-keys` が既存鍵に対してどう振る舞うかは未確認であり、§2.2 の
`ssh-keygen -f` は既存ファイルに対して `Overwrite (y/n)?` と対話で聞いて
くる(この手順書の他の手順は非対話実行を前提にしている)。§5.2 の照合に
使うフィンガープリントは、初期インストール手順書 §2.4 で控えたものを使う。

以下の §2.1〜§2.3 は、**既に NixOS が動いているマシンに後から lanzaboote を
導入する場合**の手順である。

### 2.1 鍵の生成

`sbctl` は PATH に無いので `nix run` で呼ぶ。

```
sudo nix run nixpkgs#sbctl -- create-keys
sudo nix run nixpkgs#sbctl -- status
```

`/var/lib/sbctl/keys/{PK,KEK,db}/*.{key,pem}` が生成され、`status` は
`Setup Mode: Disabled`(まだ Setup Mode ではない)と出る。

### 2.2 initrd SSH ホスト鍵の生成

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

後で §5.2 の照合に使うため、公開鍵のフィンガープリントをここで控えておく。
(`/var/lib` は暗号化された `/` の上にあり、initrd で足止めされている状況
では未マウントのため、そのときに取りに行くことはできない。)

```
ssh-keygen -lf /var/lib/initrd-ssh/ssh_host_ed25519_key.pub
```

### 2.3 `nixos-rebuild switch` で lanzaboote を適用する

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

### 2.4 ヘッドレス VM でパスフレーズを入力する方法(VM リハーサル専用の付録)

**この節は VM リハーサル専用の手順。実機ではコンソールから直接パスフレーズ
を打てばよく、この節のスキャンコード操作は使わない。** 別のパスフレーズを
使う場合にスキャンコード列をどう組むかはここには書かない(実際に組んで
動作を確かめていないため)。組む必要が生じたら、実際に動かして確認した
上で書き足すこと。

以降の節(§2.5, §4.1 など)で `startvm --type headless` で起動した VM に
LUKS パスフレーズを入力する必要が複数回出てくる。ヘッドレスなので通常の
コンソール入力はできず、`VBoxManage controlvm <vm> keyboardputscancode` で
スキャンコード列を直接送る。

```bash
VB="/c/Program Files/Oracle/VirtualBox/VBoxManage.exe"
VM='<VM 名>'
"$VB" showvminfo "$VM" --machinereadable
"$VB" controlvm "$VM" keyboardputscancode <hex...>
```

スキャンコードは PS/2 keyboard scan code set 1 で、1 キーにつき「押す
(make code)」と「離す(break code。make code に `0x80` を加えた値)」の
2 バイトを送る。実測で使ったパスフレーズ `rehearsal` + Enter に対応する列
(r e h e a r s a l + Enter とデコードして確認済み、動作確認済み):

```
13 93 12 92 23 a3 12 92 1e 9e 13 93 1f 9f 1e 9e 26 a6 1c 9c
```

### 2.5 セットアップモードに入る

**ここだけ VM と実機で手順が違う。**

NVRAM を変更する前に、現在の状態を確認する。

```bash
sudo nix run nixpkgs#sbctl -- status
```

`Setup Mode: Enabled` なら、PK のクリアと VM の `inituefivarstore` を実行せず
§2.6 へ進む。`Setup Mode: Disabled` の場合だけ、以下の環境別手順を実行する。
想定と違う場合は停止する。

VM では `modifynvram <vm> inituefivarstore` を使う。UEFI 変数ストアを初期化する
操作で、実行後に `sbctl status` が `Setup Mode: Enabled` を返すことを確認した。
**登録済みの PK／KEK／db もこれで消える。**

副次的に、既にインストール済みの VM で実行した直後はインストーラーの ISO から
起動した(それ以前は ISO を入れても既存ディスクへフォールバックしていた)。
**EFI のブートエントリが消えたことが理由かどうかは未確認。** ISO から起動させたい
だけなら `modifyvm <vm> --boot1 dvd` を先に試すこと。

`modifynvram <vm> enrollorclpk` は使わない。コマンド名は「Oracle の PK を
登録する」と読め、字面からはセットアップモードを**抜ける**操作に見える。
**実行して確かめていない。**

VM:

```bash
VB="/c/Program Files/Oracle/VirtualBox/VBoxManage.exe"
VM='<VM 名>'
"$VB" showvminfo "$VM" --machinereadable
```

ここで停止し、Name と UUID が対象 VM と一致することを確認する。
確認後、同じ Bash セッションで電源停止を要求する。

```bash
"$VB" controlvm "$VM" acpipowerbutton
```

`VMState="poweroff"` になるまで待つ。次のブロックは変数が残っている同じ
Bash セッションで実行する。poweroff でなければ停止する。

```bash
if test -n "${VB:-}" && test -n "${VM:-}" && test "$("$VB" showvminfo "$VM" --machinereadable | sed -n 's/^VMState="\(.*\)"$/\1/p')" = poweroff; then
  "$VB" modifynvram "$VM" inituefivarstore
  "$VB" startvm "$VM" --type headless
else
  echo 'VM target or state is invalid; stopped' >&2
  false
fi
```

`inituefivarstore` は対象 VM の PK、KEK、db、ブートエントリーを消去する。

起動後、§2.4 の方法で LUKS のパスフレーズを入力してログインできる状態に
する。

実機: ファームウェア(UEFI)のセットアップメニューから Secure Boot の設定に入り、
既存の PK をクリアしてセットアップモードに切り替える。**具体的なメニュー操作は
ファームウェアベンダー依存であり未確認。**

確認(共通):

```
sudo nix run nixpkgs#sbctl -- status
```

`Setup Mode: Enabled` を確認してから次に進む。`sbctl` の `✗`/`✓` 記号は
見た目が反転して見えることがあるので、記号ではなく後続の文字列
(`Enabled`/`Disabled`)を読むこと。**想定と違ったら、先に進まずに止まる
こと。**

### 2.6 鍵を登録する

```
sudo nix run nixpkgs#sbctl -- enroll-keys --microsoft
```

`--microsoft` は省略できない。省略すると Microsoft の option ROM 検証鍵が
入らず、環境によっては起動しなくなる。

`--microsoft` は、Jupiter の鍵に加えて Microsoft の鍵が許可する UEFI
コンポーネントも信頼する。PCR 7 は Secure Boot の有効状態と PK、KEK、db、dbx
などのポリシー変数を測るが、実際にどの許可済みコンポーネントを起動したかは示さない。

確認は **`sbctl status` の `Setup Mode` を当てにしない。** 実機(2026-08-22)では
`enroll-keys` が成功して `Vendor Keys: microsoft` になった後も、`Setup Mode` は
`Enabled` のままだった。EFI 変数を直接見ると PK は書けている。

```bash
bash -c 'for v in PK KEK db; do f=$(ls /sys/firmware/efi/efivars/${v}-* 2>/dev/null | head -1); echo "$v: $(stat -c%s "$f" 2>/dev/null || echo 変数なし) bytes"; done'
```

期待: PK / KEK / db がいずれも数百バイト以上で存在すること(実機の実測値は
PK 1258 / KEK 4332 / db 8895)。**`SetupMode` が 1 のままでも、PK が非空なら
§2.7 へ進んでよい。** このファームウェアは Secure Boot を有効化する時点で
セットアップモードを解除する。

`shishi` のログインシェルは fish なので、上のような変数代入を含むブロックを
`ssh <target> '...'` に直接渡すと fish が解釈して失敗する。
`ssh <target> 'bash -s' < script` の形で渡す。

### 2.7 Secure Boot を有効化する

**鍵を登録してから有効化する。** 有効化すると PCR 7(secure-boot-policy)の値が
変わるため、§3 の TPM2 登録は必ずこの後に行う。

VM:

```bash
VB="/c/Program Files/Oracle/VirtualBox/VBoxManage.exe"
VM='<VM 名>'
"$VB" showvminfo "$VM" --machinereadable
```

ここで停止し、Name と UUID が対象 VM と一致することを確認する。
確認後、同じ Bash セッションで電源停止を要求する。

```bash
"$VB" controlvm "$VM" acpipowerbutton
```

`VMState="poweroff"` になるまで待つ。次のブロックは変数が残っている同じ
Bash セッションで実行する。poweroff でなければ停止する。

```bash
if test -n "${VB:-}" && test -n "${VM:-}" && test "$("$VB" showvminfo "$VM" --machinereadable | sed -n 's/^VMState="\(.*\)"$/\1/p')" = poweroff; then
  "$VB" modifynvram "$VM" listvars
  "$VB" modifynvram "$VM" queryvar --name=PK
else
  echo 'VM target or state is invalid; stopped' >&2
  false
fi
```

ここで停止し、PK エントリが空でないことを確認する。確認後、同じ Bash
セッションで Secure Boot を有効化する。

```bash
"$VB" modifynvram "$VM" secureboot --enable
"$VB" startvm "$VM" --type headless
```

ホスト側 NVRAM ストアへの反映には遅延があるため、`enroll-keys` の直後に
間を置かず `secureboot --enable` を呼ぶと
`Secure boot is not available because the platform key (PK) is not enrolled`
で失敗することがある。`listvars`/`queryvar --name=PK` で PK の実在を確認
してから有効化すること。`modifynvram <vm> secureboot` は引数無しでは使えず、
`--enable`/`--disable` の指定が必須(クエリ用途には使えない)。

実機: ファームウェア設定で Secure Boot を有効に切り替える(**未確認**、ファームウェア依存)。

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

## 3. LUKS2 ボリュームに TPM2 を登録する(PCR 7)

### 3.1 `--tpm2-pcrs=7` を省略できない理由

systemd 258 で `systemd-cryptenroll` の既定 PCR 集合が「PCR なし」に変わった
(jupiter の systemd は 261)。**省略すると、何にも縛られない TPM2 鍵がその
まま追加される。** 解錠は成功し続けるので、Secure Boot の状態が変わっても
検出できない。必ず `--tpm2-pcrs=7` を明示する。

PCR 7 が測るのは Secure Boot の有効状態と PK、KEK、db、dbx などのポリシー変数である。
起動したブートローダーは PCR 4、UKI のカーネルと initrd は PCR 11 に測られる。
フェーズ A は PCR 4 と PCR 11 に縛らないため、特定のブートローダーや UKI を
固定する構成ではない。改変によって署名が無効になった実行ファイルは Secure Boot が
拒否するが、登録済みの信頼鍵が許可する別の実行ファイルまでは PCR 7 で区別しない。
この制限を縮めるフェーズ B は §7 で扱う。

### 3.2 実行順序

§2.7 のとおり Secure Boot の有効化で PCR 7 の値が変わる。TPM2 の登録を先に
行うと、その後の有効化で登録した内容が無効(解錠できない)ポリシーに
なる。**Secure Boot 有効化 → TPM2 登録の順を守る。**

### 3.3 TPM2 を LUKS2 ボリュームに登録する

LUKS2 は新規の鍵スロットの追加時にも既存の資格情報での認証を要求するため、
非対話 SSH で標準入力の無いまま実行すると、既存パスフレーズの入力待ちで
無期限にハングする。`--unlock-key-file=/dev/stdin` で現在のパスフレーズを
渡す。

管理用 age 鍵で `secrets/bootstrap.yaml` を復号し、`jq` が抽出した LUKS 値だけを
標準入力で送る。コマンドライン、画面、永続ファイルには出さない。
ワークステーション側の nix-config チェックアウトで、`sops` と `jq` が使える
開発シェルから実行する。

```bash
set -o pipefail
SOPS_AGE_KEY_FILE=secrets/management-age-key.txt sops --decrypt --output-type json secrets/bootstrap.yaml | jq -jer '."luks-passphrase"' | ssh <target> 'sudo systemd-cryptenroll --unlock-key-file=/dev/stdin --tpm2-device=auto --tpm2-pcrs=7 /dev/disk/by-partlabel/disk-main-luks'
```

`sudo` は NOPASSWD(`nixos/sudo.nix`)なので標準入力を奪わない。奪う設定に
変えると、パスフレーズが sudo に食われて TPM2 登録処理が既存鍵の入力待ちでハングする。

（`disk-main-luks` は `hosts/jupiter/disko.nix` の `disko.devices.disk.main` と
パーティション `luks` から disko の命名規則で決まるパーティションラベルで、実機でも
同名になる。）

期待: `New TPM2 token enrolled as key slot 1.`

### 3.4 封印の検証

`cryptsetup luksDump` は `cryptsetup 2.8.6` では `Keyslot: N` の 1 行しか
出さず、`tpm2-pcrs` 等の詳細を表示しない。生のトークン JSON を見る。

まず `luksDump` でトークン一覧を確認し、`systemd-tpm2` トークンの ID を確定
する(§3.5 の削除 → 再登録を経るとトークン番号がずれることがあるため、
`0` を決め打ちしない)。

```
sudo cryptsetup luksDump /dev/disk/by-partlabel/disk-main-luks
```

`Tokens:` セクションに出ている ID(以下 `<N>`)を使って、生のトークン JSON を
見る。

```
sudo cryptsetup token export --token-id=<N> /dev/disk/by-partlabel/disk-main-luks
```

期待(該当部分): `"tpm2-pcrs":[7]` と `"tpm2-pcr-bank":"sha256"`。

**`tpm2-primary-alg` は見ない。** VM では `"ecc"`、実機(Minisforum V3 / 2026-08-22)
では `"rsa"` になった。`systemd-cryptenroll` が TPM の対応に合わせて選ぶ値で、
封印が PCR 7 に縛られているかとは無関係。ここを期待値に含めると、正しく登録
できているのに失敗と判断して §3.5 の削除 → 再登録をやり直すことになる。

### 3.5 削除と登録は別コマンドに分ける

既存の TPM2 鍵スロットを同じ PCR セットのまま再登録しようとすると、
`This PCR set is already enrolled, executing no operation.` と出て黙って
何も起きないことがある。PCR セットを変える、または壊れた登録を
作り直すときは、`--wipe-slot=tpm2` で既存の TPM2 鍵スロットを消すコマンドと、
新規に登録するコマンドを分けて実行する。

```bash
ssh <target> 'sudo systemd-cryptenroll --wipe-slot=tpm2 /dev/disk/by-partlabel/disk-main-luks'
set -o pipefail
SOPS_AGE_KEY_FILE=secrets/management-age-key.txt sops --decrypt --output-type json secrets/bootstrap.yaml | jq -jer '."luks-passphrase"' | ssh <target> 'sudo systemd-cryptenroll --unlock-key-file=/dev/stdin --tpm2-device=auto --tpm2-pcrs=7 /dev/disk/by-partlabel/disk-main-luks'
```

**削除した状態で再起動すると initrd の解錠待ちになる。** そこを抜けるには
§5 の initrd SSH でパスフレーズを入れる必要がある。管理用 age 鍵と
`secrets/bootstrap.yaml` の両方を復旧可能な状態にしてから削除する。

**この 2 コマンド構成を VM で通した。** `--wipe-slot=tpm2` の直後に
`luksDump` の `Tokens:` が空になり、再起動すると initrd で解錠待ちになる。
initrd SSH で解錠して起動したあと `--tpm2-device=auto --tpm2-pcrs=7` で
登録し直すと `0: systemd-tpm2` が戻る。

## 4. 動作確認

### 4.1 リセット後の自動解錠

電源断相当のリセット後、スキャンコードを一切送らずに SSH をポーリングして
到達すれば、自動解錠が成立している。パスフレーズの入力は不要。
(「スキャンコード」は §2.4 で説明する、`VBoxManage controlvm ... keyboardputscancode`
で送るキー入力のこと。ここで送らずに到達する、
という意味。)

### 4.2 カーネル更新後も自動解錠が維持されるか

`nixos-rebuild switch` でカーネルを更新し、再起動して §4.1 と同様に確認する。
`cryptsetup token export` の `"tpm2-pcrs":[7]` はカーネル更新後も維持される。

**既知の制限**: カーネル更新後の再起動が、TPM 関連の初期化
(`Starting Early TPM SRK Setup...`)の段階でハングする場合がある(LUKS の
パスフレーズ入力プロンプトにすら到達しない停止であり、TPM2/PCR7 の
登録自体の問題ではない)。原因は特定できていない。長時間(10 分程度)
応答が無い場合はハードリセットして再試行すること。**それでも同じ箇所で
ハングする場合は、この手順書が想定していない別の原因を疑うこと。**

## 5. 復旧手順(initrd SSH)

### 5.0 先に確認すること: USB イーサネットアダプタが挿さっているか

**この機体に有線 LAN ポートは無く、initrd に無線は入れていない。**
USB イーサネットアダプタが挿さっていなければ、initrd 側の遠隔復旧は
**存在しない** — 物理コンソールへ行くしかない。ドライバーやネットワーク定義の
切り分けに入る前に、まずアダプタの装着を確認すること。

### 5.1 前提: NIC ドライバーが無いと復旧経路自体が機能しない

initrd でネットワークが使えるには、NIC ドライバーが initrd に含まれている
必要がある。無いと NIC が検出されず `systemd-networkd` は loopback しか
上げない。

**「到達不能」の見え方は環境によって違う。**

- **VM(VirtualBox NAT)では、TCP は確立するのに SSH バナーが一切返ら
  ない。** VirtualBox の NAT はホスト側で TCP 接続を受け付けてからゲストへ
  転送する実装のため、ゲストに IP が無く誰も待ち受けていなくても、
  ホスト側からの接続自体は成立して見える。実測(2026-08-21、VM でこの
  状態を再現)では 75〜90 秒程度で `Connection reset by peer` になった。
- **実機で NIC ドライバーが欠けている場合はこれと異なる。** NAT のように
  中間で接続を受け付けないため、リンクが上がっていない NIC への到達は ARP
  解決自体が失敗し、接続拒否かタイムアウトになると考えられる(**未確認**。
  実機でこの状態を実測してはいない)。

読むのは TPM 解錠に失敗して遠隔から入れない最中であることが多い。VM の
症状(TCP 確立・バナー無し)を実機でも同じものだと思って切り分けを進めると
誤る。§1 の `boot.initrd.availableKernelModules` と実機の NIC ドライバーが
一致していることが、この節全体の前提になる。

### 5.2 接続方法

```
ssh -tt -p <port> root@<host>
```

- **`root@` で入る。** `shishi@` では `Permission denied (publickey)` になる。
  initrd の `AuthorizedKeysFile` は `/etc/ssh/authorized_keys.d/root` のみで、
  `boot.initrd.network.ssh.authorizedKeys` は initrd に単一しか存在しない
  root ユーザーの authorized_keys として展開される。
- **`-tt`(`RequestTTY=force`)が要る。** 無いと公開鍵認証は成功するが、
  `command="systemctl default"` が疑似端末なしで実行されるためパスフレーズの
  プロンプトがどこにも出力されず、接続がハングしたまま応答しなくなる。
- **ポート**: initrd の sshd はゲスト側の 2222 番ポートで待ち受ける。本体 sshd
  (ゲスト側の 22 番ポート)とは別なので、ホスト側の到達経路(NAT/ファイアウォール)は
  本体 sshd 用の転送とは別に用意する必要がある。VM では
  `host:2223 → guest:2222` の NAT 規則を使った。**実機でこのポートに
  どう到達するかは環境依存であり未確認。**
- ホスト鍵のフィンガープリントで「本体 sshd ではなく initrd sshd に
  繋がっているか」を判別できる。**`/var/lib/initrd-ssh/ssh_host_ed25519_key.pub`
  は暗号化された `/`(btrfs `@root`)の上にあり、initrd で足止めされている
  状況ではまだマウントされていない。** そこへ読みに行くには、解錠したい
  その当のマシンにログインする必要が生じてしまう(循環)。代わりに §2.2
  (初回インストールでは初期インストール手順書 §2.4)で控えた
  フィンガープリントを使い、`ssh-keyscan -p <port> <host> | ssh-keygen -lf -` の結果と比較する。

### 5.3 パスフレーズ投入

管理用 age 鍵で `secrets/bootstrap.yaml` を復号し、`jq` が抽出した LUKS 値だけをパイプへ流す。
画面へ表示せず、永続ファイルにも保存しない。ワークステーション側の nix-config
チェックアウトで、`sops` と `jq` が使える開発シェルから実行する。

```bash
set -o pipefail
SOPS_AGE_KEY_FILE=secrets/management-age-key.txt sops --decrypt --output-type json secrets/bootstrap.yaml | jq -jer '."luks-passphrase" + "\n"' | { cat; sleep 90; } | timeout 150 ssh -tt -p <port> root@<host>
```

`sleep 90` は、プロンプトが出るより先に標準入力が閉じて ssh が終了するのを
防ぐため。`-tt` は擬似端末を強制する指定で、これが無いと
`systemd-tty-ask-password-agent` がプロンプトを出さない。

次のプロンプトが出力される。

```
🔐 Please enter passphrase for disk disk-main-luks (cryptroot): (press TAB for no echo)
```

投入後、`Connection to <host> closed.`(終了コード 0)で切断されるのは
`switch-root`(ルート切り替え)によって initrd の sshd が停止したことによる正常終了であり、
異常ではない。

### 5.4 `x-systemd.device-timeout=infinity` の効果

`fileSystems."/".options` に設定済み。initrd SSH が最初から機能せず、
コンソールから手動でパスフレーズを入れるまで長時間待たされる状況でも、
パスフレーズのプロンプトは崩れず、cryptsetup 関連のユニットがタイムアウトで
失敗することはない。

### 5.5 VM のハングとの切り分け

起動中に SSH が応答しない場合、単純な起動の遅さなのか VM 自体が完全に
ハングしているのかを切り分ける必要がある。数秒間隔でコンソールの
スクリーンショットを 2 枚取り、バイトサイズが完全に同一であればハングと
判定できる(`Ctrl+Alt+F3` 相当のキー入力に画面が無反応なら判定を補強できる)。
ハングと判定したら VM をリセットする。VM 環境固有の既知事象であり、
TPM2／Secure Boot の登録自体の欠陥ではない。**実機でこの種のハングが
起きるかは未確認。**

## 6. Secure Boot ポリシー変更後は TPM2 を再登録する

Secure Boot の有効状態または PK、KEK、db、dbx を変更すると PCR 7 の値が変わる。
既存の PCR 7 に縛った登録では解錠できなくなるため、変更前に §5 の復旧経路を
準備する。変更後はパスフレーズで起動し、§3.5 の手順で TPM2 を登録し直す。

lanzaboote の再インストールや `nixos-rebuild switch`／`boot` でブートローダーや
UKI の内容だけが変わる場合、その計測先は PCR 7 ではなく PCR 4 または PCR 11 である。
フェーズ A は PCR 4 と PCR 11 に縛らないため、その変更だけを理由に TPM2 を
再登録する必要はない。ただし、起動経路を変更した後の動作確認として §4 の
自動解錠確認は実行する。

## 7. フェーズ B(`systemd-pcrlock`)— 現在は未対応

VM の仮想 TPM + OVMF では `systemd-pcrlock` が機能する前提を満たせず、
`hosts/jupiter/default.nix` にフェーズ B を有効化する宣言はコミットして
いない(属性パスは実機で有効化する際に確定する。`flake/checks.nix` の
契約検査も同様に未追加)。

### 7.1 実機で試すときに最初に確認すること

**`systemd-pcrlock is-supported` が `yes` を返すことは十分条件ではない。**
正しい前提条件は「イベントログの再生が実際の PCR 値を再現すること」で、
これは `make-policy` を実行して保護マスクを読むまで分からない。
VM では `is-supported` が `yes` を返しながら実際には使えなかった。実機で
試すときは次の順で確認する。

1. `systemd-pcrlock` は PATH に無いのでフルパスで呼ぶ
   (`/run/current-system/sw/lib/systemd/systemd-pcrlock`)。
   `sudo <フルパス> is-supported` で `yes` を確認する(必要条件だが十分
   条件ではない)。
2. `sudo <フルパス> make-policy --recovery-pin=show` を実行し、標準出力の
   `PCRs dropped from protection mask:`／`PCRs in protection mask:` を
   確認する。宣言したい PCR(0、4、7 など)が除外側に出た場合、実機の
   イベントログ実装に VM と同じ制約がある。

   VM での除外理由: `lock-firmware-code`(PCR 0)／
   `lock-secureboot-authority`(PCR 7)という「現在の状態を無条件に確定
   する」コマンドすら `Event log ... does not match PCR state, refusing`
   で失敗した。個々のイベントは認識されている
   (`allEventsMatched: true`)のに、それらを連結して計算した最終ダイジェスト
   が実際のレジスタ値と一致しない(`hashMatchesEventLog: false`)という、
   vTPM 自身の自己矛盾だった。実機の物理 TPM でこの制約が無いかは未確認。
3. ウォームリブート(`systemctl reboot`)と、電源断相当のリセットの両方で
   `make-policy` を再実行し、結果が変わらないか確認する。結果が同じで
   あれば、リブート方式の違いではなく TPM/ファームウェアの実装そのものの
   限界であると判断できる。
4. 除外が無ければ TPM2 登録(§3.5 相当。`--tpm2-pcrlock=/var/lib/systemd/pcrlock.json`
   を指定する形)に進んでよい。除外があれば、フェーズ B の効果が「値の
   変わらない PCR(13／14／15 など)だけを保護する登録」に縮退し、
   「カーネル更新に追従する」という中核目的を検証できないので、登録に
   進む前に判断をユーザーへ戻すこと。

復旧用 PIN は `make-policy --recovery-pin=show` の実行時に標準出力へ
表示される。既定の `hide`(`pcrlock.json` に暗号化保存)は、ポリシーが古く
なった時点で取り出せなくなるため使わない。

### 7.2 復旧用 PIN の保管方針

**PIN そのものは本手順書を含むこのリポジトリのどこにも書かない。** 取得できた
PIN はユーザー本人がオフラインの秘密管理手段に控える。このリポジトリは公開されて
いるため、PIN・パスフレーズ・秘密鍵はいかなる形式でもコミットしない。

### 7.3 無効化の順序(未確認)

以下はフェーズ B を実際に登録していないため未確認。実機でフェーズ B を
成立させた後に無効化するときの参考手順として記載する。

想定している順序:

1. `sudo systemd-cryptenroll --wipe-slot=tpm2 /dev/disk/by-partlabel/disk-main-luks`
2. フェーズ B を有効化した際に `hosts/jupiter/default.nix` に追加した宣言を
   戻して `nixos-rebuild switch`(属性パスは有効化した時点で記録すること)
3. `sudo <systemd-pcrlockのフルパス> remove-policy`

逆順(特に 3 を先に実行する場合)の挙動は未確認。pcrlock ポリシーを先に
消すと鍵スロットの検証対象(`PolicyAuthorizeNV` が指す NV インデックスの内容)が
失われ、締め出される可能性があると考えているが、実機で確認するまで
保証はない。

## 8. コマンドの既知の制限

| コマンド | 制限 |
|---|---|
| `sbctl <verb>` | PATH に無い。`nix run nixpkgs#sbctl -- <verb>` を使う |
| `systemd-pcrlock <verb>` | PATH に無い。`/run/current-system/sw/lib/systemd/systemd-pcrlock` をフルパスで呼ぶ |
| `systemd-pcrlock has-tpm2` | systemd 261 にこのサブコマンドは存在しない。TPM の実在は `/dev/tpm0`・`/dev/tpmrm0` で見る |
| `systemd-pcrlock log --json=short \| grep -c PATTERN` | 1 行 JSON なので `grep -c` は常に 0 か 1 になる。`grep -o PATTERN \| wc -l` で出現回数を数える |
| `VBoxManage showvminfo ... \| grep -i tpm` | 要素名は `TrustedPlatformModule`。`tpm` という文字列を含まないため拾えない |
| `VBoxManage modifynvram <vm> secureboot`(引数無し) | クエリ用途には使えない。`--enable`/`--disable` の指定が必須 |
| `VBoxManage modifynvram <vm> queryvar PK` | `--name=PK` の指定が必須 |
| `cryptsetup luksDump` | `cryptsetup 2.8.6` では `tpm2-pcrs` 等の詳細を表示しない。`cryptsetup token export --token-id=N` で生 JSON を見る |
| 同一 PCR セットでの再 `systemd-cryptenroll` | `This PCR set is already enrolled, executing no operation.` で黙って何もしないことがある。削除と登録を分ける |
| initrd SSH に `shishi@` で接続 | `Permission denied (publickey)`。initrd では `root@` のみ |
| initrd SSH に `-tt` を付けない | 公開鍵認証は成功するがプロンプトが出ず無応答のままハングする |
