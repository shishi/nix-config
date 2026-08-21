# ★スタブ(checks を通すための仮置き)。
# インストール前ゲート 2: installer 起動した実機から
#   nixos-generate-config --no-filesystems --show-hardware-config
# で実物を取得して置き換えるまで、インストールに進むことは禁止。
#
# インストール前ゲート 3: ゲート 2 で実物に置き換えた後も、これだけでは
# 遠隔復旧経路(initrd SSH)は機能しない。nixos-generate-config が出す
# availableKernelModules はストレージ・入力系が中心で、NIC ドライバは
# 通常含まれない。実機の NIC ドライバ名を
#   basename $(readlink /sys/class/net/<iface>/device/driver)
# で確認し、hosts/jupiter/default.nix の boot.initrd.availableKernelModules
# (現状 VM 用の "e1000" のみ)に追記するまで、TPM 解錠が失敗した瞬間に
# 遠隔から入れない。
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
