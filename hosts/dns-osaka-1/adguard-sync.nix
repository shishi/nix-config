{ config, ... }:
{
  virtualisation.oci-containers.backend = "docker";
  virtualisation.oci-containers.containers.adguardhome-sync = {
    image = "ghcr.io/bakito/adguardhome-sync@sha256:d01e5bcd9a2e759c705a6e8aaac483e553b4cc9de292bbaa7271f77fe6d35fac";
    cmd = [ "run" ];
    extraOptions = [ "--network=host" ];
    environmentFiles = [ config.sops.secrets."adguard-sync-env".path ];
    environment = {
      ORIGIN_URL = "http://127.0.0.1:3000";
      API_PORT = "0";
      CRON = "0 * * * *";
      RUN_ON_START = "true";
      FEATURES_DNS_ACCESS_LISTS = "false";
      FEATURES_DNS_SERVER_CONFIG = "false";
      FEATURES_DNS_REWRITES = "false";
      FEATURES_DHCP_SERVER_CONFIG = "false";
      FEATURES_DHCP_STATIC_LEASES = "false";
      FEATURES_GENERAL_SETTINGS = "true";
      FEATURES_PROTECTION_STATUS = "true";
      FEATURES_QUERY_LOG_CONFIG = "false";
      FEATURES_STATS_CONFIG = "false";
      FEATURES_CLIENT_SETTINGS = "false";
      FEATURES_SERVICES = "false";
      FEATURES_FILTERS_BLACKLIST = "true";
      FEATURES_FILTERS_WHITELIST = "true";
      FEATURES_FILTERS_USER_RULES = "true";
      FEATURES_THEME = "false";
      FEATURES_TLS_CONFIG = "false";
    };
  };
  systemd.services.docker-adguardhome-sync = {
    wants = [ "tailscaled-autoconnect.service" ];
    after = [ "tailscaled-autoconnect.service" "adguardhome.service" ];
  };
}
