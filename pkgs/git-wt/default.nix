{
  lib,
  buildGoModule,
  fetchFromGitHub,
}:

buildGoModule rec {
  pname = "git-wt";
  version = "0.18.0";

  src = fetchFromGitHub {
    owner = "k1LoW";
    repo = "git-wt";
    rev = "v${version}";
    hash = "sha256-Oau5JkAFtly6dN9ziMrwuqOI8wD/ZqA2nkdhfHT4ez4=";
  };

  vendorHash = "sha256-LkyH7czzBkiyAYGrKuPSeB4pNAZLmgwXgp6fmYBps6s=";

  # テストは git コマンドを必要とするが、nix サンドボックスでは利用不可のためスキップ
  doCheck = false;

  # ldflags でバージョン情報を埋め込む
  ldflags = [
    "-s"
    "-w"
    "-X github.com/k1LoW/git-wt/version.Version=${version}"
  ];

  meta = with lib; {
    description = "A Git subcommand that makes git worktree simple";
    homepage = "https://github.com/k1LoW/git-wt";
    license = licenses.mit;
    maintainers = [ ];
    mainProgram = "git-wt";
  };
}
