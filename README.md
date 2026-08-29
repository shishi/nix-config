# nix-config

flake-parts + home-manager による個人用 Nix 設定。
WSL Ubuntu(スタンドアロン Home Manager)／NixOS 実機 jupiter／NixOS-WSL(スケルトン)。

## 構成

- `home/` … 可搬レイヤー(全ホスト共有の home-manager モジュール)
- `nixos/` … NixOS 専用レイヤー(システム設定)
- `hosts/` … マシンごとの束ね(フラグ値はここだけ)
- `shared/` … 層をまたぐ純データ(キャッシュ定義・SSH 公開鍵)

## WSL Ubuntu(earth)

前提: 標準パス `~/dev/src/github.com/shishi/nix-config` にクローンする。
非 Nix 前提は `hosts/ubuntu-wsl/README.md`(check-env が機械検証)。

```bash
nix run .#setup-sudo-nopasswd
nix run .#setup-trusted-user
nix run .#install-system-packages
nix run .#check-env            # 前提の機械検証
nix run .#switch               # 適用(check-env-critical 内蔵。--force で省略)
```

適用経路は `switch` 一本(直接アクティベーション + 適用記録)。素の `nh home switch` は
契約検査を迂回するため非公認(シェル所有権が dotfiles にある間)。
恒久の明示経路: `nix run home-manager -- switch --flake ~/dev/src/github.com/shishi/nix-config#shishi`

## NixOS 実機(jupiter)

目的別の手順書を使う。README へコマンドを複製しない。

- [NixOS 初期インストール](docs/jupiter-install-runbook.md)
  - インストーラー、`disko`／`install` フェーズ、初回起動の確認
- [秘密情報の作成と更新](docs/jupiter-secrets-runbook.md)
  - SOPS、2 種類の age 鍵、SMB パスワード変更
- [Secure Boot／TPM2 自動解錠](docs/jupiter-secure-boot-runbook.md)
  - sbctl、PCR 7 への登録、initrd SSH 復旧、pcrlock

初回起動後の手順は 1 コマンドに畳んである。クローンには無認証 HTTPS を使う。
両リポジトリとも公開されているため、SSH 鍵の有無に関係なく実行できる。
鍵の状態は最後に案内が出る:

```
nix run github:shishi/nix-config#bootstrap
```

手動でやる場合の同等手順。**パスは `NH_FLAKE` が指す場所と一致していなければ
ならない**(`~/dev/src/github.com/shishi/nix-config`)。`ghq` 自体は宣言済みで
入っているが、ルート設定(gitconfig)は dotfiles のセットアップ前で未設定のため、
`ghq get` は既定の `~/ghq` にクローンしてパスがずれる。素の `git clone` を
そのパスに打つ。

```
ssh -o StrictHostKeyChecking=accept-new -T git@github.com   # ホスト鍵を受理する
mkdir -p ~/dev/src/github.com/shishi
git clone git@github.com:shishi/nix-config.git ~/dev/src/github.com/shishi/nix-config
git clone git@github.com:shishi/dotfiles.git   ~/dev/src/github.com/shishi/dotfiles
bash ~/dev/src/github.com/shishi/dotfiles/setup.sh
nh os switch
```

SSH(git@)でクローンする場合、最初の 1 行を省くと `git clone` がホスト鍵確認の
対話で止まる(新規マシンの `known_hosts` は空)。`setup.sh` 自身は内部で
`GIT_SSH_COMMAND` に `accept-new` を入れるが、それは `setup.sh` が始まってからの
話で、上の 2 つの `git clone` には効かない。

`nh os switch` が **`DIFF: 0 bytes`** を返せば、インストールされた世代と
リポジトリからビルドした結果が同一のストアパスである。これは構成と実機に
ずれがないことを示す、インストール後の成功基準である。以後の更新も `nh os switch`。

### 生体認証(顔・指紋)の登録

宣言(`hosts/jupiter/default.nix`)が入れるのは仕組みまで。顔モデルと指紋は
生体データなのでリポジトリに入れず、本人が実機の前で 1 回登録する。
再インストール後も同様にやり直す。顔認証は次の順で設定・確認する:

```
sudo linux-enable-ir-emitter configure   # IR エミッタの動作を確認する(対話)
sudo howdy add                           # 顔モデルを 1 件追加する(/var/lib/howdy/models)
sudo howdy -U shishi list                # 顔モデルの登録を確認する
sudo fprintd-enroll shishi               # 指紋を登録する(/var/lib/fprint)
fprintd-list shishi                      # 指紋の登録を確認する
```

`linux-enable-ir-emitter configure` が点滅を問い、`Yes` の後に
`The emitter is already working, skipping the configuration.` と出た場合、IR エミッタは
既に動作しているため追加設定は不要です。

`sudo howdy -U shishi test` はカメラ映像のプレビューです。顔照合の成否は確認しません。
顔認証は `Super+L` でロックして確認します。KDE は `Unlock` のクリックで
ロック解除の PAM 認証を開始します。Howdy は PAM 認証が
始まってからカメラを使うため、ロック直後に顔だけで自動解除はしません。顔が一致すると
その認証を通過して解除します。失敗時はパスワードで解除できます。

指紋の登録は `sudo fprintd-enroll shishi` を使います。通常の `fprintd-enroll` は
この構成では polkit に拒否されることがあります。

