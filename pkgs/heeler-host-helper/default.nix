{
  lib,
  runCommand,
  nodejs_24,
  src,
}:
let
  helper = "${src}/plugin/helper";
  inherit (lib.importJSON (src + "/plugin/helper/version.json")) version;
in
runCommand "heeler-host-helper-${version}"
  {
    nativeBuildInputs = [ nodejs_24 ];
    meta.license = lib.licenses.asl20;
  }
  ''
    node ${src}/scripts/generate-host-helper-manifest.mjs --check
    mkdir -p "$out"
    cp -R ${helper}/. "$out/"
  ''
