{
  config,
  pkgs,
  lib,
  ...
}:

let
  # nixpkgs にまだないGoパッケージをビルドするサンプル
  # buildGoModule を使って GitHub などから直接ビルドできるよ！

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
}
