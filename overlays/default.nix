# オーバーレイの例（無害）
final: prev: {
  # ezaを使ったlsの置き換え
  ll = prev.writeShellScriptBin "ll" ''
    ${prev.eza}/bin/eza -la --icons --git $@
  '';
  
  # カスタムvimの設定例（将来用）
  # vim-custom = prev.vim_configurable.customize {
  #   name = "vim";
  #   vimrcConfig.customRC = ''
  #     set number
  #     set relativenumber
  #   '';
  # };
}