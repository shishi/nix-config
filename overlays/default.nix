# オーバーレイの実用例
#
# Overlayの意味：
# - Nixpkgsの既存パッケージセットを「上書き」する仕組み
# - グローバルに適用され、すべての場所で変更が反映される
# - 例：gitをカスタマイズすると、他のパッケージが依存するgitも変更される
#
# 独自コマンドとの違い：
# - 独自コマンド：単に新しいコマンドを追加（pkgs/に置く）
# - Overlay：既存パッケージの動作を変更・拡張できる
#
# final と prev の意味：
# - prev: 前の（元の）パッケージセット。Nixpkgsの標準パッケージ
# - final: 最終的なパッケージセット。すべてのOverlayが適用された後の状態
#
# 例：
# - prev.git = Nixpkgsの標準のgit
# - final.git = このOverlayで変更したgit（他のパッケージが参照する）
#
# 循環参照を避けるため：
# - 他のパッケージを参照する時は基本的にprevを使う
# - finalは自己参照や、明確に「最終版」が必要な時のみ使う
#
final: prev: {
  # 1. 既存パッケージにパッチを適用する例
  # neovim = prev.neovim.overrideAttrs (oldAttrs: {
  #   patches = (oldAttrs.patches or []) ++ [
  #     ./patches/neovim-custom.patch
  #   ];
  # });

  # 2. パッケージのビルドオプションを変更する例
  # ffmpeg = prev.ffmpeg.override {
  #   withFdkAac = true;  # AACエンコーダを有効化
  #   withVpx = true;     # VP8/VP9コーデックを有効化
  # };

  # 3. 特定バージョンに固定する例
  # nodejs = prev.nodejs_18;  # Node.js 18系に固定

  # 4. 環境変数を設定してパッケージをラップする例
  # docker = prev.symlinkJoin {
  #   name = "docker-wrapped";
  #   paths = [ prev.docker ];
  #   buildInputs = [ prev.makeWrapper ];
  #   postBuild = ''
  #     wrapProgram $out/bin/docker \
  #       --set DOCKER_HOST "unix:///run/user/1000/docker.sock"
  #   '';
  # };

  # 5. 既存のgitコマンドを拡張する例（これがOverlayの真価）
  # 具体例で理解する：
  # - 誰かが `nix-shell -p git vim` を実行
  # - vimがgitを内部で使う（git commit時のエディタなど）
  # - この時、両方とも「このOverlayで拡張されたgit」が使われる
  # git = prev.symlinkJoin {
  #   # symlinkJoin: 複数のパッケージを1つのディレクトリにまとめる関数
  #   # すべてのファイルへのシンボリックリンクを作成する
  #   name = "git"; # 新しいパッケージの名前
  #   paths = [ prev.git ]; # 元のgitパッケージのすべてのファイルをコピー
  #   buildInputs = [ prev.makeWrapper ]; # wrapProgramコマンドを使うために必要
  #   postBuild = ''
  #     # wrapProgram: 既存のプログラムをラッパースクリプトで包む
  #     # $out/bin/git が実行される時、以下の設定が自動適用される
  #     wrapProgram $out/bin/git \
  #       --set GIT_MERGE_AUTOEDIT "no" \      # 環境変数を設定
  #       --add-flags "-c color.ui=always"      # コマンドライン引数を追加
  #     # git-cleanupサブコマンドを追加
  #     # Gitは$PATH上のgit-*という名前の実行ファイルを
  #     # 自動的にサブコマンドとして認識する
  #     cat > $out/bin/git-cleanup << 'EOF'
  #     #!/bin/sh
  #     echo "🧹 Cleaning up merged branches..."
  #     git branch --merged | grep -v "\*\|main\|master" | xargs -r git branch -d
  #     echo "✅ Done!"
  #     EOF
  #     chmod +x $out/bin/git-cleanup
  #   '';
  # };

  # 6. Pythonパッケージをカスタマイズする例
  # python3 = prev.python3.override {
  #   packageOverrides = self: super: {
  #     requests = super.requests.overridePythonAttrs (old: {
  #       version = "2.31.0";  # 特定バージョンに固定
  #     });
  #   };
  # };

  # 7. デスクトップアプリケーションの設定を変更する例
  # vscode = prev.vscode.overrideAttrs (oldAttrs: {
  #   postInstall = oldAttrs.postInstall or "" + ''
  #     # デフォルト設定ファイルを追加
  #     mkdir -p $out/share/vscode/
  #     cp ${./configs/vscode-settings.json} $out/share/vscode/settings.json
  #   '';
  # });
}
