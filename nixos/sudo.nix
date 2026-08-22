# sudo のパスワード省略。対象は shishi のみで、wheel 全体には広げない。
#
# 動機: nh は root 実行を拒否し内部で sudo へ昇格するため、パスワードが要ると
# 対話端末が必要になる。TTY の無い経路(ssh の非対話実行、自動化)では
# 「sudo: a terminal is required to read the password」で activation が止まる
# (VM リハーサルで実測)。jupiter はサーバー運用するのでこの経路を塞ぐ。
#
# security.sudo.wheelNeedsPassword = false は wheel 全員に効くため使わない。
# 現状 wheel は shishi だけだが、将来ユーザーを足したときに黙って権限が
# 広がるのを避ける。earth では scripts/setup-sudo-nopasswd.sh が同じ状態を
# 作っており、NixOS 側はその宣言的な対応物にあたる。
#
# 前提: リモートからの認証は SSH 鍵のみ。これは ssh.nix が強制する
# (パスワード認証を残したままここを緩めると、shishi のパスワードを知る相手が
# 追加認証なしに root になれる)。
{ ... }:
{
  security.sudo.extraRules = [
    {
      users = [ "shishi" ];
      commands = [
        {
          command = "ALL";
          options = [ "NOPASSWD" ];
        }
      ];
    }
  ];
}
