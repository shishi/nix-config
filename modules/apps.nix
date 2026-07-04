# flake の apps 定義: nix run .#<name> で実行できるコマンド群
#   update                  : flake update + カスタムパッケージ更新を一括実行
#   setup-* / install-*     : scripts/ のシェルスクリプトを実行するラッパー
{ ... }:
{
  perSystem =
    { pkgs, ... }:
    let
      # scripts/<file> を bash で実行するだけの app を作るヘルパー。
      # setup-* / install-* のように「既存スクリプトに引数を渡すだけ」の app で使う。
      mkScriptApp = name: script: {
        type = "app";
        program = "${pkgs.writeShellScript name ''
          exec ${pkgs.bash}/bin/bash ${script} "$@"
        ''}";
      };
    in
    {
      apps = {
        # 更新スクリプト本体は scripts/update-all.sh に外出しし、
        # 必要ツールは runtimeInputs で PATH に注入する。
        update = {
          type = "app";
          program = "${
            pkgs.writeShellApplication {
              name = "update-all";
              runtimeInputs = with pkgs; [
                git
                nix
                jq
                nix-update
              ];
              text = builtins.readFile ../scripts/update-all.sh;
            }
          }/bin/update-all";
        };

        setup-sudo-nopasswd = mkScriptApp "setup-sudo-nopasswd" ../scripts/setup-sudo-nopasswd.sh;
        setup-trusted-user = mkScriptApp "setup-trusted-user" ../scripts/setup-nix-trusted-user.sh;
        install-system-packages = mkScriptApp "install-system-packages" ../scripts/install-system-packages.sh;
      };
    };
}
