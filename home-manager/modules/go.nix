{
  config,
  pkgs,
  lib,
  ...
}:

let
  # nixpkgs にまだないGoパッケージをビルドするサンプル
  # buildGoModule を使って GitHub などから直接ビルドできるよ！

  # サンプル1: シンプルなパターン
  # exampleTool = pkgs.buildGoModule rec {
  #   pname = "example-tool";
  #   version = "1.0.0";
  #
  #   src = pkgs.fetchFromGitHub {
  #     owner = "example";
  #     repo = "example-tool";
  #     rev = "v${version}"; # タグを指定（コミットハッシュでもOK）
  #     hash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="; # 最初は空で実行してエラーから取得
  #   };
  #
  #   # go.sum から計算されるハッシュ
  #   # 最初は lib.fakeHash を使って、エラーメッセージから正しいハッシュを取得する
  #   vendorHash = lib.fakeHash;
  #   # vendorHash = "sha256-BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=";
  #   # vendorHash = null; # vendor ディレクトリがある場合
  #
  #   # ビルドするサブパッケージを指定（省略可）
  #   # subPackages = [ "cmd/example-tool" ];
  #
  #   # ビルド時のタグ（省略可）
  #   # tags = [ "netgo" ];
  #
  #   # ldflags でバージョン情報を埋め込む（省略可）
  #   # ldflags = [
  #   #   "-s" "-w"
  #   #   "-X main.version=${version}"
  #   # ];
  #
  #   meta = with lib; {
  #     description = "Example tool description";
  #     homepage = "https://github.com/example/example-tool";
  #     license = licenses.mit;
  #   };
  # };

  # サンプル2: 実際に使えるパターン（ghq など）
  # ghq = pkgs.buildGoModule rec {
  #   pname = "ghq";
  #   version = "1.6.2";
  #
  #   src = pkgs.fetchFromGitHub {
  #     owner = "x-motemen";
  #     repo = "ghq";
  #     rev = "v${version}";
  #     hash = "sha256-xxx...";
  #   };
  #
  #   vendorHash = "sha256-yyy...";
  #
  #   # テストを無効にする場合（ネットワークアクセスが必要なテストがある場合など）
  #   doCheck = false;
  # };

in
{
  # home.packages = [
  #   exampleTool
  #   # ghq
  # ];
}
