{ ... }:
{
  flake.templates = {
    basic = {
      path = ../templates/basic;
      description = "Basic development shell template";
    };
    rust = {
      path = ../templates/rust;
      description = "Rust development template (fenix toolchain)";
    };
    ruby = {
      path = ../templates/ruby;
      description = "Ruby development template (.ruby-version tracking via nixpkgs-ruby)";
      welcomeText = ''
        # 使い方

        1. .ruby-version をプロジェクトの版に書き換える
        2. git add .ruby-version flake.nix .envrc
           flake は git 管理下のファイルしか見ないため、add しないと .ruby-version を読めません
        3. direnv allow  (または nix develop)

        # gem の置き場所

        <repo>/.git/gem/<ruby の store path 名>/<engine>/<API バージョン>/ に入ります。
        ruby のビルドごとに分かれるので混線せず、worktree 間では共有されます
        (worktree を作っても bundle install をやり直す必要はありません)。
        ruby を上げると古い鍵のディレクトリが残るので、不要になったら削除してください。

        # 既存プロジェクトに入れるときの注意

        - すでに .ruby-version がある場合、nix flake init は上書きを拒んでそこで止まります。
          自分の .ruby-version を一時退避してから実行し、あとで戻してください。
          中断時にすでに書かれた flake.nix / .envrc は、内容が同じなら再実行時に
          スキップされるのでそのままで構いません。
        - .bundle/config に BUNDLE_PATH がある場合、そちらが環境変数より優先されます。
          gem install と bundle install が別の場所に分かれるので、その行は削除してください。

        # ネイティブ拡張を使うとき

        拡張がリンクするライブラリは flake.nix の rubyPkgs から取ってください
        (pkgs から取ると ruby 本体と glibc が食い違い、require 時に落ちます)。
      '';
    };
  };
}
