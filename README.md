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
非 Nix 前提は `hosts/ubuntu-wsl/README.md`(preflight が機械検証)。

```bash
nix run .#setup-sudo-nopasswd
nix run .#setup-trusted-user
nix run .#install-system-packages
nix run .#preflight            # 前提の機械検証
nix run .#switch               # 適用(preflight-critical 内蔵。--force で省略)
```

適用経路は `switch` 一本(直接 activation + 適用記録)。素の `nh home switch` は
契約検査を迂回するため非公認(シェル所有権が dotfiles にある間)。
恒久の明示経路: `nix run home-manager -- switch --flake ~/dev/src/github.com/shishi/nix-config#shishi`

## NixOS 実機(jupiter)

インストールは nixos-anywhere + disko。インストール前ゲート(スペック参照)を
全部通してから:

```bash
nix run .#nixos-anywhere -- --flake .#jupiter root@<target-ip>
```

初回起動後: 標準パスへ clone → `nh os switch` が動くことを確認(post-install 成功基準)。
TPM2 自動解錠: `sudo systemd-cryptenroll --tpm2-device=auto /dev/nvme0n1p2`
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
