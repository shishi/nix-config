{
  config,
  lib,
  pkgs,
  ...
}:
let
  secretsFile = ../../secrets/jupiter/mcp.yaml;
  configured = builtins.pathExists secretsFile;
  package = pkgs.callPackage ../../pkgs/tunnel-client { };
in
{
  config = lib.mkMerge [
    {
      warnings =
        lib.optional (!configured)
          "Slate MCP tunnel is not configured. Run nix run .#jupiter-mcp-setup in nix-config, then rebuild jupiter.";
    }
    (lib.mkIf configured {
      services.tailscale.enable = true;
      sops.secrets = {
        "openai-mcp-api-key" = {
          sopsFile = secretsFile;
          key = "api-key";
          restartUnits = [ "openai-mcp-tunnel-slate.service" ];
        };
        "openai-mcp-slate-config" = {
          sopsFile = secretsFile;
          key = "slate-config";
          restartUnits = [ "openai-mcp-tunnel-slate.service" ];
        };
      };
      systemd.services.openai-mcp-tunnel-slate = {
        description = "Slate private OpenAI MCP tunnel";
        wantedBy = [ "multi-user.target" ];
        wants = [
          "network-online.target"
          "tailscaled-autoconnect.service"
        ];
        requires = [ "tailscaled.service" ];
        after = [
          "network-online.target"
          "tailscaled.service"
          "tailscaled-autoconnect.service"
        ];
        serviceConfig = {
          ExecStartPre = "${lib.getExe package} doctor --config %d/config --control-plane.api-key=file:%d/api-key --explain";
          ExecStart = "${lib.getExe package} run --config %d/config --control-plane.api-key=file:%d/api-key";
          LoadCredential = [
            "api-key:${config.sops.secrets.openai-mcp-api-key.path}"
            "config:${config.sops.secrets.openai-mcp-slate-config.path}"
          ];
          DynamicUser = true;
          Restart = "on-failure";
          RestartSec = "5s";
          UMask = "0077";
          NoNewPrivileges = true;
          PrivateTmp = true;
          ProtectHome = true;
          ProtectSystem = "strict";
        };
      };
    })
  ];
}
