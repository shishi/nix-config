{ lib, pkgs }:

rec {
  # OSごとの条件分岐
  # 使用例: myLib.osCase { linux = "firefox"; darwin = "Safari"; }
  osCase =
    {
      linux ? null,
      darwin ? null,
      default ? null,
    }:
    if pkgs.stdenv.isLinux then
      linux
    else if pkgs.stdenv.isDarwin then
      darwin
    else
      default;

  # GUI環境の検出
  # 使用例:
  #   home.packages = []
  #     ++ lib.optionals (myLib.hasGui { inherit pkgs lib; }) [ firefox vlc ]
  #     ++ lib.optionals (!myLib.hasGui { inherit pkgs lib; }) [ lynx ];
  hasGui =
    { pkgs, lib }:
    let
      # 環境変数でGUI環境を検出
      hasDisplay = builtins.getEnv "DISPLAY" != "";
      hasWayland = builtins.getEnv "WAYLAND_DISPLAY" != "";

      # macOSは常にGUI環境として扱う
      isDarwin = pkgs.stdenv.isDarwin;

      # SSHセッションかどうかを確認
      isSSH = builtins.getEnv "SSH_CONNECTION" != "";

      # WSL環境の検出とGUIサポートの確認
      isWSL = builtins.pathExists "/proc/sys/fs/binfmt_misc/WSLInterop";
      hasWSLDisplay = isWSL && (hasDisplay || hasWayland);
    in
    # macOSまたは、SSHでない環境でディスプレイが利用可能な場合はGUI環境
    isDarwin || (!isSSH && (hasDisplay || hasWayland || hasWSLDisplay));

  # プラットフォーム別のパッケージ選択
  # 使用例:
  #   home.packages = with pkgs; [
  #     (myLib.platformPackage {
  #       inherit pkgs lib;
  #       gui = firefox;
  #       cli = lynx;
  #     })
  #   ];
  platformPackage =
    {
      pkgs,
      lib,
      gui,
      cli,
    }:
    if hasGui { inherit pkgs lib; } then gui else cli;

  # GUI/CLI環境に応じた設定の選択
  # 使用例:
  #   programs.git.extraConfig = myLib.guiCliConfig {
  #     inherit pkgs lib;
  #     gui = { core.editor = "code --wait"; };
  #     cli = { core.editor = "nvim"; };
  #   };
  guiCliConfig =
    {
      pkgs,
      lib,
      gui,
      cli,
    }:
    if hasGui { inherit pkgs lib; } then gui else cli;

  # 開発言語の検出（プロジェクトファイルベース）
  # 使用例:
  #   let
  #     langs = myLib.detectLanguages ./.;
  #   in {
  #     home.packages = []
  #       ++ lib.optionals langs.rust [ rustc cargo ]
  #       ++ lib.optionals langs.node [ nodejs ];
  #   };
  detectLanguages = dir: {
    rust = builtins.pathExists "${dir}/Cargo.toml";
    node = builtins.pathExists "${dir}/package.json";
    python =
      builtins.pathExists "${dir}/pyproject.toml" || builtins.pathExists "${dir}/requirements.txt";
    go = builtins.pathExists "${dir}/go.mod";
  };

  # カラースキーム（Gruvbox Dark）
  # 使用例:
  #   programs.alacritty.settings.colors = {
  #     primary = {
  #       background = myLib.colors.base16.base00;
  #       foreground = myLib.colors.base16.base05;
  #     };
  #     normal = {
  #       black = myLib.colors.base16.base00;
  #       red = myLib.colors.base16.base08;
  #       # ... 他の色
  #     };
  #   };
  colors = {
    base16 = {
      base00 = "#282828"; # background
      base01 = "#3c3836"; # lighter background
      base02 = "#504945"; # selection background
      base03 = "#665c54"; # comments
      base04 = "#bdae93"; # dark foreground
      base05 = "#d5c4a1"; # foreground
      base06 = "#ebdbb2"; # light foreground
      base07 = "#fbf1c7"; # white
      base08 = "#fb4934"; # red
      base09 = "#fe8019"; # orange
      base0A = "#fabd2f"; # yellow
      base0B = "#b8bb26"; # green
      base0C = "#8ec07c"; # cyan
      base0D = "#83a598"; # blue
      base0E = "#d3869b"; # purple
      base0F = "#d65d0e"; # brown
    };
  };
}
