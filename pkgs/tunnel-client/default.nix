{
  lib,
  stdenvNoCC,
  fetchurl,
  unzip,
}:
let
  # Renovate が tag と配布物の SHA-256 を一緒に更新するので、この 2 行は隣接させて書く。
  tag = "v0.0.16";
  sha256 = "d60cdba019bce451bcc3a15478cc5b9cb11270b049f5b56ea39a80b517f8b117";
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