顔認証が通らない場合は、まず `sudo howdy -U shishi add` を追加で実行します。正面、
少し左、少し右などで複数のモデルを登録します。ロック時に
`Failure, not possible to open camera at configured path` と
`Failure, timeout reached` が続けて出る場合、この端末では顔照合の
タイムアウトでも
同じ表示を確認しています。このメッセージだけでカメラ故障とは判断しません。

効く先はロック画面(顔・指紋)と polkit の認証ダイアログ(顔・指紋)。
sudo には効かない(NOPASSWD が認証フェーズを飛ばす。効かせる手順は
`nixos/sudo.nix` の選択肢 (d))。

### リモートデスクトップ(RDP)

KRdp は動作中の Plasma セッションを RDP で共有する。`0.0.0.0:3389` で待ち受け、
ファイアウォールは `tailscale0` だけで 3389 番ポートを開ける。

**ポータル経路を使う。** `--plasma` だとクリップボードが両方向とも動かない(KRdp
6.7.4 の `PlasmaScreencastV1Session::setClipboardData` が空実装)。ポータルは既定で
接続のたびに画面上の許可を求めるが、`krdp-portal-permission.service` が
PermissionStore に事前許可を書くのでダイアログは出ない。**このユニットが無いと、
新規インストール直後は「RDP が無いとダイアログを押せない / 押さないと RDP が
使えない」で詰む。**

手元の RDP クライアントから
Jupiter の MagicDNS 名または Tailscale IP の 3389 番ポートへ直接繋ぐ。
ユーザー名は `shishi`、パスワードは
**shishi のシステムパスワード**。接続すると画面ロックが出るので、同じパスワードで
解除する。

**この口の先は PAM 認証で、その先は NOPASSWD の sudo。** 破られるとパスワード
1 つで root まで届く。そのため 3389 番ポートは Tailscale のインタフェースだけで
開ける。物理 LAN と接続先の AP からは直接到達できない。tailnet 内での到達主体は
Tailscale の通信ポリシーに従う。

Tailscale は `secrets/runtime.yaml` の `tailscale-oauth-secret` を使い、
`tag:jupiter` の永続ノードとして tailnet へ自動参加する。Tailscale SSH も
`tailscale set --ssh` で有効にする。Jupiter のシステムビルド前に OAuth クライアントを
発行し、`nix run .#init-secrets` でクライアントシークレットを登録する。既存の秘密情報は
空 Enter で維持し、値を入力した項目だけ更新する。
Tailscale SSH が扱うのは 22 番ポートで、RDP は Tailscale ネットワーク上の
3389 番ポートへ直接接続する。

**KWallet は自動では開かない。** `pam_kwallet` はログインパスワードから鍵を
導出するので、autoLogin では鍵が渡らない(セッション開始直後の `kwalletd6` は
バス上で起動可能な状態のまま)。KWallet を使うアプリは初回に開錠を求めてくる。

手元が Windows のとき、`localhost:3389` は Windows 自身の RDP サーバーを指す。
Jupiter へは**MagicDNS 名か Tailscale IP で**繋ぐこと。SSH トンネルを張る場合も、
手元側は 3389 を避ける。例えば
`ssh -N -L 13389:127.0.0.1:3389 shishi@<jupiter>` のように別のポートにする。

- セッションは autoLogin で常時上がっており、**開始時にロックが降りる**
  (`kscreenlocker.lockOnStartup`。掛けるのはロッカー自身で、自分の起動時に掛ける)。
  物理アクセスにもロック解除のパスワードが要る。krdpserver との起動順は
  制約していないので、セッション起動中のごく短い間はロック前の状態がありうる
- RDP 上でログアウトするとセッションごと krdpserver が落ちるが、SDDM が
  autoLogin をやり直すので自動で戻る(`sddm.autoLogin.relogin`)。ただし
  **セッションが異常終了した場合は戻らない** — SDDM はそこで止まるので、
  SSH から `sudo systemctl restart display-manager` で戻す
- 証明書は初回起動時に `~/.local/share/krdp/` へ自己署名で作られる。自己署名なので
  クライアントは証明書の警告を出す
- **RDP のパスワードは shishi のログインパスワードそのもの。** 出所は
  初回インストール時だけ `secrets/bootstrap.yaml` の暗号文からラッパーが生成・配送する
  ハッシュである。稼働後は Jupiter 上の `passwd` と暗号文を別々に同じ値へ更新する。
  `nixos/users.nix` はパスワードを宣言しない(公開リポジトリのため)。初回配送時に
  置き忘れると shadow が `!` になり、RDP もロック解除も通らない
- 音声・クリップボード・マルチモニタの挙動は未確認

## 更新

```bash
nix run .#update   # worktree でアトミック更新 → update/<date> ブランチに残る
# earth で適用成功後: git merge --ff-only update/<date>
```

## Rust

ツールチェーンは rustup に委譲する(stable + nightly)。ツールは cargo-binstall で存在保証。

```bash
nix run .#rust-bootstrap              # 状態確認 + 不足の導入
nix run .#rust-bootstrap -- --repair  # 破壊的修復(壊れたバイナリの再導入・撤去)
```

## テンプレート

```bash
nix flake new -t .#basic my-project
nix flake new -t .#rust my-rust-project
```
