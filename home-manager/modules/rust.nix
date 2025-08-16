{
  config,
  pkgs,
  lib,
  ...
}:

{
  home.packages = with pkgs; [
    # Fenixを使用してRustツールチェインをインストール
    # 具体的なバージョン指定も可能:
    # - fenix.stable: 最新の安定版（例: 1.75.0）
    # - fenix.latest: 最新のnightly
    # - fenix.toolchainOf { channel = "1.74.0"; }: 特定バージョン
    (fenix.stable.withComponents [
      "cargo"
      "clippy"
      "rust-src"
      "rustc"
      "rustfmt"
      "rust-std"
    ])

    # クロスコンパイル用のターゲット
    # Linux
    fenix.targets.x86_64-unknown-linux-gnu.stable.rust-std
    fenix.targets.aarch64-unknown-linux-gnu.stable.rust-std

    # macOS
    fenix.targets.x86_64-apple-darwin.stable.rust-std
    fenix.targets.aarch64-apple-darwin.stable.rust-std

    # Windows
    fenix.targets.x86_64-pc-windows-gnu.stable.rust-std
    fenix.targets.x86_64-pc-windows-msvc.stable.rust-std

    # Rust開発用の追加ツール
    rust-analyzer # LSP server
    cargo-watch # ファイル変更監視
    cargo-edit # cargo add/rm/upgrade
    cargo-outdated # 古い依存関係の検出
    cargo-audit # セキュリティ監査
    cargo-deny # ライセンスとセキュリティチェック
    cargo-expand # マクロ展開
    cargo-bloat # バイナリサイズ分析

    # ビルド高速化
    sccache # コンパイルキャッシュ
    mold # 高速リンカー

    # デバッグツール
    gdb # GNU debugger
    lldb # LLVM debugger
  ];

  # Cargo設定
  home.file.".cargo/config.toml".text = ''
    [build]
    # sccacheを使用してビルドを高速化
    rustc-wrapper = "${pkgs.sccache}/bin/sccache"

    [target.x86_64-unknown-linux-gnu]
    linker = "clang"
    rustflags = ["-C", "link-arg=-fuse-ld=${pkgs.mold}/bin/mold"]

    [target.aarch64-unknown-linux-gnu]
    linker = "clang"
    rustflags = ["-C", "link-arg=-fuse-ld=${pkgs.mold}/bin/mold"]

    [target.x86_64-apple-darwin]
    linker = "cc"
    # macOSではmoldは使用不可、代わりにlldを使用可能
    # rustflags = ["-C", "link-arg=-fuse-ld=lld"]

    [target.aarch64-apple-darwin]
    linker = "cc"
    # macOSではmoldは使用不可、代わりにlldを使用可能
    # rustflags = ["-C", "link-arg=-fuse-ld=lld"]

    [target.x86_64-pc-windows-gnu]
    linker = "x86_64-w64-mingw32-gcc"
    # Windowsクロスコンパイルではデフォルトのリンカーを使用

    # 並列ビルドの設定
    jobs = 8

    # エイリアス
    [alias]
    c = "check"
    t = "test"
    r = "run"
    rr = "run --release"
    b = "build"
    br = "build --release"
  '';

  # 環境変数
  home.sessionVariables = {
    CARGO_HOME = "$HOME/.cargo";
    RUSTUP_HOME = "$HOME/.rustup";
    # sccacheの設定
    SCCACHE_CACHE_SIZE = "10G";
    SCCACHE_DIR = "$HOME/.cache/sccache";
  };
}
