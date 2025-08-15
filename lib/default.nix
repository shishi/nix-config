{ lib, pkgs }:

rec {
  # OSごとの条件分岐
  # 使用例: myLib.osCase { linux = "firefox"; darwin = "Safari"; }
  osCase = { linux ? null, darwin ? null, default ? null }:
    if pkgs.stdenv.isLinux then linux
    else if pkgs.stdenv.isDarwin then darwin
    else default;

  # ホームディレクトリの動的解決
  # 使用例: "${myLib.homeDir "shishi"}/Documents"
  homeDir = username: osCase {
    linux = "/home/${username}";
    darwin = "/Users/${username}";
  };

  # XDG準拠のディレクトリパス
  # 使用例: 
  #   xdg.configFile."app/config.toml".text = "...";
  #   xdg.dataFile."app/data.db".source = ./data.db;
  mkXdgPaths = username: {
    configHome = "${homeDir username}/.config";
    dataHome = "${homeDir username}/.local/share";
    cacheHome = "${homeDir username}/.cache";
    stateHome = "${homeDir username}/.local/state";
  };

  # dotfilesリポジトリとの統合
  # 使用例:
  #   programs.git.extraConfig = myLib.importDotfile "shishi" "git/config.local";
  #   programs.zsh.initExtra = myLib.importDotfile "shishi" "zsh/aliases.zsh";
  importDotfile = username: path: 
    let dotfilesPath = "${homeDir username}/dotfiles/${path}";
    in if builtins.pathExists dotfilesPath
       then builtins.readFile dotfilesPath
       else "";

  # 複数のソースから設定をマージ（後の設定が優先）
  # 使用例:
  #   programs.git.extraConfig = myLib.mergeConfigs [
  #     (import ./git-defaults.nix)
  #     (import ./git-work.nix)  
  #     { user.email = "personal@example.com"; }
  #   ];
  mergeConfigs = configs:
    lib.fold (a: b: lib.recursiveUpdate b a) {} configs;

  # 設定の条件付き有効化
  # 使用例:
  #   imports = [
  #     (myLib.enableIf config.services.docker.enable ./docker-tools.nix)
  #     (myLib.enableIf (builtins.pathExists ./work.nix) ./work.nix)
  #   ];
  enableIf = condition: config:
    if condition then config else {};

  # シークレットファイルの安全な読み込み
  # 使用例:
  #   programs.git.extraConfig.user.signingkey = 
  #     myLib.readSecretFile "shishi" "gpg-key.txt" "default-key";
  readSecretFile = username: path: default:
    let secretPath = "${homeDir username}/.secrets/${path}";
    in if builtins.pathExists secretPath
       then lib.removeSuffix "\n" (builtins.readFile secretPath)
       else default;

  # フォントの標準設定
  # 使用例:
  #   programs.alacritty.settings.font = {
  #     normal.family = myLib.fonts.monospace;
  #     size = 12;
  #   };
  #   programs.vscode.userSettings."editor.fontFamily" = myLib.fonts.monospace;
  fonts = {
    monospace = osCase {
      linux = "JetBrains Mono";
      darwin = "SF Mono";
      default = "monospace";
    };
    ui = osCase {
      linux = "Inter";
      darwin = "SF Pro Display";
      default = "sans-serif";
    };
  };

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
    python = builtins.pathExists "${dir}/pyproject.toml" || 
             builtins.pathExists "${dir}/requirements.txt";
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

  # 一般的なaliasセット
  # 使用例:
  #   programs.bash.shellAliases = myLib.commonAliases // {
  #     myalias = "mycommand";
  #   };
  commonAliases = {
    ll = "ls -la";
    la = "ls -A";
    l = "ls -CF";
    
    # Git
    g = "git";
    gs = "git status";
    ga = "git add";
    gc = "git commit";
    gp = "git push";
    gl = "git pull";
    gd = "git diff";
    
    # 安全なコマンド
    rm = "rm -i";
    cp = "cp -i";
    mv = "mv -i";
    
    # その他便利なalias
    ".." = "cd ..";
    "..." = "cd ../..";
    mkdir = "mkdir -p";
  };

  # Gitの一般的な設定
  # 使用例:
  #   programs.git = {
  #     enable = true;
  #     extraConfig = myLib.gitConfig.enhanced // {
  #       user.email = "my@email.com";
  #     };
  #   };
  gitConfig = {
    minimal = {
      init.defaultBranch = "main";
      core.editor = "nvim";
    };
    
    enhanced = mergeConfigs [
      gitConfig.minimal
      {
        pull.rebase = true;
        fetch.prune = true;
        diff.colorMoved = "zebra";
        merge.conflictStyle = "diff3";
        rebase.autoStash = true;
        core.autocrlf = "input";
      }
    ];
  };
}