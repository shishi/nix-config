{
  lib,
  stdenvNoCC,
  fetchurl,
  squashfsTools,
}:
let
  # Renovate が snap ストアの「版_revision」と配布物の SHA-512 を一緒に更新するので、
  # この 2 行は隣接させて書く。revision はアーキテクチャーごとに異なり、これは arm64 用。
  # 取得するアーキテクチャーは renovate.json の hostRules のヘッダーでも指定している。
  release = "1.61.0-6_125";
  sha512 = "55e18082541d9e03b4312490d42ce3fd009871111d19eecf488ce7c8593297b079337e56e27692f8034ef3b0ce148fbadadd11aceeeb8855ed526a821f11f8a6";
  releaseParts = lib.splitString "_" release;
in
stdenvNoCC.mkDerivation {
  pname = "oracle-cloud-agent";
  version = builtins.head releaseParts;
  src = fetchurl {
    url = "https://api.snapcraft.io/api/v1/snaps/download/ltx4XjES2e2ujitNIuO5GxPYDM6lp6ry_${lib.last releaseParts}.snap";
    inherit sha512;
  };
  nativeBuildInputs = [ squashfsTools ];
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
}
