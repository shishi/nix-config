{
  config,
  inputs,
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
    secrets."smb-mars-shishi" = {
      owner = "root";
      group = "root";
      mode = "0400";
    };
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
}
