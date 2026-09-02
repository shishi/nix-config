{ pkgs, ... }:
let
  oracleCloudAgent = pkgs.stdenvNoCC.mkDerivation {
    pname = "oracle-cloud-agent";
    version = "1.61.0-6";
    src = pkgs.fetchurl {
      url = "https://api.snapcraft.io/api/v1/snaps/download/ltx4XjES2e2ujitNIuO5GxPYDM6lp6ry_125.snap";
      hash = "sha256-U83Y/hO6XLgDcGIgAXFFpUgyme8j3c45Gzz5mYZbM+M=";
    };
    nativeBuildInputs = [ pkgs.squashfsTools ];
    dontPatchELF = true;
    dontStrip = true;
    unpackPhase = ''
      runHook preUnpack
      unsquashfs -q -d source "$src"
      runHook postUnpack
    '';
    installPhase = ''
      runHook preInstall
      install -Dm755 source/agent "$out/agent"
      install -Dm755 source/plugins/gomon/gomon "$out/plugins/gomon/gomon"
      runHook postInstall
    '';
  };
in
{
  users.groups.snap_daemon = { };
  users.users.snap_daemon = {
    isSystemUser = true;
    group = "snap_daemon";
  };

  environment.etc."oracle-cloud-agent/agent.yml".text = ''
    logDir: "/var/log/oracle-cloud-agent"
    agentHardStopInterval: "25s"
    pluginHardStopInterval: "20s"
    pluginHealthCheckInterval: "10m"
    logAllResources: false
    plugins:
      gomon:
        disabled: false
        exec: "/snap/oracle-cloud-agent/current/plugins/gomon/gomon"
        elevated: false
        args: []
        resourceConstraints:
          cpu: 1
          memory: 1
  '';
  environment.etc."oracle-cloud-agent/plugins/gomon/config.yml".text = ''
    logDir: "/var/log/oracle-cloud-agent/plugins/gomon"
    telemetryInterval: 10s
    telemetryBatchSize: 6
    telemetryBatchCountInRing: 3
    telemetry:
      sample: false
      metrics:
        - name: CpuUtilization
          unit: Percent
          sample: 10
          min_range: 0
          max_range: 100
        - name: MemoryUtilization
          unit: Percent
          sample: 10
          min_range: 0
          max_range: 100
        - name: NetworksBytesIn
          unit: Bytes
          sample: 10000
        - name: NetworksBytesOut
          unit: Bytes
          sample: 10000
        - name: DiskBytesRead
          unit: Bytes
          sample: 10000
        - name: DiskBytesWritten
          unit: Bytes
          sample: 10000
        - name: DiskIopsRead
          unit: Operations
          sample: 10000
        - name: DiskIopsWritten
          unit: Operations
          sample: 10000
        - name: LoadAverage
          unit: NumberOfProcesses
          sample: 0.09
        - name: MemoryAllocationStalls
          unit: NumberOfStalls
          sample: 0.0
  '';

  systemd.tmpfiles.rules = [
    "d /snap 0755 root root -"
    "d /snap/oracle-cloud-agent 0755 root root -"
    "L+ /snap/oracle-cloud-agent/current - - - - ${oracleCloudAgent}"
    "d /var/lib/oracle-cloud-agent 2775 snap_daemon snap_daemon -"
    # gomon は起動時にここへ plugin ソケット用の一時ファイルを作る。
    # 無いと "plugin init error: open /var/lib/oracle-cloud-agent/tmp/…" で
    # 初期化に失敗し、メトリクスが一切送信されない。
    "d /var/lib/oracle-cloud-agent/tmp 2775 snap_daemon snap_daemon -"
    "d /var/log/oracle-cloud-agent 0755 snap_daemon snap_daemon -"
    "d /var/log/oracle-cloud-agent/plugins 0755 snap_daemon snap_daemon -"
    "d /var/log/oracle-cloud-agent/plugins/gomon 0755 snap_daemon snap_daemon -"
    "d /var/snap/oracle-cloud-agent/common 0755 snap_daemon snap_daemon -"
  ];

  systemd.services.oracle-cloud-agent = {
    description = "Oracle Cloud Agent with Compute Instance Monitoring";
    wantedBy = [ "multi-user.target" ];
    wants = [ "network-online.target" ];
    after = [
      "network-online.target"
      "systemd-tmpfiles-setup.service"
    ];
    environment = {
      SNAP = "/snap/oracle-cloud-agent/current";
      SNAP_COMMON = "/var/snap/oracle-cloud-agent/common";
    };
    serviceConfig = {
      Type = "simple";
      User = "snap_daemon";
      Group = "snap_daemon";
      ExecStart = "${oracleCloudAgent}/agent";
      Restart = "always";
      RestartSec = "10s";
      NoNewPrivileges = true;
      PrivateTmp = true;
      ProtectHome = true;
      ProtectSystem = "strict";
      ReadWritePaths = [
        "/var/lib/oracle-cloud-agent"
        "/var/log/oracle-cloud-agent"
        "/var/snap/oracle-cloud-agent/common"
      ];
    };
  };
}
