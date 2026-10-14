{
  config,
  lib,
  pkgs,
  ...
}:
let
  encryptedRuntime = "\n" + builtins.readFile config.sops.defaultSopsFile;
  tunnels = [
    {
      name = "slate";
      apiKey = "openai-mcp-api-key";
      configKey = "openai-mcp-slate-config";
    }
    {
      name = "secondary";
      apiKey = "openai-mcp-secondary-api-key";
      configKey = "openai-mcp-secondary-config";
    }
  ];
  configured =
    tunnel:
    lib.hasInfix "\n${tunnel.apiKey}:" encryptedRuntime
    && lib.hasInfix "\n${tunnel.configKey}:" encryptedRuntime;
  package = pkgs.callPackage ../../pkgs/tunnel-client { };
in
{
  config = lib.mkMerge (
    [
      {
        warnings =
          lib.optional (!(configured (builtins.head tunnels)))
            "Slate MCP tunnel is not configured. Run nix run .#jupiter-secrets in nix-config, then rebuild jupiter.";
      }
    ]
    ++ map (
      tunnel:
      lib.mkIf (configured tunnel) {
        services.tailscale.enable = true;
        sops.secrets = {
          "${tunnel.apiKey}" = {
            restartUnits = [ "openai-mcp-tunnel-${tunnel.name}.service" ];
          };
          "${tunnel.configKey}" = {
            restartUnits = [ "openai-mcp-tunnel-${tunnel.name}.service" ];
          };
        };
        systemd.services."openai-mcp-tunnel-${tunnel.name}" = {
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
              "api-key:${config.sops.secrets.${tunnel.apiKey}.path}"
              "config:${config.sops.secrets.${tunnel.configKey}.path}"
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
      }
    ) tunnels
  );

}
