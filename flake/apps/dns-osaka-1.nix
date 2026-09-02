# dns-osaka-1 の provisioning app データ(module ではない)。
# ./default.nix の mkProvisioningApps が dns-osaka-1-secrets / dns-osaka-1-install に組み立てる。
# workflow 本体は scripts/dns-osaka-1-secrets.sh / scripts/dns-osaka-1-install.sh が所有する。
{ pkgs }:
{
  # nix run .#dns-osaka-1-secrets が PATH に持つコマンド群
  secrets.runtimeInputs = with pkgs; [
    age
    coreutils
    git
    jq
    sops
    util-linux
  ];
  # nix run .#dns-osaka-1-install が PATH に持つコマンド群
  install.runtimeInputs = with pkgs; [
    age
    coreutils
    gawk
    git
    gnugrep
    jq
    openssh
    sops
    util-linux
  ];
}
