# shishi の SSH 公開鍵。**公開鍵なので public repo に置いてよい**
# (github.com/shishi.keys で既に公開されている)。秘密鍵は置かない。
#
# ここを唯一の真実にする。書き写した先が増えると、鍵を差し替えたときに
# 片方だけ直して自分を締め出す。導出先:
#   - nixos/users.nix       本体 sshd のログイン鍵
#   - hosts/jupiter         initrd SSH(command= を足して map する)
#
# 空リストにすると flake/checks.nix の boot-contract が
# initrd.ssh.authorizedKeys.nonEmpty で落ちる(鍵を空にして実測済み)。
[
  "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILarf1PUuzo6XLQNwnOf2IZeyCqXGxgNdrSJUjgbp/94"
]
