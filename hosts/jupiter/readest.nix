{ config, pkgs, ... }:
let
  serviceName = "readest";
  source = pkgs.fetchgit {
    url = "https://github.com/readest/readest.git";
    rev = "2d37bbfc2e94725e1343ab2a825573545aa59f5f";
    hash = "sha256-b6Ce6TtHDmY3g0q7BV6ITlnh0njhBUit2sRp4dDy4+k=";
    fetchSubmodules = true;
  };
  webBuildSource = pkgs.applyPatches {
    name = "readest-web-pwa";
    src = source;
    patches = [ ../../patches/readest-docker-pwa.patch ];
  };
  webImage = "readest-local:${builtins.baseNameOf webBuildSource}";
  env = name: "$" + "{${name}}";
  proxyConfig = pkgs.writeText "readest-nginx.conf" ''
    upstream readest_library {
      server unix:/run/readest-opds/http.sock;
    }
    server {
      listen 80;
      server_name _;
      proxy_set_header Host $http_host;
      proxy_set_header X-Real-IP $remote_addr;
      proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
      proxy_set_header X-Forwarded-Proto https;
      location / {
        proxy_pass http://client:3000;
      }
      location /nas-books/ {
        proxy_pass http://readest_library;
        proxy_buffering off;
      }
      location ~ ^/(auth|rest)/v1/ {
        proxy_pass http://kong:8000;
      }
      location /readest-files/ {
        proxy_pass http://storage:9000;
        client_max_body_size 0;
        proxy_request_buffering off;
      }
    }
  '';
  composeFile = (pkgs.formats.yaml { }).generate "readest-compose.yaml" {
    name = "readest";
    services = {
      db = {
        image = "supabase/postgres:15.8.1.085";
        restart = "unless-stopped";
        volumes = [
          "${source}/docker/volumes/db/roles.sql:/docker-entrypoint-initdb.d/init-scripts/99-roles.sql:ro"
          "${source}/docker/volumes/db/jwt.sql:/docker-entrypoint-initdb.d/init-scripts/99-jwt.sql:ro"
          "${source}/docker/volumes/db/init/schema.sql:/docker-entrypoint-initdb.d/init-scripts/100-schema.sql:ro"
          "${source}/docker/volumes/db/migrations:/readest-migrations:ro"
          "${source}/docker/volumes/db/apply-migrations.sh:/docker-entrypoint-initdb.d/zz-readest-migrations.sh:ro"
          "db-data:/var/lib/postgresql/data"
          "db-config:/etc/postgresql-custom"
        ];
        environment = {
          POSTGRES_HOST = "/var/run/postgresql";
          PGPORT = env "POSTGRES_PORT";
          POSTGRES_PORT = env "POSTGRES_PORT";
          PGPASSWORD = env "POSTGRES_PASSWORD";
          POSTGRES_PASSWORD = env "POSTGRES_PASSWORD";
          PGDATABASE = env "POSTGRES_DB";
          POSTGRES_DB = env "POSTGRES_DB";
          JWT_SECRET = env "JWT_SECRET";
          JWT_EXP = env "JWT_EXPIRY";
        };
        command = [
          "postgres"
          "-c"
          "config_file=/etc/postgresql/postgresql.conf"
          "-c"
          "log_min_messages=fatal"
        ];
        healthcheck = {
          test = [
            "CMD-SHELL"
            "pg_isready -h 127.0.0.1 -U postgres -d \"$$POSTGRES_DB\""
          ];
          interval = "5s";
          timeout = "5s";
          retries = 30;
          start_period = "20s";
        };
      };
      kong = {
        image = "kong:2.8.1";
        restart = "unless-stopped";
        volumes = [ "${source}/docker/volumes/api/kong.yml:/home/kong/temp.yml:ro" ];
        environment = {
          KONG_DATABASE = "off";
          KONG_NGINX_WORKER_PROCESSES = "1";
          KONG_DECLARATIVE_CONFIG = "/home/kong/kong.yml";
          KONG_DNS_ORDER = "LAST,A,CNAME";
          KONG_PLUGINS = "request-transformer,cors,key-auth,acl,basic-auth";
          SUPABASE_ANON_KEY = env "ANON_KEY";
          SUPABASE_SERVICE_KEY = env "SERVICE_ROLE_KEY";
        };
        entrypoint = ''bash -c 'eval "echo \"$$(cat ~/temp.yml)\"" > ~/kong.yml && /docker-entrypoint.sh kong docker-start' '';
        depends_on = {
          auth.condition = "service_started";
          rest.condition = "service_started";
        };
      };
      auth = {
        image = "supabase/gotrue:v2.185.0";
        restart = "unless-stopped";
        depends_on.db.condition = "service_healthy";
        environment = {
          GOTRUE_API_HOST = "0.0.0.0";
          GOTRUE_API_PORT = "9999";
          API_EXTERNAL_URL = env "API_EXTERNAL_URL";
          GOTRUE_DB_DRIVER = "postgres";
          GOTRUE_DB_DATABASE_URL = "postgres://supabase_auth_admin:${env "POSTGRES_PASSWORD"}@db:${env "POSTGRES_PORT"}/${env "POSTGRES_DB"}";
          GOTRUE_SITE_URL = env "SITE_URL";
          GOTRUE_URI_ALLOW_LIST = env "ADDITIONAL_REDIRECT_URLS";
          GOTRUE_DISABLE_SIGNUP = env "DISABLE_SIGNUP";
          GOTRUE_JWT_ADMIN_ROLES = "service_role";
          GOTRUE_JWT_AUD = "authenticated";
          GOTRUE_JWT_DEFAULT_GROUP_NAME = "authenticated";
          GOTRUE_JWT_EXP = env "JWT_EXPIRY";
          GOTRUE_JWT_SECRET = env "JWT_SECRET";
          GOTRUE_EXTERNAL_EMAIL_ENABLED = env "ENABLE_EMAIL_SIGNUP";
          GOTRUE_EXTERNAL_ANONYMOUS_USERS_ENABLED = env "ENABLE_ANONYMOUS_USERS";
          GOTRUE_MAILER_AUTOCONFIRM = env "ENABLE_EMAIL_AUTOCONFIRM";
          GOTRUE_SMTP_HOST = env "SMTP_HOST";
          GOTRUE_SMTP_PORT = env "SMTP_PORT";
          GOTRUE_SMTP_USER = env "SMTP_USER";
          GOTRUE_SMTP_PASS = env "SMTP_PASS";
          GOTRUE_SMTP_ADMIN_EMAIL = env "SMTP_ADMIN_EMAIL";
          GOTRUE_SMTP_SENDER_NAME = env "SMTP_SENDER_NAME";
        };
      };
      rest = {
        # 発行直後の JWT を散発的に誤拒否する不具合の修正版（PostgREST #5196）。
        image = "postgrest/postgrest:v14.18";
        restart = "unless-stopped";
        depends_on.db.condition = "service_healthy";
        environment = {
          PGRST_DB_URI = "postgres://authenticator:${env "POSTGRES_PASSWORD"}@db:${env "POSTGRES_PORT"}/${env "POSTGRES_DB"}";
          PGRST_DB_SCHEMAS = env "PGRST_DB_SCHEMAS";
          PGRST_DB_ANON_ROLE = "anon";
          PGRST_JWT_SECRET = env "JWT_SECRET";
          PGRST_DB_USE_LEGACY_GUCS = "false";
          PGRST_APP_SETTINGS_JWT_SECRET = env "JWT_SECRET";
          PGRST_APP_SETTINGS_JWT_EXP = env "JWT_EXPIRY";
        };
        command = [ "postgrest" ];
      };
      storage = {
        image = "chrislusf/seaweedfs@sha256:4e61d15fd35994cb1e43e1e553dff106794841fd9a99ade2fc8c8bfce4d7872d";
        restart = "unless-stopped";
        environment = {
          AWS_ACCESS_KEY_ID = env "S3_ACCESS_KEY_ID";
          AWS_SECRET_ACCESS_KEY = env "S3_SECRET_ACCESS_KEY";
          S3_BUCKET = env "S3_BUCKET_NAME";
          S3_EXTERNAL_URL = env "SITE_URL";
        };
        command = [
          "mini"
          "-dir=/data"
          "-s3.port=9000"
        ];
        volumes = [ "storage-data:/data" ];
        healthcheck = {
          test = [
            "CMD-SHELL"
            "wget -q -O /dev/null http://localhost:9333/cluster/status"
          ];
          interval = "5s";
          timeout = "5s";
          retries = 30;
          start_period = "10s";
        };
      };
      client = {
        image = env "READEST_WEB_IMAGE";
        pull_policy = "never";
        build = {
          context = "${webBuildSource}";
          target = "production-stage";
          args = {
            NEXT_PUBLIC_APP_PLATFORM = "web";
            NEXT_PUBLIC_SUPABASE_URL = env "SUPABASE_PUBLIC_URL";
            NEXT_PUBLIC_SUPABASE_ANON_KEY = env "ANON_KEY";
            NEXT_PUBLIC_API_BASE_URL = env "SITE_URL";
          };
        };
        restart = "unless-stopped";
        environment = {
          SUPABASE_URL = "http://kong:8000";
          SUPABASE_PUBLIC_URL = env "SUPABASE_PUBLIC_URL";
          SUPABASE_ANON_KEY = env "ANON_KEY";
          SUPABASE_ADMIN_KEY = env "SERVICE_ROLE_KEY";
          API_BASE_URL = env "SITE_URL";
          S3_ENDPOINT = "http://storage:9000";
          S3_PUBLIC_ENDPOINT = env "S3_PUBLIC_ENDPOINT";
          S3_REGION = "us-east-1";
          S3_BUCKET_NAME = env "S3_BUCKET_NAME";
          S3_ACCESS_KEY_ID = env "S3_ACCESS_KEY_ID";
          S3_SECRET_ACCESS_KEY = env "S3_SECRET_ACCESS_KEY";
          # 本文なしで発行する署名 URL に、空の CRC32 を埋め込ませない。
          AWS_REQUEST_CHECKSUM_CALCULATION = "WHEN_REQUIRED";
          OBJECT_STORAGE_TYPE = env "OBJECT_STORAGE_TYPE";
          SELF_HOSTED = env "SELF_HOSTED";
          STORAGE_FIXED_QUOTA = "1125899906842624";
          TRANSLATION_FIXED_QUOTA = "1000000000000";
          FONT_BASE_URL = env "FONT_BASE_URL";
        };
        depends_on = {
          kong.condition = "service_started";
          storage.condition = "service_healthy";
        };
      };
      proxy = {
        image = "nginx:1.28-alpine";
        restart = "unless-stopped";
        ports = [ "127.0.0.1:3080:80" ];
        volumes = [
          "${proxyConfig}:/etc/nginx/conf.d/default.conf:ro"
          "/run/readest-opds:/run/readest-opds:ro"
        ];
        depends_on.client.condition = "service_started";
      };
    };
    volumes = {
      db-data = { };
      db-config = { };
      storage-data = { };
    };
  };
  compose = pkgs.writeShellApplication {
    name = "readest-compose";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.docker
      pkgs.docker-compose
      pkgs.jq
    ];
    text = ''
      state="''${XDG_DATA_HOME:-$HOME/.local/share}/readest"
      if [[ ! -f "$state/.env" ]]; then
        echo 'Readest has not been initialized. Start readest.service with systemctl --user start readest.' >&2
        exit 1
      fi
      export READEST_WEB_IMAGE="${webImage}"
      image_hash=$(docker compose --project-name readest --env-file "$state/.env" --file ${composeFile} config --format json | jq -cS '.services.client.build' | sha256sum)
      export READEST_WEB_IMAGE="${webImage}-''${image_hash%% *}"
      exec docker compose --project-name readest --env-file "$state/.env" --file ${composeFile} "$@"
    '';
  };
  initialize = pkgs.writeShellApplication {
    name = "readest-initialize";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.docker
      pkgs.jq
      pkgs.python3
      config.services.tailscale.package
    ];
    text = ''
      umask 077
      state="''${XDG_DATA_HOME:-$HOME/.local/share}/readest"
      mkdir -p "$state"
      chmod 700 "$state"
      docker info >/dev/null
      dns_suffix=$(tailscale status --json | jq -er '.CurrentTailnet.MagicDNSSuffix | select(type == "string" and length > 0)')
      python3 ${../../scripts/readest-init.py} "$state/.env" "https://${serviceName}.$dns_suffix"
      chmod 600 "$state/.env"
      web_image=$(${compose}/bin/readest-compose config --format json | jq -er '.services.client.image')
      if ! docker image inspect "$web_image" >/dev/null 2>&1; then
        ${compose}/bin/readest-compose build client
      fi
    '';
  };
  ready = pkgs.writeShellApplication {
    name = "readest-ready";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.curl
    ];
    text = ''
      # 初回 DB の healthcheck は試行の実行時間も含めて最大約 5 分かかる。
      deadline=$((SECONDS + 360))
      while ((SECONDS < deadline)); do
        if curl --fail --silent --max-time 2 http://127.0.0.1:3080/ >/dev/null &&
          curl --fail --silent --max-time 2 http://127.0.0.1:3080/auth/v1/health >/dev/null; then
          exit 0
        fi
        sleep 1
      done
      echo 'Readest did not become ready. Check journalctl --user -u readest.' >&2
      exit 1
    '';
  };
