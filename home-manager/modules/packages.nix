{
  config,
  pkgs,
  lib,
  ...
}:

{
  home.packages =
    with pkgs;
    [
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
      neovim
      nix-output-monitor
      nix-search-cli
      nix-update
      nixd
      nixfmt
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
      wezterm
      wget
      xclip
      xsel
      yq
      zip
      zoxide

      # fonts
      noto-fonts
      noto-fonts-cjk-sans
      noto-fonts-cjk-serif
      noto-fonts-color-emoji
      udev-gothic
      udev-gothic-nf

      # 言語
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
    ]
    ++ lib.optionals config.myConfig.hasGui (
      with pkgs;
      [
        _1password-gui
        discord
        firefox
        flameshot
        gnome-screenshot
        gnomeExtensions.clipboard-indicator
        google-chrome
        guake
        microsoft-edge
        slack
        tailscale-systray
        teamviewer
        vlc
        vscode
      ]
    );
}
