{ ... }:
let
  # bash 用 alias 定義。fish 側は dotfiles の config.fish(abbr)が正
  aliases = {
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
in
{
  programs.bash = {
    enable = true;
    initExtra = ''
      if [[ ! "$PATH" =~ "$HOME/.local/bin" ]]; then
        export PATH="$HOME/.local/bin:$PATH"
      fi
    '';
    shellAliases = aliases;
  };

  # fish への env/alias 供給は行わない(2026-08-11 撤去)。
  # dotfiles の config.fish が abbr(23 個)・EDITOR(nvim-edit)・LESS・PAGER を
  # 既に所有しており、供給ファイルは重複どころかリッチな設定を素朴な値で
  # 後から上書きして劣化させていた(実測)。NH_FLAKE も dotfiles 直書きへ移管済み。
  # fish 側の PATH / env / alias の正は dotfiles(#8(b) の完全形)
}
