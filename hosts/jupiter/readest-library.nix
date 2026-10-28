{ pkgs, ... }:
let
  bookDirectory = "/mnt/mars/shishi/book";
  configuration = pkgs.writeText "readest-library.conf" ''
    [global]
      name: NAS 本棚
      i: unix:666:/run/readest-opds/http.sock
      http-only
      rp-loc: /nas-books
      rproxy: 1
      no-thumb
      no-snap
      no-readme
      no-logues
      no-zip
      no-dav
      opds-exts:

    [/]
      /srv/readest-books
      accs:
        r: *
      flags:
        opds
        d2d
        xvol
        assert_root
  '';
in
{
  systemd.services.readest-library = {
    description = "Read-only OPDS catalog for Readest";
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
    };
    environment.XDG_CONFIG_HOME = "/run/readest-opds";
    serviceConfig = {
      Type = "exec";
      User = "shishi";
      Group = "users";
      WorkingDirectory = "/";
      ExecStart = "${pkgs.copyparty}/bin/copyparty -c ${configuration}";
      Restart = "on-failure";
      RestartSec = "30s";
      RuntimeDirectory = "readest-opds";
      RuntimeDirectoryMode = "0755";
      RuntimeDirectoryPreserve = "yes";
      UMask = "0077";
      Nice = 10;
      NoNewPrivileges = true;
      PrivateTmp = true;
      PrivateDevices = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      TemporaryFileSystem = [ "/mnt:ro" ];
      BindReadOnlyPaths = [ "${bookDirectory}:/srv/readest-books" ];
      InaccessiblePaths = [
        "-/run/secrets"
        "-/run/user"
        "-/run/docker.sock"
      ];
      RestrictSUIDSGID = true;
      RestrictAddressFamilies = [ "AF_UNIX" ];
      CapabilityBoundingSet = "";
    };
  };
}
