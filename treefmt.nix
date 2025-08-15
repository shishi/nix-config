{
  projectRootFile = "flake.nix";
  
  programs = {
    # Nixファイルのフォーマット
    nixpkgs-fmt.enable = true;
    
    # その他のフォーマッター（将来用）
    # prettier.enable = true;
    # rustfmt.enable = true;
  };
}