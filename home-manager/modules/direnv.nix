{
  config,
  pkgs,
  lib,
  ...
}:

{
  programs.direnv = {
    enable = true;

    # nix-direnv を使用してキャッシュを有効化
    nix-direnv.enable = true;

    # direnv の設定
    config = {
      global = {
        # ログを隠す（シェルプロンプトがスッキリする）
        hide_env_diff = true;
      };
    };
  };
}
