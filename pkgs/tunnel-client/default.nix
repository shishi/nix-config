{
  lib,
  stdenvNoCC,
  fetchurl,
  unzip,
}:
let
  # Renovate が tag と配布物の SHA-256 を一緒に更新するので、この 2 行は隣接させて書く。
  tag = "v0.0.21";
  sha256 = "9e91a539e3ae1c436d499f216a1d7514b3c86cc7779032f41b2a05821d74b03a";
in
stdenvNoCC.mkDerivation {
  pname = "tunnel-client";
  version = lib.removePrefix "v" tag;
  src = fetchurl {
    url = "https://github.com/openai/tunnel-client/releases/download/${tag}/tunnel-client-${tag}-linux-amd64.zip";
    inherit sha256;
  };
  nativeBuildInputs = [ unzip ];
  dontUnpack = true;
  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin
    unzip -j "$src" '*tunnel-client' -d $out/bin
    chmod +x $out/bin/tunnel-client
    runHook postInstall
  '';
  meta = {
    description = "OpenAI private MCP tunnel client";
    homepage = "https://github.com/openai/tunnel-client";
    license = lib.licenses.asl20;
    platforms = [ "x86_64-linux" ];
    mainProgram = "tunnel-client";
  };
}
