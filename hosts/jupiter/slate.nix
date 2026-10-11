{
  config,
  inputs,
  lib,
  pkgs,
  ...
}:
let
  sourceDirectory = "/home/shishi/dev/src/github.com/shishi/slate";
  vaultDirectory = "/mnt/mars/shishi/save/slate";
  stateDirectory = "${sourceDirectory}/data/state-mars-slate";
  serverDirectory = "${sourceDirectory}/apps/server/dist";
  webDirectory = "${sourceDirectory}/apps/web/dist";
  buildReady = "${serverDirectory}/.slate-build-ready";
  mainOrigin = "https://slate.cougar-hydra.ts.net";
  runOrigin = "https://slate-run.cougar-hydra.ts.net";
  runtime = inputs.nixpkgs-slate.legacyPackages.${pkgs.stdenv.hostPlatform.system};
  runtimeService = {
    Type = "exec";
    WorkingDirectory = "/";
    Restart = "on-failure";
    # NAS 不通時も、毎分最大 2 回の頻度で復旧まで再試行する。
    RestartSec = "30s";
    TimeoutStartSec = "90s";
    TimeoutStopSec = "60s";
    UMask = "0077";
    NoNewPrivileges = true;
    PrivateTmp = true;
    PrivateDevices = true;
    ProtectSystem = "strict";
    ProtectHome = "tmpfs";
    ProtectProc = "invisible";
    ProtectKernelTunables = true;
    ProtectKernelModules = true;
    ProtectControlGroups = true;
    RestrictSUIDSGID = true;
    RestrictAddressFamilies = [
      "AF_UNIX"
      "AF_INET"
      "AF_INET6"
    ];
    CapabilityBoundingSet = "";
    InaccessiblePaths = [
      "-/run/docker.sock"
      "-/run/user"
    ];
  };
  waitForHttp = url: ''
    for attempt in $(seq 1 60); do
      if curl --fail --silent --max-time 1 ${lib.escapeShellArg url} >/dev/null; then
        exit 0
      fi
      sleep 1
    done
    echo "Slate did not become ready: ${url}" >&2
    exit 1
  '';
in
{
  environment.systemPackages = [
    (pkgs.writeShellApplication {
      name = "slate-update";
      runtimeInputs = [ pkgs.systemd ];
      text = builtins.readFile ../../scripts/slate-update.sh;
    })
  ];

  systemd.services.slate-build = {
    description = "Build Slate in its working tree while both servers are stopped";
    conflicts = [
      "slate.service"
      "slate-run.service"
    ];
    before = [
      "slate.service"
      "slate-run.service"
    ];
    path = [
      runtime.bun
      runtime.coreutils
      runtime.nodejs
    ];
    environment.BUN_INSTALL_CACHE_DIR = "/var/cache/slate-build";
    script = ''
      mkdir -p apps/server/dist
      rm -f ${lib.escapeShellArg buildReady}
      bun install --frozen-lockfile
      bun run build
      touch ${lib.escapeShellArg buildReady}
    '';
    serviceConfig = {
      Type = "oneshot";
      User = "shishi";
      Group = "users";
      WorkingDirectory = sourceDirectory;
      TimeoutStartSec = "15min";
      CacheDirectory = "slate-build";
      UMask = "0022";
      NoNewPrivileges = true;
      PrivateTmp = true;
      ProtectSystem = "strict";
      ProtectHome = "read-only";
      ReadWritePaths = [ sourceDirectory ];
    };
  };

  systemd.services.slate = {
    description = "Slate Vault server";
    wantedBy = [ "multi-user.target" ];
    wants = [
      "network-online.target"
      "tailscaled-autoconnect.service"
      "mnt-mars-shishi.automount"
    ];
    after = [
      "network-online.target"
      "tailscaled-autoconnect.service"
      "mnt-mars-shishi.automount"
    ];
    unitConfig = {
      StartLimitIntervalSec = 0;
      ConditionPathExists = buildReady;
    };
    path = [
      runtime.coreutils
      pkgs.curl
    ];
    environment = {
      HOST = "127.0.0.1";
      PORT = "8787";
      SLATE_VAULT_ROOT = vaultDirectory;
      SLATE_STATE_ROOT = stateDirectory;
      SLATE_WEB_ROOT = webDirectory;
      SLATE_ALLOWED_ORIGIN = mainOrigin;
      SLATE_RUN_ORIGIN = runOrigin;
    };
    preStart = ''
      test -r "$SLATE_VAULT_ROOT"
      test -w "$SLATE_VAULT_ROOT"
    '';
    postStart = waitForHttp "http://127.0.0.1:8787/readyz";
    serviceConfig = runtimeService // {
      User = "shishi";
      Group = "users";
      ExecStart = "${runtime.bun}/bin/bun ${serverDirectory}/index.js";
      BindReadOnlyPaths = [
        serverDirectory
        webDirectory
      ];
      BindPaths = [
        vaultDirectory
        stateDirectory
      ];
      ReadWritePaths = [
        vaultDirectory
        stateDirectory
      ];
    };
  };

  systemd.services.slate-run = {
    description = "Slate isolated HTML execution host";
    wantedBy = [ "multi-user.target" ];
    unitConfig = {
      StartLimitIntervalSec = 0;
      ConditionPathExists = buildReady;
    };
    path = [
      pkgs.coreutils
      pkgs.curl
    ];
    environment = {
      HOST = "127.0.0.1";
      PORT = "8789";
      SLATE_MAIN_ORIGIN = mainOrigin;
    };
    postStart = waitForHttp "http://127.0.0.1:8789/";
    serviceConfig = runtimeService // {
      DynamicUser = true;
      ExecStart = "${runtime.bun}/bin/bun ${serverDirectory}/html-run-server.js";
      BindReadOnlyPaths = [ serverDirectory ];
      InaccessiblePaths = runtimeService.InaccessiblePaths ++ [ "/mnt" ];
      IPAddressDeny = "any";
      IPAddressAllow = "localhost";
    };
  };

  systemd.services.slate-serve = {
    description = "Publish Slate Main and Run through Tailscale Services";
    wantedBy = [ "multi-user.target" ];
    requires = [ "tailscaled.service" ];
    wants = [ "tailscaled-autoconnect.service" ];
    after = [
      "tailscaled.service"
      "tailscaled-autoconnect.service"
    ];
    unitConfig.StartLimitIntervalSec = 0;
    path = [ config.services.tailscale.package ];
    script = ''
      tailscale serve --yes --service=svc:slate --https=443 http://127.0.0.1:8787
      tailscale serve --yes --service=svc:slate-run --https=443 http://127.0.0.1:8789
    '';
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      Restart = "on-failure";
      RestartSec = "30s";
      TimeoutStartSec = "60s";
    };
  };
}
