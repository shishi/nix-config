# shishi の SSH 公開鍵。**公開鍵なので public repo に置いてよい**
# (github.com/shishi.keys で既に公開されている)。秘密鍵は置かない。
#
# ここを唯一の真実にする。書き写した先が増えると、鍵を差し替えたときに
# 片方だけ直して自分を締め出す。導出先:
#   - nixos/users.nix       本体 sshd のログイン鍵
#   - hosts/jupiter         initrd SSH(command= を足して map する)
#   - hosts/installer       installer ISO の root ログイン鍵
#
# 空リストにすると flake/checks.nix の boot-contract が
# initrd.ssh.authorizedKeys.nonEmpty で落ちる(鍵を空にして実測済み)。
#
# **その検出が効くのは jupiter の initrd 経路を通る場合だけ。** checks の
# contract はすべて nixosConfigurations.jupiter を起点にしているので、
# hosts/installer の root 鍵は無検査である。あちらの import 行を消す変更は
# nix flake check を緑のまま通る。
#
# それでも installer 用の check を足していないのは、壊れ方が「新規インストール
# のときに root への ssh が拒否される」で、実機の前に立った時点で即座に分かる
# ため。復旧中に静かに効かない類の欠陥ではない。
[
  "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILarf1PUuzo6XLQNwnOf2IZeyCqXGxgNdrSJUjgbp/94"
]
