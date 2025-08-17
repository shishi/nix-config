{
  config,
  pkgs,
  lib,
  ...
}:

let
  # yaskkserv2のパッケージ定義
  yaskkserv2 = pkgs.rustPlatform.buildRustPackage rec {
    pname = "yaskkserv2";
    version = "0.1.7";

    src = pkgs.fetchFromGitHub {
      owner = "wachikun";
      repo = "yaskkserv2";
      rev = version;
      sha256 = "sha256-Qa0j5wDPGYmVrgXfJxbCbgDQrMNJULnF1/eDzMhXeRk=";
    };

    cargoSha256 = "sha256-IqWdpMKAOIJMaglsqLlE+jp/DUL5lDCJ8szyDmsy1eo=";

    # ビルド時に必要な依存関係
    buildInputs = with pkgs; [
      openssl
    ];

    nativeBuildInputs = with pkgs; [
      pkg-config
    ];
  };

  # SKK辞書の場所
  skkDictDir = "${config.home.homeDirectory}/skk";
  skkDictL = "${skkDictDir}/SKK-JISYO.L";
  yaskkservDict = "${skkDictDir}/yaskkserv2.dictionary";
in
{
  home.packages = [ yaskkserv2 ];

  # SKK辞書のダウンロードと変換スクリプト
  home.activation.setupYaskkserv2 = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    # SKK辞書ディレクトリの作成
    mkdir -p ${skkDictDir}

    # SKK-JISYO.Lのダウンロード(存在しない場合)
    if [ ! -f ${skkDictL} ]; then
      echo "Downloading SKK-JISYO.L..."
      ${pkgs.curl}/bin/curl -L -o ${skkDictL} \
        https://raw.githubusercontent.com/skk-dev/dict/master/SKK-JISYO.L
    fi

    # yaskkserv2用辞書の作成(更新チェック付き)
    if [ ! -f ${yaskkservDict} ] || [ ${skkDictL} -nt ${yaskkservDict} ]; then
      echo "Creating yaskkserv2 dictionary..."
      ${yaskkserv2}/bin/yaskkserv2_make_dictionary \
        ${yaskkservDict} ${skkDictL}
    fi
  '';

  # systemdユーザーサービスの設定
  systemd.user.services.yaskkserv2 = {
    Unit = {
      Description = "Yet Another SKK server";
      After = [ "network.target" ];
    };

    Service = {
      Type = "simple";
      ExecStart = "${yaskkserv2}/bin/yaskkserv2 --port 1178 --google-japanese-input=last --google-suggest ${yaskkservDict}";
      Restart = "always";
      RestartSec = 3;
    };

    Install = {
      WantedBy = [ "default.target" ];
    };
  };
}
