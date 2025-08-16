{ config, pkgs, ... }:

{
  programs.bash = {
    enable = true;

    # ~/.local/binをPATHに追加
    initExtra = ''
      # Add ~/.local/bin to PATH
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

  # programs.fish = {
  #   enable = true;
  #   shellAbbrs = {
  #     # エディタ
  #     n = "nvim";

  #     # git関連
  #     g = "git";
  #     gs = "git status -sb";
  #     gco = "git checkout";
  #     gci = "git commit -m";
  #     gcia = "git commit --amend";
  #     gl = "git log --graph --decorate --name-status";
  #     gg = "git grep";
  #     gd = "git diff";
  #     ga = "git add";
  #     gb = "git branch";
  #     gP = "git push";
  #     gPf = "git push --force-with-lease";
  #     gPF = "git push --force";
  #     gp = "git pull";
  #     gr = "git rebase";
  #     grc = "git rebase --continue";
  #     gra = "git rebase --abort";
  #     gm = "git merge";
  #     gmc = "git merge --continue";
  #     gma = "git merge --abort";
  #     gcl = "git clean --force";
  #   };
  # };
}
