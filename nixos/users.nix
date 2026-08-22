# パスワードはここで宣言しない。この repo は public なので、固定の文字列を
# 書くと「誰でも知っているパスワードが passwd を実行するまで有効」になる。
# 初回ログイン手段は下の authorizedKeys が担い、パスワードが要るホストは
# users.users.shishi.hashedPasswordFile を自分で宣言する。
#
# ssh.nix がパスワード認証を切っているのはこれとは別の理由(sudo NOPASSWD との
# 組み合わせ)なので、ここが変わってもあちらを戻してよいことにはならない。
#
# 鍵が唯一の入口になるので、鍵を空にする変更は止まらなければならない。
# NixOS の「wheel ユーザーにパスワードも鍵も無い」assertion は
# `!cfg.mutableUsers ->` で始まるため、mutableUsers = true のこの構成では
# 常に真で何も止めない。実際に止めているのは flake/checks.nix の
# boot-contract で、jupiter の initrd SSH 鍵がここから導出されるため
# ここを空にすると nonEmpty で落ちる(鍵を空にして実測)。
# **nixos-wsl 側にはこの守りが無い。**
#
# この変更は既にインストール済みのホストの /etc/shadow を書き換えない
# (mutableUsers = true では既存ユーザーの shadow を触らない)。旧
# initialPassword で構築済みの機体では、`sudo passwd shishi` を 1 回実行して
# 既知の文字列を捨てること。
{ pkgs, ... }:
{
  users.users.shishi = {
    isNormalUser = true;
    home = "/home/shishi";
    extraGroups = [
      "wheel"
      "networkmanager"
    ];
    shell = pkgs.fish;

    # 初回ログイン手段(無いと新規インストール機へ遠隔ログイン不能。
    # SSH はパスワード認証を切っているため。物理コンソールからは
    # hashedPasswordFile を宣言・搬入したホストに限りパスワードで入れる —
    # 無いまま新規インストールしたホストは shadow が `!` になりコンソールも
    # 不能。既存ホストで passwd 済みなら shadow は残る)。
    # 実体と導出先の一覧は shared/authorized-keys.nix にある。
    openssh.authorizedKeys.keys = import ../shared/authorized-keys.nix;
  };
  # login shell 登録に必要(/etc/shells)。ユーザー設定は dotfiles/HM 側
  programs.fish.enable = true;
}
