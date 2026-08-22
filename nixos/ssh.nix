# SSH の認証は鍵のみ。openssh を有効にしていないホストでは何も起きない。
#
# sudo.nix で shishi の sudo をパスワード不要にしたため、パスワードで SSH に
# 入れる経路が残っていると「22 番へ到達 + パスワード」だけで root になれてしまう。
# users.nix はパスワードを宣言しない。必要なホストだけが
# users.users.shishi.hashedPasswordFile でインストール時に配る。
# その値を知る相手にネットワーク越しの入口を与えないため、鍵認証を唯一の
# 入口にする。
#
# コンソールログインの退避手段は、ハッシュを配ったホストにしか無い。
# 配っていないホストで**新規に作られた**ユーザーは shadow が `!` になる。
# 既にインストール済みの機体には旧パスワードが残る(users.nix 参照)。
{ ... }:
{
  services.openssh.settings = {
    PasswordAuthentication = false;
    KbdInteractiveAuthentication = false;
  };
}
