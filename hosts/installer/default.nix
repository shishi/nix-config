# 起動しただけで root へ SSH が通る installer ISO。
#
# 素の nixos-minimal ISO には root の authorized_keys が無い。一方
# nixos-anywhere は disko / install の両フェーズで必ず root@ へ繋ぐ。そのため
# インストールのたびに実機のコンソールで鍵を手打ちする必要があり、それが
# 「コードにしてあるのに毎回人間を挟む」穴になっていた。鍵を焼き込んだ ISO を
# repo 側で作ることで、人間の動作は「USB を焼いて挿す」だけになる。これは
# 素の ISO を使う場合にも必ず行う動作なので、手順は増えない。
#
# **firmware メニューの操作(Secure Boot の無効化 → インストール → 自分の鍵を
# enroll して再有効化、必要なら PK クリア)はこれでも無くならない。**
# ベアメタル + Secure Boot である以上そこはコードにできない。
{ modulesPath, lib, ... }:
{
  imports = [ (modulesPath + "/installer/cd-dvd/installation-cd-minimal.nix") ];

  # ISO の root は空パスワードで、空パスワードの SSH ログインは sshd 側が
  # 拒否する。したがって鍵が唯一の入口になる。
  users.users.root.openssh.authorizedKeys.keys = import ../../shared/authorized-keys.nix;

  # 上流 ISO の既定に依存せず明示する。既定が変わったときに、鍵は焼けている
  # のに入れない ISO が黙って出来上がるのを避けるため。
  services.openssh = {
    enable = true;
    settings.PermitRootLogin = lib.mkForce "prohibit-password";
  };

  # runbook 手順 2 は target 上で nix run を使う。手順 2 側でフラグを明示する
  # 代わりにここで宣言する(同じ目的の手当てを 2 つ置かない)。
  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];

  # 素の nixos-minimal ISO と取り違えないための名前。取り違えて起動すると、
  # この構成が消そうとしている手打ちがそのまま戻る。`image.fileName` では
  # 出力ファイル名は変わらない(実測)。
  image.baseName = lib.mkForce "nixos-installer-shishi";
}
