# SSH の認証は鍵のみ。openssh を有効にしていないホストでは何も起きない。
#
# sudo.nix で shishi の sudo をパスワード不要にしたため、パスワードで SSH に
# 入れる経路が残っていると「22 番へ到達 + パスワード」だけで root になれてしまう。
# users.nix の initialPassword は固定の既知文字列で、初回ログイン後に passwd を
# 実行するまで有効なまま残る(VM リハーサルで実測: passwd -S が P を返した)。
# 鍵認証を唯一の入口にしてこの前提を強制する。
#
# パスワードはコンソールログインの退避手段としては残る(物理アクセス限定)。
{ ... }:
{
  services.openssh.settings = {
    PasswordAuthentication = false;
    KbdInteractiveAuthentication = false;
  };
}
