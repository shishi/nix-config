{
  lib,
  buildGoModule,
  fetchFromGitHub,
  go_1_25,
}:

buildGoModule.override { go = go_1_25; } rec {
  pname = "git-wt";
  version = "0.29.0";

  src = fetchFromGitHub {
    owner = "k1LoW";
    repo = "git-wt";
    rev = "v${version}";
    hash = "sha256-1u0GDC1Sc4Xy4URuM6TnR/ENsdIWa94Ixu3mL6WrmFg=";
  };

  vendorHash = "sha256-ppbY3ZJo2L/FbWlOiywqk6W4kVDQKkwf5VjRHucb78A=";

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
