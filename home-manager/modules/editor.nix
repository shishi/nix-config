{ config, pkgs, ... }:

{
  programs.neovim = {
    enable = true;
    # defaultEditor = trueの効果：
    # 1. EDITOR環境変数を"nvim"に設定
    # 2. gitやlessなどがデフォルトでneovimを使用
    # 3. systemctl editなどのコマンドでも使用される
    defaultEditor = true;

    # エイリアスの設定
    viAlias = true; # vi → nvim
    vimAlias = true; # vim → nvim
  };

  # defaultEditor = true の具体的な効果：
  # home.sessionVariables = {
  #   EDITOR = "nvim";
  #   VISUAL = "nvim";
  # };
  # と同等の設定が自動的に行われる
}
