{
  description = "A Ruby project that follows .ruby-version";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    systems.url = "github:nix-systems/default";
    # nixpkgs は意図的に follows しない。上流 pin でビルドされた成果物のみが
    # nixpkgs-ruby.cachix.org にあるため、follows すると ruby がソースビルドに落ちる。
    nixpkgs-ruby.url = "github:bobvanderlinden/nixpkgs-ruby";
  };

  outputs =
    inputs@{ flake-parts, systems, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = import systems;

      perSystem =
        { pkgs, system, ... }:
        let
          # .ruby-version をそのまま解釈してパッチ単位で解決する。
          # 注意: flake は git 管理下のファイルしか見ないため .ruby-version は git add が必要。
          ruby = inputs.nixpkgs-ruby.lib.packageFromRubyVersionFile {
            file = ./.ruby-version;
            inherit system;
          };

          # ruby 本体がビルドされた nixpkgs。ネイティブ拡張のビルドに関わるもの
          # (コンパイラ、および拡張がリンクするライブラリ)は必ずこちらから取る。
          # 揃えないと .so が新しい glibc でビルドされ、実行時は ruby 側の古い
          # glibc が載るため、新しい側にしかないシンボルを掴んだ gem が require で
          # 落ちる(GLIBC_ABI_* not found)。
          #   ライブラリを足す例: rubyPkgs.libyaml / rubyPkgs.postgresql
          #   ABI に関わらない道具(linter 等)は unstable の pkgs から取ってよい。
          rubyPkgs = inputs.nixpkgs-ruby.inputs.nixpkgs.legacyPackages.${system};
        in
        {
          devShells.default = (pkgs.mkShell.override { stdenv = rubyPkgs.stdenv; }) {
            packages = [
              ruby
              rubyPkgs.pkg-config
            ];

            # gem の置き場所を「この ruby ビルド」ごとに分ける。
            # 鍵に store path を使う理由: バージョン文字列が同じでもビルドが違えば
            # ネイティブ拡張が焼き込む libruby / glibc の RUNPATH が変わり、
            # 混在すると require 時に LoadError になる。
            # 置き場所が .git の中なので worktree 間で自動的に共有され、
            # git は自分のディレクトリを追跡しないので .gitignore も要らない。
            shellHook = ''
              # 絶対パス化は cd + pwd で行う(--path-format は git 2.31+ 限定で、
              # 古い git だと静かに非 git 扱いへ落ちてリポジトリ内に gem 木ができる)。
              # CDPATH= と -P は必須: CDPATH が設定されていると cd が別リポジトリの
              # .git へ飛び、さらに移動先を stdout に印字して値が壊れる。
              # -P は symlink 経由の checkout で本体と worktree の鍵が割れるのも防ぐ。
              if git_common=$(git rev-parse --git-common-dir 2>/dev/null) && [ -n "$git_common" ] \
                && git_common=$(CDPATH= cd -P -- "$git_common" 2>/dev/null && pwd) \
                && [ -n "$git_common" ]; then
                gem_root="$git_common/gem"
              else
                gem_root="$PWD/.nix-gem"
                echo "warning: git repo として解決できないため $gem_root を使います" >&2
              fi

              # bundler は BUNDLE_PATH の下に <engine>/<API バージョン>/ を掘る。
              # GEM_HOME をその実体に合わせて、gem install と bundle install を同じ木に集める。
              BUNDLE_PATH="$gem_root/${baseNameOf ruby}"
              export BUNDLE_PATH
              GEM_HOME="$BUNDLE_PATH/$(ruby -e 'print "#{Gem.ruby_engine}/#{Gem.ruby_api_version}"')"
              export GEM_HOME
              # 読み込み経路も閉じる。既定では Gem.path に共有の
              # ~/.local/share/gem/ruby/<API バージョン> が残り、そこ経由で混線しうる。
              # ただし ruby 同梱の gem 置き場(Gem.default_dir)は残すこと。落とすと
              # bundled gems(csv / rake / debug 等)が require できなくなる。
              # 末尾に : を付けないこと(付けると rubygems が共有ディレクトリを足し戻す)。
              GEM_PATH="$GEM_HOME:$(ruby -e 'print Gem.default_dir')"
              export GEM_PATH
              export PATH="$GEM_HOME/bin:$PATH"

              echo "ruby $(ruby -e 'print RUBY_VERSION')  gems: $GEM_HOME"
            '';
          };
        };
    };
}