in
{
  imports = [ ./readest-library.nix ];
  virtualisation.docker.enable = true;
  # user unit の起動時も Docker に接続できるよう、activation 前の停止を避ける。
  systemd.services.docker.stopIfChanged = false;
  users.users.shishi = {
    extraGroups = [ "docker" ];
    linger = true;
  };
  services.tailscale = {
    enable = true;
    extraSetFlags = [ "--operator=shishi" ];
  };
  home-manager.users.shishi = {
    home.packages = [ compose ];
    systemd.user.services = {
      readest = {
        Unit = {
          Description = "Readest web app and synchronization backend";
          Wants = [ "readest-serve.service" ];
          StartLimitIntervalSec = 0;
        };
        Install.WantedBy = [ "default.target" ];
        Service = {
          Type = "exec";
          ExecStartPre = [
            "${initialize}/bin/readest-initialize"
            "${compose}/bin/readest-compose pull --ignore-buildable --policy missing --quiet"
          ];
          ExecStart = "${compose}/bin/readest-compose up --no-color --remove-orphans";
          ExecStartPost = "${ready}/bin/readest-ready";
          ExecStop = "${compose}/bin/readest-compose down --timeout 30";
          Restart = "on-failure";
          RestartSec = "15s";
          TimeoutStartSec = "30min";
          TimeoutStopSec = "90s";
          UMask = "0077";
        };
      };
      readest-serve = {
        Unit = {
          Description = "Publish Readest through its Tailscale Service";
          Requires = [ "readest.service" ];
          After = [ "readest.service" ];
          PartOf = [ "readest.service" ];
          StartLimitIntervalSec = 0;
        };
        Install.WantedBy = [ "default.target" ];
        Service = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = "${config.services.tailscale.package}/bin/tailscale serve --yes --service=svc:${serviceName} --https=443 http://127.0.0.1:3080";
          ExecStop = "${config.services.tailscale.package}/bin/tailscale serve clear svc:${serviceName}";
          Restart = "on-failure";
          RestartSec = "15s";
        };
      };
    };
  };
}
