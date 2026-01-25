{
  config,
  pkgs,
  lib,
  myLib,
  # nixpkgs-ruby,
  ...
}:

{
  home.packages =
    with pkgs;
    [
      fish
      ripgrep
      fd
      bat
      eza
      zoxide
      curl
      wget
      bottom
      jq
      yq
      deno
      zip
      unzip
      unar
      p7zip
      git
      gnupg
      luajit
      pass
      xclip
      xsel
      vim
      neovim
      rclone
      pkg-config
      wezterm
      nil
      nixd
      less
      nixfmt
      _1password-cli
      tailscale
      uv
      emacs
      gnomeExtensions.clipboard-indicator
      gh
      nix-output-monitor

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
    ++ lib.optionals myLib.hasGui (
      with pkgs;
      [
        _1password-gui
        firefox
        google-chrome
        microsoft-edge
        vscode
        slack
        discord
        vlc
        gnome-screenshot
        flameshot
        teamviewer
        tailscale-systray
        guake
      ]
    );
}
