{
  lib,
  stdenvNoCC,
  fetchurl,
  unzip,
}:
stdenvNoCC.mkDerivation rec {
  pname = "tunnel-client";
  version = "0.0.16";
  src = fetchurl {
    url = "https://github.com/openai/tunnel-client/releases/download/v${version}/tunnel-client-v${version}-linux-amd64.zip";
    hash = "sha256-1gzboBm85FG8w6FUeMxbnLEScLBJ9bVuo5qAtRf4sRc=";
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
