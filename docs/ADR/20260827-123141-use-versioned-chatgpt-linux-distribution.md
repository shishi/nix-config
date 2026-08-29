# バージョンを固定した ChatGPT Linux 配布物を使用する

| | |
|---|---|
| **状態** | 承認済み |
| **日付** | 2026-08-27 |
| **決定者** | shishi |
| **相談先** | なし |
| **共有先** | なし |

## 背景と課題

以前の Nix ラッパーは、固定したコンテンツハッシュと OpenAI の可変な
ChatGPT Desktop 用 `/latest/` URL を組み合わせていました。OpenAI が新しい
パッケージを公開すると、既存のロックは新しい内容を古いハッシュで取得します。
そのため、無関係な flake 更新までビルドと検証ができなくなっていました。

## 判断基準

* コミット済みの flake ロックが同じ上流成果物を取得し続けること
* パッケージ化の前に OpenAI パッケージの出所と完全性を確認すること
* ローカルのパッケージフォークを保守せずに ChatGPT Desktop を NixOS で実行できること
* コミュニティー固有の機能は、用途を確認して明示的に採用したものだけ有効にすること

## 検討した選択肢

1. 公式パッケージのバージョンを固定する `ilysenko/codex-desktop-linux` を使用する
2. `poeck/chatgpt-desktop-app-nix-flake` を維持し、`/latest/` の更新ごとにハッシュを更新する
3. 公式 Linux パッケージ用の derivation をこのリポジトリで保守する

## 決定

**採用:** `ilysenko/codex-desktop-linux` を使用します。この配布物は署名済みの
OpenAI APT メタデータからバージョン付きパッケージのパスを解決するため、OpenAI が
新しいバージョンを公開しても古いロックを維持できます。Home Manager モジュールが
NixOS 固有の実行環境への統合も担います。

Computer Use UI と、日常利用で用途を確認した `automation-extensions`、
`directory-only-working-tree-watch`、`node-repl-reaper`、
`project-group-last-updated-sort`、`tray-usage` を有効にします。ほかの任意機能は、
必要性と副作用を確認するまで無効のままにします。

Computer Use の実行要件も NixOS と Home Manager で宣言します。KDE 環境では、
Plasma の NixOS モジュールが KWin、Assistive Technology Service Provider
Interface（AT-SPI）、XDG Desktop Portal、KDE 用 Portal バックエンドとその経路設定、
dconf を提供します。Computer Use 固有の要件として PipeWire と WirePlumber を追加し、
Electron のアクセシビリティーツリーを有効にする toolkit accessibility を dconf へ
永続化します。

### 影響

**良い影響:**

* OpenAI のリリースで既存のパッケージ URL とハッシュの組が無効にならない
* パッケージの検出時に、署名済み APT メタデータと選択したパッケージのハッシュを検証できる
* NixOS 固有の ELF とサンドボックスへの対応を上流で保守できる

**悪い影響:**

* アプリケーションが、以前より大きな第三者配布物とそのリリース手順に依存する
* 配布物が Nix 固有のアプリケーションパッチと独自ランチャーを使用する
* 更新時に、以前の最小ラッパーより広い上流差分をレビューする必要がある
* 有効にした任意機能について、上流更新時に挙動と権限の変化を確認する必要がある

**中立的な影響:**

* コマンドとデスクトップエントリーが `chatgpt` と `chatgpt.desktop` から
  `codex-desktop` と `codex-desktop.desktop` に変わる

### 確認方法

flake の `chatgpt-desktop-contract` 検査では、パッケージがバージョン付きの
リポジトリ URL を使用すること、Computer Use UI と承認済みの任意機能だけが
有効であることを確認します。コミュニティーへの利用状況送信が無効であること、
パッケージを `--diagnose` 付きで実行すると成功することも確認します。さらに、KDE
タスクバーが新しいデスクトップエントリーを使うことを確認します。

合成 KDE 構成と Jupiter の評価で NixOS モジュールの依存グラフを確認します。
Jupiter のシステムビルドと切り替えが成功すれば、統合全体を確認できます。

## 各選択肢の比較

### `ilysenko/codex-desktop-linux` を使用する

* 利点: バージョン付きパッケージ URL により、ロックの再現性を維持できる
* 利点: 署名済みリポジトリメタデータとパッケージハッシュを検証できる
* 利点: プロジェクトが NixOS 固有の実行時動作をテストしている
* 欠点: ラッパーと任意機能の枠組みにより、信頼するコードの範囲が広がる

### `poeck/chatgpt-desktop-app-nix-flake` を維持する

* 利点: Nix のパッケージ化コードが小さく、レビューしやすい
* 欠点: 可変な `/latest/` URL により、上流のリリース後は古い固定出力 derivation が失敗する
* 欠点: 対応するラッパーの更新を待つ間、検証対象の全 flake 更新が止まり得る

### ローカルの derivation を保守する

* 利点: パッケージ方針と更新時期をこのリポジトリだけで制御できる
* 欠点: パッケージの検出、出所の確認、ELF 対応、継続的な互換性対応をこのリポジトリで保守する必要がある

## 参考資料

* [OpenAI ChatGPT Desktop for Linux](https://learn.chatgpt.com/docs/linux/linux-app)
* [codex-desktop-linux Nix documentation](https://github.com/ilysenko/codex-desktop-linux/blob/main/docs/nix.md)
