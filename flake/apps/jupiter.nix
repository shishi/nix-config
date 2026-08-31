# jupiter の provisioning app データ(module ではない)。
# ./default.nix の mkProvisioningApps が jupiter-secrets / jupiter-install に組み立てる。
# workflow 本体は scripts/jupiter-secrets.sh / scripts/jupiter-install.sh が所有する。
{ pkgs }:
{
  secretsInputs = with pkgs; [
    age
    coreutils
    diffutils
    findutils
    git
    gnugrep
    gnupg
    jq
    openssh
    sops
    util-linux
  ];
  installInputs = with pkgs; [
    age
    coreutils
    findutils
    git
    gnugrep
    gnupg
    jq
    openssh
    sops
    util-linux
    whois
  ];
}
