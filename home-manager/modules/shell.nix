# シェル設定とエイリアス
# 他のシェルを使う場合: programs.fish.enable / programs.zsh.enable を追加
{ config, pkgs, ... }:

{
  programs.bash = {
    enable = true;

    initExtra = ''
      if [[ ! "$PATH" =~ "$HOME/.local/bin" ]]; then
        export PATH="$HOME/.local/bin:$PATH"
      fi
    '';

    shellAliases = {
      ll = "ls -la";
      n = "nvim";
      g = "git";
      gs = "git status -sb";
      gco = "git checkout";
      gci = "git commit -m";
      gcia = "git commit --amend";
      gl = "git log --graph --decorate --name-status";
      gg = "git grep";
      gd = "git diff";
      ga = "git add";
      gb = "git branch";
      gP = "git push";
      gPf = "git push --force-with-lease";
      gPF = "git push --force";
      gp = "git pull";
      gr = "git rebase";
      grc = "git rebase --continue";
      gra = "git rebase --abort";
      gm = "git merge";
      gmc = "git merge --continue";
      gma = "git merge --abort";
      gcl = "git clean --force";
    };
  };

  # programs.zsh = {
  #   enable = true;
  #   enableAutosuggestions = true;
  #   enableCompletion = true;
  # };
}
