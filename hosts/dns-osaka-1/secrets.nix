{
  config,
  inputs,
  ...
}:
{
  imports = [ inputs.sops-nix.nixosModules.sops ];

  sops = {
    defaultSopsFile = ../../secrets/dns-osaka-1/runtime.yaml;
    defaultSopsFormat = "yaml";
    age = {
      keyFile = "/var/lib/sops-nix/dns-osaka-1-age-key.txt";
      generateKey = false;
    };
    secrets = {
      "tailscale-oauth-secret" = {
        owner = "root";
        group = "root";
        mode = "0400";
      };
      "freshrss-api-url" = { };
      "freshrss-api-username" = { };
      "freshrss-api-password" = { };
      # Funnel 公開する digest feed の Basic 認証(nginx が読む htpasswd 行)。
      # 平文は digest-feed-password キーにあり、FreshRSS の購読設定に使う。
      "digest-htpasswd" = {
        owner = "nginx";
        mode = "0400";
      };
    };
  };
}
