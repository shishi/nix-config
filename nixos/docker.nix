{ lib, ... }:
{
  # 有効化はホスト判断(jupiter = true)。TCP 公開はしない
  virtualisation.docker.enable = lib.mkDefault false;
}
