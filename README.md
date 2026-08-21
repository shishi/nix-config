# nix-config

flake-parts + home-manager による個人用 Nix 設定。
WSL Ubuntu(standalone HM)/ NixOS 実機 jupiter / NixOS-WSL(スケルトン)。

## 構成

- `home/` … 可搬レイヤー(全ホスト共有の home-manager モジュール)
- `nixos/` … NixOS 専用レイヤー(system 設定)
- `hosts/` … マシンごとの束ね(フラグ値はここだけ)
- `shared/` … 層をまたぐ純データ(キャッシュ定義)

## WSL Ubuntu(earth)

前提: 標準パス `~/dev/src/github.com/shishi/nix-config` に clone。
非 Nix 前提は `hosts/ubuntu-wsl/README.md`(check-env が機械検証)。

```bash
nix run .#setup-sudo-nopasswd
nix run .#setup-trusted-user
nix run .#install-system-packages
nix run .#check-env            # 前提の機械検証
nix run .#switch               # 適用(check-env-critical 内蔵。--force で省略)
```

適用経路は `switch` 一本(直接 activation + 適用記録)。素の `nh home switch` は
契約検査を迂回するため非公認(シェル所有権が dotfiles にある間)。
恒久の明示経路: `nix run home-manager -- switch --flake ~/dev/src/github.com/shishi/nix-config#shishi`

## NixOS 実機(jupiter)

インストールは nixos-anywhere + disko。手順は
[docs/jupiter-secure-boot-runbook.md](docs/jupiter-secure-boot-runbook.md) に
一本化してある。**ここにコマンドを写さない**(片方だけ古くなる)。

- **未インストールの実機への初回インストールは runbook §2 のゲート 4 に従う。**
  `nix run .#nixos-anywhere -- --flake .#jupiter root@<target>` を素で打つと、
  disko がディスクを消去・暗号化した後のブートローダ設置段で失敗する
  (`boot.lanzaboote` と initrd SSH の host key が、まだ存在しない鍵を要求するため)
- SSH 秘密鍵と GPG 秘密鍵は、インストール時に `--extra-files` で置く(ゲート 4 手順 0b)
- TPM2 自動解錠は runbook §4。**`--tpm2-pcrs=7` を省略しない。** systemd 258 以降
  `--tpm2-device=auto` の既定 PCR 集合は空で、省略すると何にも縛られない鍵が入る。
  解錠は成功し続けるので気づけない
- インストール前に firmware で Secure Boot を無効にする。installer の ISO は
  署名されていないため、有効なままだと起動しない

初回起動後: 標準パスへ clone → dotfiles の `setup.sh` を実行 → `nh os switch` が
動くことを確認(post-install 成功基準)。
以後の更新: `nh os switch`(NixOS 側 programs.nh が NH_FLAKE を設定)

## 更新

```bash
nix run .#update   # worktree でアトミック更新 → update/<date> ブランチに残る
# earth で適用成功後: git merge --ff-only update/<date>
```

## Rust

toolchain は rustup 委譲(stable + nightly)。ツールは cargo-binstall で存在保証。

```bash
nix run .#rust-bootstrap              # 状態確認 + 不足の導入
nix run .#rust-bootstrap -- --repair  # 破壊的修復(壊れたバイナリの再導入・撤去)
```

## テンプレート

```bash
nix flake new -t .#basic my-project
nix flake new -t .#rust my-rust-project
```
