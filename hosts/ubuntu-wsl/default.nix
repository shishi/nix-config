# 現 WSL Ubuntu(hostname: earth)の standalone HM 束ね。
# フラグ値と standalone 専用機能はここだけに置く(home/ は可搬層のまま保つ)
{ lib, ... }:
{
  imports = [
    ../../home
    ../../home/profiles/wsl-gui.nix
  ];

  # yaskkserv2 は earth では無効: Windows 側 CorvusSKK が
  # port 1178 を保持しており(mirrored networking でポート空間共有)、
  # 日本語入力は Windows 側で完結している実測に基づく。jupiter では有効
  my.skk.enable = false;
  my.shell = "fish";

  # standalone 専用: HM CLI(統合 NixOS ホストでは第 2 適用経路になるため禁止)
  programs.home-manager.enable = true;

  # standalone 専用: nh(HM モジュール)。NixOS ホストは NixOS 側 programs.nh を使う
  programs.nh = {
    enable = true;
    flake = "/home/shishi/dev/src/github.com/shishi/nix-config";
    clean = {
      enable = true;
      dates = "weekly";
      extraArgs = "--keep 5 --keep-since 4d";
    };
  };

  # self-guard: 統合 NixOS ホスト上で standalone プロファイルを誤適用しない。
  # (NixOS 側 programs.nh の NH_FLAKE は nh home にも波及するため、
  #  コマンド側でなく構成側で塞ぐ)
  home.activation.guardStandaloneOnNixos = lib.hm.dag.entryBefore [ "writeBoundary" ] ''
    if [ -e /etc/NIXOS ]; then
      echo "ERROR: this standalone home profile must not be activated on an integrated NixOS host" >&2
      exit 1
    fi
  '';
}
