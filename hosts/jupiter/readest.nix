{
  config,
  lib,
  pkgs,
  ...
}:
let
  serviceName = "readest";
  # Web 版は API に手元のアクセストークンを送り、起動のたびに試す更新が完了するまで差し替えない。
  # 更新がサーバーへ届かない端末でも期限内なら同期を続けられるよう、1 年有効にする。
  accessTokenLifetime = toString (365 * 24 * 60 * 60);
  # Renovate が上流リリースの tag と commit を一緒に更新するので、この 2 行は隣接させて書く。
  # commit で内容が決まるため、Renovate が計算できない Nix のハッシュは持たない。
  readestTag = "v0.12.20";
  readestRev = "28aab23e039a23511bc478c23bf5278daa43cc68";
  source = builtins.fetchGit {
    url = "https://github.com/readest/readest.git";
    ref = "refs/tags/${readestTag}";
    rev = readestRev;
    submodules = true;
    shallow = true;
  };
  webBuildSource = pkgs.applyPatches {
    name = "readest-web-pwa";
    src = source;
    patches = [ ../../patches/readest-docker-pwa.patch ];
  };
  webImage = "readest-local:${builtins.baseNameOf webBuildSource}";
  env = name: "$" + "{${name}}";
  # PostgreSQL のイメージが変わると、照合順序を提供する glibc の版も変わることがある。
  # 並び順が変わると文字列の索引と食い違うため、版が変わった DB の索引を作り直す。
  refreshCollation = pkgs.writeText "readest-refresh-collation.sh" ''
    set -eu
    export PGHOST="$POSTGRES_HOST" PGPORT="$POSTGRES_PORT" PGPASSWORD="$POSTGRES_PASSWORD"
    psql_admin() {
      psql -v ON_ERROR_STOP=1 --no-password --no-psqlrc -U supabase_admin "$@"
    }
    stale=$(psql_admin -d postgres -tAc "SELECT datname FROM pg_database
      WHERE datallowconn
        AND datcollversion IS DISTINCT FROM pg_database_collation_actual_version(oid)")
    for db in $stale; do
      echo "readest-collation: rebuilding the indexes of $db"
      psql_admin -d "$db" -c "REINDEX DATABASE \"$db\""
      psql_admin -d "$db" -c "ALTER DATABASE \"$db\" REFRESH COLLATION VERSION"
    done
  '';
  # PostgreSQL のメジャー版の更新で、旧版のデータを pg_upgrade するためだけに使う旧版のイメージ。
  # 旧版のデータを読めればよく、新しいメジャー版へ上げると移行できなくなるため、Renovate が
  # 更新する `image = "..."` の形では書かない。
  postgresUpgradeSource = "supabase/postgres:15.20.0.001@sha256:87b54b71426fc082f6a11ce3deb76ff6914744064f08e32014f2f78d1d5a6a16";
  postgresMajor = image: builtins.head (builtins.match "supabase/postgres:([0-9]+)\\..*" image);
  # データが自分のメジャー版で、db のイメージと違うときだけ、旧版の PostgreSQL を
  # Nix のストアパスごと共有の volume へ写す。
  copyUpgradeSource = pkgs.writeText "readest-postgres-upgrade-source.sh" ''
    set -eu
    from=$(cat /data/PG_VERSION 2>/dev/null || true)
    own=$(postgres -V | sed -E 's/.* ([0-9]+)\..*/\1/')
    if [ "$from" != "$own" ] || [ "$from" = "$PG_TARGET_MAJOR" ] || [ -f /upgrade-bin/bindir ]; then
      exit 0
    fi
    package=$(dirname "$(dirname "$(readlink -f /usr/lib/postgresql/bin/postgres)")")
    paths=$(nix-store --query --requisites "$package")
    rm -rf /upgrade-bin/store
    mkdir /upgrade-bin/store
    cp -a $paths /upgrade-bin/store/
    echo "$package/bin" >/upgrade-bin/bindir
  '';
  # 新しいメジャー版の PostgreSQL は旧版のデータディレクトリを読めない。旧版のバイナリーで
  # pg_upgrade し、移行後のクラスターを同じ volume の中で入れ替える。旧クラスターは残さない。
  # 版が変わる起動の前に readest-backup が volume を退避しているため。
  upgradePostgres = pkgs.writeText "readest-postgres-upgrade.sh" ''
    set -eu
    data=/var/lib/postgresql/data
    work="$data/.pg-upgrade"
    # upgraded が無い間は、使うクラスターは常に $data にある。
    if [ ! -e "$work/upgraded" ]; then
      from=$(cat "$data/PG_VERSION" 2>/dev/null || true)
      if [ -z "$from" ] || [ "$from" = "$PG_TARGET_MAJOR" ]; then
        # 後片付けの途中で止まった移行の残りを消す。
        rm -rf "$work" /upgrade-bin/bindir /upgrade-bin/store
        exit 0
      fi
      if [ ! -f /upgrade-bin/bindir ]; then
        echo "readest-postgres-upgrade: no PostgreSQL $from binaries to upgrade the data with; set postgresUpgradeSource to a supabase/postgres $from image" >&2
        exit 1
      fi
      echo "readest-postgres-upgrade: upgrading the data from PostgreSQL $from to $PG_TARGET_MAJOR"
      # 旧版のバイナリーは自分のストアパスにある依存を読み込むため、同じパスに見せる。
      for path in /upgrade-bin/store/*; do
        [ -e "/nix/store/''${path##*/}" ] || ln -s "$path" /nix/store/
      done
      new_bin=$(dirname "$(readlink -f /usr/lib/postgresql/bin/postgres)")
      # 旧版のイメージで作ったデータは、UID の違う postgres が所有していることがある。
      chown -R postgres:postgres "$data"
      rm -rf "$work"
      mkdir -p "$work/new" "$work/old"
      chown postgres:postgres "$work" "$work/new"
      cd "$work"
      su-exec postgres "$new_bin/initdb" --username=supabase_admin -D "$work/new"
      su-exec postgres "$new_bin/pg_upgrade" --username=supabase_admin \
        --old-bindir="$(cat /upgrade-bin/bindir)" --new-bindir="$new_bin" \
        --old-datadir="$data" --new-datadir="$work/new"
      # pg_upgrade は統計を移さない。pg_upgrade が出す update_extensions.sql は当てない。
      # pg_graphql には旧版からの更新経路が無く、拡張はマイナー版の更新と同じく移行前の版で動く。
      su-exec postgres "$new_bin/pg_ctl" -D "$work/new" -w \
        -o "-c listen_addresses= -c unix_socket_directories=$work" start
      su-exec postgres "$new_bin/vacuumdb" -h "$work" -U supabase_admin --all --analyze-only
      su-exec postgres "$new_bin/pg_ctl" -D "$work/new" -w stop
      touch "$work/upgraded"
    fi
    # 入れ替えが途中で止まっても、次の起動で残りを移す。
    if [ ! -e "$work/old-moved" ]; then
      for entry in "$data"/*; do
        [ ! -e "$entry" ] || mv "$entry" "$work/old/"
      done
      touch "$work/old-moved"
    fi
    for entry in "$work"/new/*; do
      [ ! -e "$entry" ] || mv "$entry" "$data/"
    done
    rm "$work/upgraded"
    rm -rf "$work" /upgrade-bin/bindir /upgrade-bin/store
  '';
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
      location = /api/tts/edge {
        proxy_pass http://client:3000;
        # 単語境界ヘッダーは最大 8 KiB で、既定のヘッダーバッファーを超える。
        proxy_buffer_size 16k;
        proxy_buffers 4 16k;
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
  composeConfig = {
    name = "readest";
    services = rec {
      db = {
        image = "supabase/postgres:17.12.0.001@sha256:374df435f973b1d371dbaecb1a69403f4fdbb67238f354be424fe04435a45aee";
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
          JWT_EXP = accessTokenLifetime;
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
        depends_on = {
          db-config-refresh.condition = "service_completed_successfully";
          db-upgrade.condition = "service_completed_successfully";
        };
      };
      db-upgrade-source = {
        image = postgresUpgradeSource;
        volumes = [
          "db-data:/data:ro"
          "db-upgrade-bin:/upgrade-bin"
          "${copyUpgradeSource}:/copy-upgrade-source.sh:ro"
        ];
        environment.PG_TARGET_MAJOR = postgresMajor db.image;
        entrypoint = [
          "sh"
          "/copy-upgrade-source.sh"
        ];
      };
      db-upgrade = {
        inherit (db) image;
        volumes = [
          "db-data:/var/lib/postgresql/data"
          "db-upgrade-bin:/upgrade-bin"
          "${upgradePostgres}:/upgrade-postgres.sh:ro"
        ];
        environment.PG_TARGET_MAJOR = postgresMajor db.image;
        entrypoint = [
          "sh"
          "/upgrade-postgres.sh"
        ];
        depends_on.db-upgrade-source.condition = "service_completed_successfully";
      };
      # 上流の構成は pgsodium の鍵を残すために /etc/postgresql-custom を volume にしているが、
      # volume は作成時のイメージの設定ファイルと postgres の UID も保持し続ける。新しいイメージは
      # そこに無い設定を読みに行き、UID の違う鍵も読めずに起動できない。起動のたびに今の
      # イメージの設定と所有者へ揃える。鍵はイメージに含まれないので上書きされずに残る。
      db-config-refresh = {
        inherit (db) image;
        volumes = [ "db-config:/persisted" ];
        entrypoint = [
          "sh"
          "-c"
          "cp -a /etc/postgresql-custom/. /persisted/ && chown -R postgres:postgres /persisted"
        ];
      };
      # 上流の初期化処理は migration を DB の新規作成時にしか当てない。既存の DB にも
      # 起動のたびに未適用分だけを当て、Web 版はその完了を待ってから起動する。
      migrate = {
        inherit (db) image;
        depends_on.db.condition = "service_healthy";
        volumes = [
          "${source}/docker/volumes/db/migrations:/readest-migrations:ro"
          "${source}/docker/volumes/db/apply-migrations.sh:/apply-migrations.sh:ro"
          "${refreshCollation}:/refresh-collation.sh:ro"
        ];
        environment = {
          POSTGRES_HOST = "db";
          POSTGRES_PORT = env "POSTGRES_PORT";
          POSTGRES_DB = env "POSTGRES_DB";
          POSTGRES_PASSWORD = env "POSTGRES_PASSWORD";
        };
        entrypoint = [
          "sh"
          "-c"
          "sh /refresh-collation.sh && exec sh /apply-migrations.sh"
        ];
      };
      kong = {
        image = "kong:3.9.4@sha256:ad6cc0c8cca5b66b3cdab3bde7bc7ca973d4d820dd2c6651a7e3042f5428a76a";
        restart = "unless-stopped";
        volumes = [ "${source}/docker/volumes/api/kong.yml:/home/kong/temp.yml:ro" ];
        environment = {
          KONG_DATABASE = "off";
          KONG_NGINX_WORKER_PROCESSES = "1";
          # kong:3.9 のイメージには /home/kong が無く、雛形の mount で Docker が root の所有で作るため、
          # kong ユーザーは書き込めない。展開した設定は kong ユーザーが所有する Kong の prefix に置く。
          KONG_DECLARATIVE_CONFIG = "/usr/local/kong/kong.yml";
          KONG_DNS_ORDER = "LAST,A,CNAME";
          KONG_PLUGINS = "request-transformer,cors,key-auth,acl,basic-auth";
          SUPABASE_ANON_KEY = env "ANON_KEY";
          SUPABASE_SERVICE_KEY = env "SERVICE_ROLE_KEY";
        };
        entrypoint = ''bash -c 'eval "echo \"$$(cat ~/temp.yml)\"" > "$$KONG_DECLARATIVE_CONFIG" && /docker-entrypoint.sh kong docker-start' '';
        depends_on = {
          auth.condition = "service_started";
          rest.condition = "service_started";
        };
      };
      auth = {
        image = "supabase/gotrue:v2.185.0@sha256:de22ff0811f3e4f7e6d3ba226f75ed8d82310df577bbd61e16fbfd7a50a8c9ce";
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
          GOTRUE_JWT_EXP = accessTokenLifetime;
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
        image = "postgrest/postgrest:v14.18@sha256:c7cd7e265a85b05248abf53f4473fcec7e327c282d0bd0cf60f1551996d09fcf";
        restart = "unless-stopped";
        depends_on.db.condition = "service_healthy";
        environment = {
          PGRST_DB_URI = "postgres://authenticator:${env "POSTGRES_PASSWORD"}@db:${env "POSTGRES_PORT"}/${env "POSTGRES_DB"}";
          PGRST_DB_SCHEMAS = env "PGRST_DB_SCHEMAS";
          PGRST_DB_ANON_ROLE = "anon";
          PGRST_JWT_SECRET = env "JWT_SECRET";
          PGRST_DB_USE_LEGACY_GUCS = "false";
          PGRST_APP_SETTINGS_JWT_SECRET = env "JWT_SECRET";
          PGRST_APP_SETTINGS_JWT_EXP = accessTokenLifetime;
        };
        command = [ "postgrest" ];
      };
      storage = {
        image = "chrislusf/seaweedfs:4.54@sha256:4b42c212543a0acd4c0e675215ecdcaf62a186ef98def76c7e12701871222d15";
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
          # Webpack の空 bufferutil stub を避け、ws の標準実装でフレームを送信する。
          WS_NO_BUFFER_UTIL = "1";
          FONT_BASE_URL = env "FONT_BASE_URL";
        };
        depends_on = {
          kong.condition = "service_started";
          storage.condition = "service_healthy";
          migrate.condition = "service_completed_successfully";
        };
      };
      proxy = {
        image = "nginx:1.28-alpine@sha256:a8b39bd9cf0f83869a2162827a0caf6137ddf759d50a171451b335cecc87d236";
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
      db-upgrade-bin = { };
      storage-data = { };
    };
  };
  composeFile = (pkgs.formats.yaml { }).generate "readest-compose.yaml" composeConfig;
  # volume の中身を書き換えうる版の組。上流のリリースは DB の migration を、GoTrue は
  # 認証スキーマの migration を持つ。nixpkgs だけの更新でも Compose ファイルの
  # store path は変わるため、退避の要否はそれでは判断しない。
  dataRelease = pkgs.writeText "readest-data-release" (
    lib.concatLines (
      [ readestRev ]
      ++ map (name: composeConfig.services.${name}.image) [
        "db"
        "auth"
        "storage"
      ]
    )
  );
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
  # dataRelease が変わった起動の前に、停止した状態の 3 つの volume をまとめて退避する。
  # 版の更新で DB の形式が変わっても、更新前の世代へ戻せるようにするため。
  backup = pkgs.writeShellApplication {
    name = "readest-backup";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.diffutils
      pkgs.docker
      pkgs.findutils
      pkgs.gnugrep
      pkgs.jq
    ];
    text = ''
      state="''${XDG_DATA_HOME:-$HOME/.local/share}/readest"
      # 記録は「volume をこの版の組で作ったか、この版の組の起動前に退避した」ことを表す。
      # 失敗した更新の再起動のたびに退避すると、更新前の世代が整理で消えるため、
      # 起動の成否では記録を更新しない。
      if cmp -s "$state/volumes-release" ${dataRelease}; then
        exit 0
      fi
      # 一覧を取れないときは止める。問い合わせの失敗を volume の不在と取り違えると、
      # 退避せずに記録だけが進む。
      volumes=$(docker volume ls --quiet)
      if ! grep -qx readest_db-data <<<"$volumes"; then
        cat ${dataRelease} >"$state/volumes-release"
        exit 0
      fi
      ${compose}/bin/readest-compose down --timeout 30
      backups="$state/backups"
      mkdir -p "$backups"
      # 失敗や中断で残った作成途中のファイルが、再起動のたびに積み上がらないようにする。
      rm -f "$backups"/*.partial
      archive="$(date +%Y%m%dT%H%M%S).tar"
      # volume の中身は root と postgres の所有なので、コンテナー内で読み取り、所有者を戻す。
      image=$(${compose}/bin/readest-compose config --format json | jq -er '.services.proxy.image')
      docker run --rm \
        --volume readest_db-data:/volumes/db-data:ro \
        --volume readest_db-config:/volumes/db-config:ro \
        --volume readest_storage-data:/volumes/storage-data:ro \
        --volume "$backups:/backups" \
        --entrypoint sh "$image" -c "tar --numeric-owner -C /volumes -cf /backups/$archive.partial . && chown $(id -u):$(id -g) /backups/$archive.partial"
      mv "$backups/$archive.partial" "$backups/$archive"
      cat ${dataRelease} >"$state/volumes-release"
      find "$backups" -maxdepth 1 -name '*.tar' -printf '%f\n' | sort -r | tail -n +4 |
        while read -r old; do rm -- "$backups/$old"; done
      echo "Readest volumes were saved to $backups/$archive before starting new Readest releases."
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
            "${backup}/bin/readest-backup"
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
