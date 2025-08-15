# Personal Nix Configuration

個人用のNix設定（flake-parts + home-manager）

## セットアップ

```bash
# Home Manager設定の適用
nix run home-manager/master -- switch --flake .#shishi@ubuntu

# 開発シェルに入る
nix develop
```

## 構成

- `home-manager/`: ユーザー環境設定
- `lib/`: 共通ユーティリティ（将来用）
- `modules/`: flake-partsモジュール
- `overlays/`: パッケージカスタマイズ
- `pkgs/`: カスタムパッケージ
- `shells/`: 開発環境定義

## 複数マシン対応

将来的に複数マシンに対応する場合：
1. flake.nixのhomeConfigurationsに新しいエントリを追加
2. ホスト固有の設定をhome-manager/hosts/に分離
3. 共通設定をモジュール化