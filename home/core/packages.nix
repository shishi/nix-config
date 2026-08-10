{ pkgs, ... }:
{
  home.packages = with pkgs; [
    _1password-cli
    bat
    bottom
    curl
    deno
    emacs
    eza
    fd
    fish
    fish-lsp
    gh
    git
    git-wt
    gnupg
    jq
    less
    llm-agents.claude-code
    llm-agents.codex
    lua-language-server
    luajit
    neovim # neovim-nightly-overlay 経由
    p7zip
    pass
    pkg-config
    pyright
    rclone
    ripgrep
    tailscale
    typescript-language-server
    unar
    unzip
    uv
    vim
    wget
    xclip
    xsel
    yq
    zip
    zoxide

    # デバッガ
    gdb
    lldb

    # fonts
    noto-fonts
    noto-fonts-cjk-sans
    noto-fonts-cjk-serif
    noto-fonts-color-emoji
    udev-gothic
    udev-gothic-nf

    # 言語ランタイム
    ruby_3_4
    nodejs_24
    python314
    go
    clang

    # DB
    mysql84
    libmysqlclient
    postgresql
    postgresql.dev
    sqlite
    sqlite.dev
  ];
}
