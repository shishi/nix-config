{ pkgs, ... }:
{
  users.users.shishi = {
    isNormalUser = true;
    home = "/home/shishi";
    extraGroups = [
      "wheel"
      "networkmanager"
    ];
    shell = pkgs.fish; # ヒアリング #8: fish 第一級

    # 初回ログイン手段(無いと新規インストール機にログイン不能 — High-3)。
    # 鍵は次 Step のコマンド出力で置換する(未置換は Task 14 のゲートが検出)。
    # initialPassword は初回ログイン後に必ず passwd で変更する
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILarf1PUuzo6XLQNwnOf2IZeyCqXGxgNdrSJUjgbp/94 shishi@earth"
    ];
    initialPassword = "changeme-on-first-login";
  };
  # login shell 登録に必要(/etc/shells)。ユーザー設定は dotfiles/HM 側
  programs.fish.enable = true;
}
