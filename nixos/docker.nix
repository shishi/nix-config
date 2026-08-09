{ lib, ... }:
{
  # 有効化はホスト判断(jupiter = true)。TCP 公開はしない(#38 裁定)
  virtualisation.docker.enable = lib.mkDefault false;
}
