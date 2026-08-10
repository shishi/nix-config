{
  config,
  pkgs,
  lib,
  ...
}:
let
  toolsJson = builtins.toJSON config.my.rust.cargoTools;
  rustBootstrap = pkgs.writeShellApplication {
    name = "rust-bootstrap";
    runtimeInputs = with pkgs; [
      rustup
      cargo-binstall
      jq
      coreutils
      util-linux
      gnugrep
      bash
      fish # login shell 解決検証(activation の最小 PATH でも動くように)
    ];
    text = ''
      export RUST_BOOTSTRAP_TOOLS='${toolsJson}'
      export RUST_BOOTSTRAP_SHELL='${config.my.shell}'
      ${builtins.readFile ../../scripts/rust-bootstrap.sh}
    '';
  };
in
{
  home.packages = with pkgs; [
    rustup
    cargo-binstall
    sccache
    mold
    rustBootstrap # nix run 用に PATH にも置く(flake app は Task 13)
  ];

  # PATH 順序契約: nix profile → ~/.cargo/bin(v12 裁定)。
  # fish の実効 PATH は dotfiles 所有(#8(b))のため、ここは bash 系 +
  # hm-session-vars 向けの宣言のみ。準拠は check-env が検証する。
  home.sessionPath = [ "$HOME/.cargo/bin" ];

  # sccache + mold(native のみ)+ alias。クロスターゲットと jobs 固定は
  # #20 裁定で削除(必要なプロジェクトが devshell で個別設定する)
  home.file.".cargo/config.toml".text = ''
    [build]
    rustc-wrapper = "${pkgs.sccache}/bin/sccache"

    [target.x86_64-unknown-linux-gnu]
    linker = "clang"
    rustflags = ["-C", "link-arg=-fuse-ld=${pkgs.mold}/bin/mold"]

    [alias]
    c = "check"
    t = "test"
    r = "run"
    rr = "run --release"
    b = "build"
    br = "build --release"
  '';

  home.sessionVariables = {
    SCCACHE_CACHE_SIZE = "10G";
    SCCACHE_DIR = "$HOME/.cache/sccache";
  };

  # 自動経路(加算のみ・非致命)。破壊的修復は手動 --repair 限定
  home.activation.rustBootstrap = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    ${rustBootstrap}/bin/rust-bootstrap --auto || true
  '';
}
