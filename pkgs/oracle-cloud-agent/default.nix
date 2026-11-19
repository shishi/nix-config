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
  release = "1.63.0-9_134";
  sha512 = "eecab21c3f26a4721aa8ebaf74a67a9aae51e3f5a2c56c7182db4d58cf49af18d63e62717cda15b7197a27dcca27f7269bcbf9526a7aa2e93ee9d5f8f134e698";
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
