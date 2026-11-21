{
  config,
  lib,
  pkgs,
  ...
}:
let
  # クライアントと同じ重みを保つため、モデルはエンジンの更新とは分けて固定する。
  models = [
    {
      name = "whisper.bin";
      url = "https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-large-v3-q5_0.bin";
      sha256 = "d75795ecff3f83b5faa89d1900604ad8c780abd5739fae406de19f23ecd98ad1";
    }
    {
      name = "cleanup.gguf";
      url = "https://huggingface.co/bartowski/google_gemma-4-E4B-it-GGUF/resolve/029e94146666900b08caf49a3b47b413dfa8ec66/google_gemma-4-E4B-it-Q4_K_M.gguf";
      sha256 = "d35a3aa7a6d47de237fd488bb6f7f3efd62908d828f85a63da0ee93acdbefe9f";
    }
  ];
  generation = builtins.hashString "sha256" (builtins.toJSON models);
  stateDirectory = "/var/lib/openwhispr-models";
  modelDirectory = "${stateDirectory}/${generation}";
  # モデルのバイト列を closure に入れると、システム用の公開キャッシュにも配布される。
  manifest =
    (pkgs.writeText "openwhispr-models.json" (builtins.toJSON { inherit generation models; }))
    // {
      inherit models;
    };
  prepare = pkgs.writeShellApplication {
    name = "openwhispr-prepare-models";
    runtimeInputs = with pkgs; [
      coreutils
      curl
      jq
    ];
    text = ''
      exec ${pkgs.bash}/bin/bash ${../../scripts/openwhispr-models.sh} ${manifest} ${stateDirectory}
    '';
  };
  readinessSeconds = 10 * 60;
  ready = pkgs.writeShellApplication {
    name = "openwhispr-ready";
    runtimeInputs = with pkgs; [
      coreutils
      curl
      jq
    ];
    text = ''
      endpoint=$1
      deadline=$((SECONDS + ${toString readinessSeconds}))
      until response=$(curl --fail --silent --show-error --max-time 5 "$endpoint" 2>/dev/null) &&
        jq -e '.status == "ok"' <<< "$response" >/dev/null; do
        if (( SECONDS >= deadline )); then
          echo "OpenWhispr did not become ready at $endpoint within ${toString readinessSeconds} seconds." >&2
          exit 1
        fi
        sleep 1
      done
    '';
  };
  whisper = pkgs.whisper-cpp-vulkan;
  cleanup = pkgs.llama-cpp.override { vulkanSupport = true; };
  inferenceServices = [
    "openwhispr-whisper.service"
    "openwhispr-cleanup.service"
  ];
  inference = {
    wantedBy = [ "multi-user.target" ];
    # Requires は失敗した準備の再起動待ちまで再始動し、再試行間隔を迂回する。
    unitConfig.Requisite = [ "openwhispr-models.service" ];
    after = [ "openwhispr-models.service" ];
    preStart = ''
      test -r ${modelDirectory}/whisper.bin
      test -r ${modelDirectory}/cleanup.gguf
    '';
    serviceConfig = {
      User = "openwhispr";
      Group = "openwhispr";
      Restart = "on-failure";
      RestartSec = "5s";
      TimeoutStartSec = "${toString ((readinessSeconds / 60) + 1)}min";
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      UMask = "0077";
    };
  };
in
{
  system.build.openwhisprModelManifest = manifest;
  hardware.graphics.enable = true;
  users.groups.openwhispr = { };
  users.users.openwhispr = {
    isSystemUser = true;
    group = "openwhispr";
    extraGroups = [ "render" ];
  };
  systemd.tmpfiles.rules = [ "d /var/lib/openwhispr-model-import 0700 root root -" ];
  systemd.services = {
    openwhispr-models = {
      description = "Prepare verified OpenWhispr models";
      stopIfChanged = false;
      wantedBy = [ "multi-user.target" ];
      wants = inferenceServices ++ [ "network-online.target" ];
      after = [ "network-online.target" ];
      environment.SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
      unitConfig.StartLimitIntervalSec = 0;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = "root";
        Group = "openwhispr";
        StateDirectory = "openwhispr-models";
        StateDirectoryMode = "0750";
        UMask = "0027";
        ExecStart = lib.getExe prepare;
        Restart = "on-failure";
        RestartSec = "30s";
        RestartPreventExitStatus = [ 65 ];
        TimeoutStartSec = "2h";
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
      };
    };
    openwhispr-whisper = lib.recursiveUpdate inference {
      description = "OpenWhispr transcription with Whisper Large Q5";
      serviceConfig = {
        RuntimeDirectory = "openwhispr-whisper";
        RuntimeDirectoryMode = "0700";
        ExecStart = "${whisper}/bin/whisper-server --host 127.0.0.1 --port 8178 --model ${modelDirectory}/whisper.bin --language auto --convert --tmp-dir /run/openwhispr-whisper --inference-path /v1/audio/transcriptions";
        ExecStartPost = "${lib.getExe ready} http://127.0.0.1:8178/health";
      };
    };
    openwhispr-cleanup = lib.recursiveUpdate inference {
      description = "OpenWhispr cleanup with Gemma E4B";
      serviceConfig = {
        ExecStart = "${cleanup}/bin/llama-server --host 127.0.0.1 --port 8179 --model ${modelDirectory}/cleanup.gguf --alias gemma-4-e4b --parallel 1 --ctx-size 8192 --gpu-layers auto --sleep-idle-seconds -1 --spec-type ngram-simple --spec-ngram-simple-size-n 4 --spec-ngram-simple-size-m 16";
        ExecStartPost = "${lib.getExe ready} http://127.0.0.1:8179/health";
      };
    };
    openwhispr-serve = {
      description = "Publish OpenWhispr through its Tailscale Service";
      wantedBy = [ "multi-user.target" ];
      requires = [ "tailscaled.service" ];
      wants = [ "tailscaled-autoconnect.service" ];
      after = [
        "tailscaled.service"
        "tailscaled-autoconnect.service"
      ];
      path = [ config.services.tailscale.package ];
      unitConfig.StartLimitIntervalSec = 0;
      script = ''
        tailscale serve --yes --service=svc:openwhispr --https=443 --set-path=/stt http://127.0.0.1:8178
        tailscale serve --yes --service=svc:openwhispr --https=443 --set-path=/llm http://127.0.0.1:8179
      '';
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStopPost = "${config.services.tailscale.package}/bin/tailscale serve clear svc:openwhispr";
        Restart = "on-failure";
        RestartSec = "30s";
        TimeoutStartSec = "60s";
      };
    };
    tailscaled.wants = [ "openwhispr-serve.service" ];
  };
}
