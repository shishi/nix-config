# 新規マシンの設営忘れ対策。人間の記憶に頼らず、未設営の間だけ対話シェルの
# 起動ごとに「次に打つコマンド」を表示する。設営が進むと案内が変わり、
# 完了すると何も出ない。
#
# NixOS レイヤに置く理由: nixos-anywhere が焼いた時点から存在するため、
# dotfiles 配備・bootstrap 実行より前に動ける(fish の user config は
# dotfiles 所有だが、これは /etc 側の init なので所有権と衝突しない)。
# 判定はファイル存在のみ(シェル起動ごとに走るため、ネットワークを伴う
# 検査は置かない)。
{ ... }:
{
  environment.interactiveShellInit = ''
    if [ "$(id -u)" != "0" ]; then
      if [ ! -e "$HOME/dev/src/github.com/shishi/nix-config/.git" ] || [ ! -e "$HOME/dev/src/github.com/shishi/dotfiles/.git" ]; then
        echo "[未設営] nix run github:shishi/nix-config#bootstrap を実行すること"
      elif [ ! -f "$HOME/.ssh/id_ed25519" ]; then
        echo "[鍵未持込] install -d -m 700 ~/.ssh && scp earth:.ssh/id_ed25519 ~/.ssh/id_ed25519 && chmod 600 ~/.ssh/id_ed25519"
      fi
    fi
  '';
}
