{ pkgs, inputs, ... }:
{
  home.packages = with pkgs; [
    _1password-cli
    bat
    bottom
    bun
    curl
    deno
    emacs
    eza
    fd
    fish
    fish-lsp
    fzf
    gh
    git
    git-wt
    gitleaks
    gnupg
    jq
    less
    llm-agents.claude-code
    llm-agents.codex
    llm-agents.herdr
    lua-language-server
    luajit
    neovim # neovim-nightly-overlay 経由
    p7zip
    pass
    ghq
    pkg-config
    pyright
    rclone
    ripgrep
    tailscale
    tree-sitter
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
    # ruby はプロジェクト側(.ruby-version 追従)と供給元を揃えるため nixpkgs-ruby から。
    # "ruby-3.4" は 3.4 系の最新パッチを指す(旧 pkgs.ruby_3_4 と同じ粒度)
    inputs.nixpkgs-ruby.packages.${pkgs.stdenv.hostPlatform.system}."ruby-3.4"
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
