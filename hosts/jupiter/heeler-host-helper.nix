{
  config,
  inputs,
  lib,
  pkgs,
  ...
}:
let
  helper = pkgs.callPackage ../../pkgs/heeler-host-helper { src = inputs.heeler; };
  directory = "${config.xdg.dataHome}/heeler/host-helper";
  app = "${directory}/app";
  extension = "${helper}/extensions/heeler-session.js";
in
{
  home.file = {
    ".pi/agent/extensions/heeler-session.js".source = extension;
    ".omp/agent/extensions/heeler-session.js".source = extension;
  };

  systemd.user.services.heeler-host-helper = {
    Unit.Description = "Heeler Host Helper";
    Install.WantedBy = [ "default.target" ];
    Service = {
      UMask = "0077";
      # Heeler は app の実ファイルをハッシュで照合する。通知の登録先はその親にある。
      ExecStartPre = [
        ''${lib.getExe' pkgs.coreutils "install"} -d -m 0700 "${directory}" "${app}"''
        ''${lib.getExe pkgs.rsync} --archive --checksum --delay-updates --delete-delay --chmod=D700,F600 "${helper}/" "${app}/"''
      ];
      ExecStart = ''"${lib.getExe pkgs.nodejs_24}" "${app}/main.js"'';
      Restart = "always";
      RestartSec = 1;
    };
  };
}
