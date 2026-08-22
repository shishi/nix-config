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
# **リモート認証は SSH 鍵のみではない。**
# jupiter は RDP(krdpserver)を LAN と Tailscale の範囲へ公開しており、そこは
# shishi のシステムパスワードで PAM 認証する。RDP で入ればデスクトップに立てて、
# そこから `sudo` はパスワード不要 —— つまり **ネットワークからパスワード 1 つで
# root** の経路が存在する。
#
# ssh.nix はパスワード認証を切っているが、それだけではこの経路を塞げない。守っているのは、RDP の到達範囲を送信元で絞っていること
# (hosts/jupiter/default.nix の networking.firewall.extraCommands)と、
# PAM と TLS だけである。
#
# **攻撃面を再評価するならここから始める。** 選択肢は 4 つで、どれも副作用がある。
# (a) 現状維持。パスワードの強度に全体が依存する
# (b) sudo にパスワードを要求する。nh の非対話経路と runbook §4 の
#     systemd-cryptenroll(標準入力でパスフレーズを渡す)が壊れる
# (c) RDP の直接公開をやめて SSH トンネル(loopback bind + port forward)に切り替える
# (d) 生体認証 + SSH agent 認証に切り替える(採用していない。将来
#     効かせたくなったときの手順として残す):
#     1. 下の extraRules(shishi の NOPASSWD)を消す
#     2. jupiter は howdy(顔)と fprintd(指紋)が有効なので、ローカルの
#        sudo は顔か指紋で通るようになる。howdy は abort_if_ssh = true(既定)
#        なので SSH 経由の sudo で顔認証待ちは起きないが、fprintd は SSH から
#        でも指を待つ。リモートの体感が悪ければ
#        security.pam.services.sudo.fprintAuth = false にする
#     3. (b) の「nh の非対話経路が壊れる」への対処として
#        security.pam.sshAgentAuth.enable = true と
#        security.pam.services.sudo.sshAgentAuth = true を足すと、転送された
#        SSH agent の鍵で sudo が通る。対象は宣言済みの鍵だけ
#        (authorizedKeysFiles の既定は /etc/ssh/authorized_keys.d/%u で、
#        users.users.*.openssh.authorizedKeys から作られる。
#        ~/.ssh/authorized_keys への手動追記分は対象外)。
#        接続側に ssh -A(または ForwardAgent yes)が要る。agent 転送は
#        「接続元マシンの侵害 = sudo 可」を意味するので、その等価交換を
#        受け入れられる場合のみ
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
