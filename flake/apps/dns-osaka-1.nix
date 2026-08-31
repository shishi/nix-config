# dns-osaka-1 の provisioning app データ(module ではない)。
# ./default.nix の mkProvisioningApps が dns-osaka-1-secrets / dns-osaka-1-install に組み立てる。
# workflow 本体は scripts/dns-osaka-1-secrets.sh / scripts/dns-osaka-1-install.sh が所有する。
{ pkgs }:
{
  secretsInputs = with pkgs; [
    age
    coreutils
    findutils
    git
    jq
    sops
    util-linux
  ];
  installInputs = with pkgs; [
    age
    coreutils
    findutils
    git
    jq
    sops
    util-linux
  ];
}
