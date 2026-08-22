# ★スタブ(checks を通すための仮置き)。
# インストール前ゲート 2: installer 起動した実機から
#   nixos-generate-config --no-filesystems --show-hardware-config
# で実物を取得して置き換えるまで、インストールに進むことは禁止。
#
# インストール前ゲート 3: ゲート 2 で実物に置き換えても、initrd の NIC
# ドライバはここから得られない(nixos-generate-config が出すのはストレージ・
# 入力系が中心)。この機体には有線 LAN ポートが無く、遠隔復旧(initrd SSH)は
# USB イーサネットアダプタを挿す前提にしてある。ドライバの集合は
# hosts/jupiter/default.nix の boot.initrd.availableKernelModules 側で宣言済み。
# 使うアダプタがその集合に含まれることだけ、一度確認する:
#   basename $(readlink /sys/class/net/<iface>/device/driver)
{ lib, modulesPath, ... }:
{
  imports = [ (modulesPath + "/installer/scan/not-detected.nix") ];
  boot.initrd.availableKernelModules = [
    "nvme"
    "xhci_pci"
    "usb_storage"
    "sd_mod"
  ];
  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
}
