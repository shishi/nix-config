{
  config,
  pkgs,
  lib,
  ...
}:

let
  # nixpkgs にまだないGoパッケージをビルドするサンプル
  # buildGoModule を使って GitHub などから直接ビルドできるよ！

  # git-wt: git worktree を簡単に操作するツール
  # https://github.com/k1LoW/git-wt
  git-wt = pkgs.buildGoModule rec {
    pname = "git-wt";
    version = "0.15.0";

    src = pkgs.fetchFromGitHub {
      owner = "k1LoW";
      repo = "git-wt";
      rev = "v${version}";
      hash = "sha256-A8vkwa8+RfupP9UaUuSVjkt5HtWvqR5VmSsVg2KpeMo=";
    };

    vendorHash = "sha256-K5geAvG+mvnKeixOyZt0C1T5ojSBFmx2K/Msol0HsSg=";

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
    };
  };

  # サンプル: buildGoModule の使い方
  # exampleTool = pkgs.buildGoModule rec {
  #   pname = "example-tool";
  #   version = "1.0.0";
  #
  #   src = pkgs.fetchFromGitHub {
  #     owner = "example";
  #     repo = "example-tool";
  #     rev = "v${version}"; # タグを指定（コミットハッシュでもOK）
  #     hash = lib.fakeHash; # 最初はfakeHashで実行してエラーから取得
  #   };
  #
  #   # go.sum から計算されるハッシュ
  #   # 最初は lib.fakeHash を使って、エラーメッセージから正しいハッシュを取得する
  #   vendorHash = lib.fakeHash;
  #   # vendorHash = null; # vendor ディレクトリがある場合
  #
  #   # ビルドするサブパッケージを指定（省略可）
  #   # subPackages = [ "cmd/example-tool" ];
  #
  #   # ビルド時のタグ（省略可）
  #   # tags = [ "netgo" ];
  #
  #   # ldflags でバージョン情報を埋め込む（省略可）
  #   # ldflags = [ "-s" "-w" "-X main.version=${version}" ];
  #
  #   # テストを無効にする場合（ネットワークアクセスが必要なテストがある場合など）
  #   # doCheck = false;
  #
  #   meta = with lib; {
  #     description = "Example tool description";
  #     homepage = "https://github.com/example/example-tool";
  #     license = licenses.mit;
  #   };
  # };

in
{
  home.packages = [
    git-wt
  ];
}
