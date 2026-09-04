{
  config,
  lib,
  pkgs,
  ...
}:
let
  ollamaModel = "qwen3:4b-instruct-2507-q4_K_M";
  freshrssDigest = pkgs.writeTextFile {
    name = "freshrss-digest";
    destination = "/bin/freshrss-digest";
    executable = true;
    text = ''
      #!${pkgs.python3}/bin/python3
      ${builtins.readFile ./freshrss_digest.py}
    '';
  };
in
{
  services.tailscale = {
    enable = true;
    openFirewall = true;
    authKeyFile = config.sops.secrets."tailscale-oauth-secret".path;
    authKeyParameters = {
      ephemeral = false;
      preauthorized = true;
    };
    extraUpFlags = [ "--advertise-tags=tag:dns" ];
    extraSetFlags = [ "--ssh" ];
  };

  # tailscaled-autoconnect は起動時に Tailscale API を名前解決する。この host の
  # 名前解決先は localhost の AdGuard Home なので、それより先に走ると失敗する(実測)。
  systemd.services.tailscaled-autoconnect.after = [ "adguardhome.service" ];

  networking.firewall = {
    enable = true;
    interfaces.tailscale0 = {
      allowedTCPPorts = [
        53
        443
        3000
        8080
        11434
      ];
      allowedUDPPorts = [ 53 ];
    };
  };

  # Tailscale Serve が公開証明書を自動管理し、tailnet 内の 443/TCP から
  # AdGuard Home の HTTP DoH エンドポイントへ中継する。
  systemd.services.adguardhome-doh = {
    description = "Expose AdGuard Home DNS-over-HTTPS through Tailscale Serve";
    wantedBy = [ "multi-user.target" ];
    requires = [
      "adguardhome.service"
      "tailscaled.service"
    ];
    wants = [ "tailscaled-autoconnect.service" ];
    after = [
      "adguardhome.service"
      "tailscaled.service"
      "tailscaled-autoconnect.service"
    ];
    path = [ config.services.tailscale.package ];
    script = ''
      tailscale serve --bg --yes --https=443 http://127.0.0.1:3000
    '';
    preStop = ''
      tailscale serve --yes --https=443 off
    '';
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      Restart = "on-failure";
      RestartSec = "5s";
    };
  };

  services.adguardhome = {
    enable = true;
    host = "0.0.0.0";
    port = 3000;
    # 宣言が正。UI での変更は再起動で失われる(閲覧・実験用)
    mutableSettings = false;
    openFirewall = false;
    settings = {
      http.doh.insecure_enabled = true;
      users = [ ];
      dns = {
        bind_hosts = [ "0.0.0.0" ];
        port = 53;
        # どちらもフィルタリング無しの上流(遮断は AdGuard 側の責務)。
        # bootstrap は v4/v6 両方(IPv6 の開通は runbook の IPv6 節)。
        upstream_dns = [
          "https://cloudflare-dns.com/dns-query"
          "https://dns10.quad9.net/dns-query"
        ];
        bootstrap_dns = [
          "1.1.1.1"
          "9.9.9.10"
          "2606:4700:4700::1111"
          "2620:fe::10"
        ];
      };
      querylog = {
        enabled = true;
        file_enabled = true;
        # AdGuard Home keeps the current and previous file, so retention is
        # twice this rotation interval: 3.5 days * 2 = 7 days maximum.
        interval = "84h";
        size_memory = 1000;
      };
      statistics = {
        enabled = true;
        interval = "720h";
      };
      clients.persistent = [
        {
          name = "dns-osaka-1";
          ids = [ "100.124.231.118" ];
          use_global_settings = true;
          use_global_blocked_services = true;
        }
        {
          name = "jupiter";
          ids = [ "100.87.49.13" ];
          use_global_settings = true;
          use_global_blocked_services = true;
        }
        {
          name = "st-m-jv94h722h3";
          ids = [ "100.111.34.20" ];
          use_global_settings = true;
          use_global_blocked_services = true;
        }
        {
          name = "mars";
          ids = [ "100.71.227.37" ];
          use_global_settings = true;
          use_global_blocked_services = true;
        }
        {
          name = "iphone-studist";
          ids = [ "100.122.122.106" ];
          use_global_settings = true;
          use_global_blocked_services = true;
        }
        {
          name = "bpad-mini-ultra";
          ids = [ "100.94.243.61" ];
          use_global_settings = true;
          use_global_blocked_services = true;
        }
        {
          name = "iphone16pro";
          ids = [ "100.107.166.102" ];
          use_global_settings = true;
          use_global_blocked_services = true;
        }
        {
          name = "earth-ubuntu";
          ids = [ "100.107.214.2" ];
          use_global_settings = true;
          use_global_blocked_services = true;
        }
        {
          name = "earth";
          ids = [ "100.114.45.65" ];
          use_global_settings = true;
          use_global_blocked_services = true;
        }
      ];
      # 280blocker(日本のモバイル広告)は公式配布元が OCI の IP からの取得を
      # 403 で拒否するため購読できない。第三者ミラーは改ざんリスクがあり使わない。
      # 日本ドメインの取りこぼしは user_rules か別リストで個別に足す。
      filters = [
        {
          enabled = true;
          id = 1;
          name = "AdGuard DNS filter";
          url = "https://adguardteam.github.io/HostlistsRegistry/assets/filter_1.txt";
        }
        {
          enabled = true;
          id = 2;
          name = "Peter Lowe's Blocklist";
          url = "https://adguardteam.github.io/HostlistsRegistry/assets/filter_3.txt";
        }
        {
          enabled = true;
          id = 3;
          name = "HaGeZi's Pro++ Blocklist";
          url = "https://adguardteam.github.io/HostlistsRegistry/assets/filter_51.txt";
        }
        {
          enabled = true;
          id = 4;
          name = "HaGeZi's Threat Intelligence Feeds";
          url = "https://adguardteam.github.io/HostlistsRegistry/assets/filter_44.txt";
        }
        {
          enabled = true;
          id = 5;
          name = "Dandelion Sprout's Anti-Malware List";
          url = "https://adguardteam.github.io/HostlistsRegistry/assets/filter_12.txt";
        }
        {
          enabled = true;
          id = 6;
          name = "HaGeZi's DNS Rebind Protection";
          url = "https://adguardteam.github.io/HostlistsRegistry/assets/filter_71.txt";
        }
      ];
      user_rules = [
        # Peter Lowe's Blocklist は t.co 全体を遮断するが、短縮リンクは日常利用する。
        "@@||t.co^"
        # フィルタを通過した広告配信専用ホスト。共有 CDN 全体は遮断しない。
        "||adstirservice.com^"
        "||global.moloco.map.fastly.net^"
        "||ssp.bance.jp.wcdnga.com^"
        "||pumpkin.uverse.iponweb.net^"
        "||gateway.rtbfabric.ap-northeast-1.amazonaws.com^"
      ];
      filtering = {
        filtering_enabled = true;
        filters_update_interval = 24;
        protection_enabled = true;
      };
    };
  };

  services.ollama = {
    enable = true;
    package = pkgs.ollama-cpu;
    host = "0.0.0.0";
    port = 11434;
    openFirewall = false;
    loadModels = [ ollamaModel ];
    syncModels = true;
    environmentVariables = {
      OLLAMA_CONTEXT_LENGTH = "8192";
      OLLAMA_KEEP_ALIVE = "-1";
      OLLAMA_MAX_LOADED_MODELS = "1";
      OLLAMA_NUM_PARALLEL = "1";
    };
  };
  systemd.services.ollama.serviceConfig = {
    MemoryMax = "8G";
    Restart = "on-failure";
    RestartSec = "10s";
  };
  systemd.services.ollama-warm = {
    description = "Keep the declared Ollama model resident";
    wantedBy = [ "multi-user.target" ];
    requires = [
      "ollama.service"
      "ollama-model-loader.service"
    ];
    after = [
      "ollama.service"
      "ollama-model-loader.service"
    ];
    partOf = [ "ollama.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      Restart = "on-failure";
      RestartSec = "30s";
    };
    script = ''
      ${lib.getExe pkgs.curl} --fail --silent --show-error \
        --header 'Content-Type: application/json' \
        --data-binary '${
          builtins.toJSON {
            model = ollamaModel;
            prompt = "";
            stream = false;
            keep_alive = -1;
          }
        }' \
        http://127.0.0.1:11434/api/generate >/dev/null
    '';
  };

  users.groups.freshrss-digest = { };
  users.users.freshrss-digest = {
    isSystemUser = true;
    group = "freshrss-digest";
  };
  users.users.nginx.extraGroups = [ "freshrss-digest" ];

  systemd.services.freshrss-digest = {
    description = "Create a daily FreshRSS digest with Ollama";
    wants = [
      "network-online.target"
      "ollama-warm.service"
      "tailscaled-autoconnect.service"
    ];
    after = [
      "network-online.target"
      "ollama-warm.service"
      "tailscaled-autoconnect.service"
    ];
    environment = {
      DIGEST_FEED_URL = "https://dns-osaka-1.cougar-hydra.ts.net:8443/digest.atom";
      DIGEST_LABELS = "news,computer";
      OLLAMA_MODEL = ollamaModel;
      OLLAMA_URL = "http://127.0.0.1:11434";
    };
    serviceConfig = {
      Type = "oneshot";
      User = "freshrss-digest";
      Group = "freshrss-digest";
      StateDirectory = "freshrss-digest";
      StateDirectoryMode = "0750";
      LoadCredential = [
        "freshrss-api-url:${config.sops.secrets."freshrss-api-url".path}"
        "freshrss-api-username:${config.sops.secrets."freshrss-api-username".path}"
        "freshrss-api-password:${config.sops.secrets."freshrss-api-password".path}"
      ];
      NoNewPrivileges = true;
      PrivateTmp = true;
      ProtectHome = true;
      ProtectSystem = "strict";
      TimeoutStartSec = "2h";
      UMask = "0027";
      ExecStart = lib.getExe freshrssDigest;
    };
  };
  systemd.timers.freshrss-digest = {
    description = "Run the FreshRSS digest every day at 06:00 JST";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* 06:00:00";
      Persistent = true;
      Unit = "freshrss-digest.service";
    };
  };

  # digest feed を Tailscale Funnel でインターネットへ公開する。FreshRSS
  # (Synology Docker)は tailnet へ出る経路を持たないため、tailnet 外から
  # 取れる唯一の配信面。中身は Basic 認証で守る(ts.net のホスト名は
  # 証明書の公開記録から第三者に知られうる)。
  systemd.services.freshrss-digest-funnel = {
    description = "Publish the digest feed through Tailscale Funnel";
    wantedBy = [ "multi-user.target" ];
    requires = [
      "nginx.service"
      "tailscaled.service"
    ];
    wants = [ "tailscaled-autoconnect.service" ];
    after = [
      "nginx.service"
      "tailscaled.service"
      "tailscaled-autoconnect.service"
    ];
    path = [ config.services.tailscale.package ];
    script = ''
      tailscale funnel --bg --yes --https=8443 http://127.0.0.1:8081
    '';
    preStop = ''
      tailscale funnel --yes --https=8443 off
    '';
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      Restart = "on-failure";
      RestartSec = "5s";
    };
  };

  services.nginx = {
    enable = true;
    # Funnel 用の入口。tailscale0 側(8080)は認証なしのまま分離する。
    virtualHosts."freshrss-digest-funnel" = {
      listen = [
        {
          addr = "127.0.0.1";
          port = 8081;
        }
      ];
      basicAuthFile = config.sops.secrets."digest-htpasswd".path;
      locations."= /digest.atom" = {
        alias = "/var/lib/freshrss-digest/public/digest.atom";
        extraConfig = ''
          default_type application/atom+xml;
          charset utf-8;
          charset_types application/atom+xml;
        '';
      };
      locations."/".return = "404";
    };
    virtualHosts."freshrss-digest" = {
      default = true;
      listen = [
        {
          addr = "0.0.0.0";
          port = 8080;
        }
      ];
      locations."= /digest.atom" = {
        alias = "/var/lib/freshrss-digest/public/digest.atom";
        # charset_types: nginx が charset を付ける MIME type の既定に
        # application/atom+xml は含まれないため明示する
        extraConfig = ''
          default_type application/atom+xml;
          charset utf-8;
          charset_types application/atom+xml;
        '';
      };
      locations."/".return = "404";
    };
  };
}
