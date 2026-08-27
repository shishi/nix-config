{
  config,
  inputs,
  pkgs,
  ...
}:
{
  imports = [ inputs.sops-nix.nixosModules.sops ];

  sops = {
    defaultSopsFile = ../../secrets/runtime.yaml;
    defaultSopsFormat = "yaml";
    age = {
      keyFile = "/var/lib/sops-nix/key.txt";
      generateKey = false;
    };
    secrets = {
      "smb-mars-shishi" = {
        owner = "root";
        group = "root";
        mode = "0400";
      };
      "tailscale-oauth-secret" = {
        owner = "root";
        group = "root";
        mode = "0400";
      };
    };
  };

  services.tailscale = {
    authKeyFile = config.sops.secrets."tailscale-oauth-secret".path;
    authKeyParameters = {
      ephemeral = false;
      preauthorized = true;
    };
    extraUpFlags = [ "--advertise-tags=tag:jupiter" ];
    extraSetFlags = [ "--ssh" ];
  };

  fileSystems."/mnt/mars/shishi" = {
    device = "//mars/shishi";
    fsType = "cifs";
    options = [
      "credentials=${config.sops.secrets."smb-mars-shishi".path}"
      "uid=1000"
      "gid=100"
      "file_mode=0600"
      "dir_mode=0700"
      "_netdev"
      "noauto"
      "x-systemd.automount"
      "x-systemd.idle-timeout=5min"
      "x-systemd.mount-timeout=10s"
    ];
  };

  systemd.services.import-shishi-gpg-secret = {
    description = "Import shishi's GPG signing key";
    wantedBy = [ "multi-user.target" ];
    unitConfig.ConditionPathExists = "/home/shishi/gpg-secret.asc";
    path = [
      pkgs.bash
      pkgs.coreutils
      pkgs.gawk
      pkgs.gnupg
    ];
    script = ''
      exec ${../../scripts/import-gpg-secret.sh} /home/shishi/gpg-secret.asc /home/shishi/.gnupg
    '';
    serviceConfig = {
      Type = "oneshot";
      User = "shishi";
      Group = "users";
      UMask = "0077";
    };
  };
}
