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
#
# GitHub の host key はここで固定する。新規マシンの known_hosts は空なので、
# 素の `git clone git@github.com:...` が host key 確認の対話で止まる。初回起動
# 直後の nix-config / dotfiles の clone がまさにそれに当たり、非対話で流すと
# そこで詰む。dotfiles の setup.sh は内部で GIT_SSH_COMMAND に accept-new を
# 入れるが、それは setup.sh が始まってからの話で、その前の clone には効かない。
#
# accept-new(初回を無条件に受理)ではなく実鍵を書くのは、TOFU をやめるため。
# 値は ssh-keyscan で取り、GitHub が公開している指紋(https://api.github.com/meta
# の ssh_key_fingerprints)と 3 本とも一致することを確認した(2026-08-23):
#   RSA     SHA256:uNiVztksCsDhcc0u9e8BujQXVUpKZIDTMczCvj3tD2s
#   ECDSA   SHA256:p2QAMXNIC1TJYWeIOttrVc98/R1BUFWu3/LiyKgUfQM
#   ED25519 SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU
# GitHub が鍵を入れ替えたらここも入れ替える。そのときは clone が
# REMOTE HOST IDENTIFICATION HAS CHANGED で止まるので、黙って通ることはない。
{ ... }:
{
  services.openssh.settings = {
    PasswordAuthentication = false;
    KbdInteractiveAuthentication = false;
  };

  programs.ssh.knownHosts = {
    "github.com-rsa" = {
      hostNames = [ "github.com" ];
      publicKey = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCj7ndNxQowgcQnjshcLrqPEiiphnt+VTTvDP6mHBL9j1aNUkY4Ue1gvwnGLVlOhGeYrnZaMgRK6+PKCUXaDbC7qtbW8gIkhL7aGCsOr/C56SJMy/BCZfxd1nWzAOxSDPgVsmerOBYfNqltV9/hWCqBywINIR+5dIg6JTJ72pcEpEjcYgXkE2YEFXV1JHnsKgbLWNlhScqb2UmyRkQyytRLtL+38TGxkxCflmO+5Z8CSSNY7GidjMIZ7Q4zMjA2n1nGrlTDkzwDCsw+wqFPGQA179cnfGWOWRVruj16z6XyvxvjJwbz0wQZ75XK5tKSb7FNyeIEs4TT4jk+S4dhPeAUC5y+bDYirYgM4GC7uEnztnZyaVWQ7B381AK4Qdrwt51ZqExKbQpTUNn+EjqoTwvqNj4kqx5QUCI0ThS/YkOxJCXmPUWZbhjpCg56i+2aB6CmK2JGhn57K5mj0MNdBXA4/WnwH6XoPWJzK5Nyu2zB3nAZp+S5hpQs+p1vN1/wsjk=";
    };
    "github.com-ecdsa" = {
      hostNames = [ "github.com" ];
      publicKey = "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBEmKSENjQEezOmxkZMy7opKgwFB9nkt5YRrYMjNuG5N87uRgg6CLrbo5wAdT/y6v0mKV0U2w0WZ2YB/++Tpockg=";
    };
    "github.com-ed25519" = {
      hostNames = [ "github.com" ];
      publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl";
    };
  };
}
