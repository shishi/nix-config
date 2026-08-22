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
# **前提が変わっている(2026-08-22)。リモート認証は SSH 鍵のみではない。**
# jupiter は RDP(krdpserver)を LAN と Tailscale の範囲へ公開しており、そこは
# shishi のシステムパスワードで PAM 認証する。RDP で入ればデスクトップに立てて、
# そこから `sudo` はパスワード不要 —— つまり **ネットワークからパスワード 1 つで
# root** の経路が存在する。
#
# ssh.nix がパスワード認証を切っているのは依然として正しいが、それだけでは
# この前提を守れない。守っているのは、RDP の到達範囲を送信元で絞っていること
# (hosts/jupiter/default.nix の networking.firewall.extraCommands)と、
# PAM と TLS だけである。
#
# **攻撃面を再評価するならここから始める。** 選択肢は 3 つで、どれも副作用がある。
# (a) 現状維持。パスワードの強度に全体が依存する
# (b) sudo にパスワードを要求する。nh の非対話経路と runbook §4 の
#     systemd-cryptenroll(標準入力でパスフレーズを渡す)が壊れる
# (c) RDP をやめて SSH トンネルへ戻す
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
