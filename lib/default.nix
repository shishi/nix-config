{ pkgs }:

{
  # OSごとの条件分岐
  # 使用例: myLib.osCase { linux = "firefox"; darwin = "Safari"; }
  # OS判定は pkgs.stdenv.isLinux / pkgs.stdenv.isDarwin を直接使うこと
  osCase =
    {
      linux ? null,
      darwin ? null,
      default ? null,
    }:
    if pkgs.stdenv.isLinux then
      linux
    else if pkgs.stdenv.isDarwin then
      darwin
    else
      default;

  # カラースキーム（Gruvbox Dark）
  colors = {
    base16 = {
      base00 = "#282828"; # background
      base01 = "#3c3836"; # lighter background
      base02 = "#504945"; # selection background
      base03 = "#665c54"; # comments
      base04 = "#bdae93"; # dark foreground
      base05 = "#d5c4a1"; # foreground
      base06 = "#ebdbb2"; # light foreground
      base07 = "#fbf1c7"; # white
      base08 = "#fb4934"; # red
      base09 = "#fe8019"; # orange
      base0A = "#fabd2f"; # yellow
      base0B = "#b8bb26"; # green
      base0C = "#8ec07c"; # cyan
      base0D = "#83a598"; # blue
      base0E = "#d3869b"; # purple
      base0F = "#d65d0e"; # brown
    };
  };
}
