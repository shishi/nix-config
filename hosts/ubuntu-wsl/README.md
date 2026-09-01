# ubuntu-wsl(earth)の非 Nix 前提

home/ の可搬性は以下のホスト側前提の上に成り立つ。check-env(`nix run .#check-env`)が機械検証する。

| 前提 | 所有者 | NixOS(jupiter)での対応物 |
|---|---|---|
| apt: build-essential, pkg-config | scripts/install-system-packages.sh | stdenv(不要) |
| Docker CE(unix socket のみ。TCP 公開はしない) | 同上 | hosts/jupiter/default.nix の virtualisation.docker.enable |
| locale ja_JP.UTF-8 | 同上 | nixos/locale.nix |
| fish が login shell(chsh) | 手動 | nixos/users.nix |
| fish の PATH 定義(nix profile → ~/.cargo/bin の順) | **dotfiles repo** | 同じ dotfiles を展開 |
| 日本語入力 | Windows 側 IME(WSL 内 fcitx5 は導入しない) | nixos/input-method.nix(fcitx5+skk) |
