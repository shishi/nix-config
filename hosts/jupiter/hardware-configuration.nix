# ★スタブ(checks を通すための仮置き)。
# インストール前ゲート 2: installer 起動した実機から
#   nixos-generate-config --no-filesystems --show-hardware-config
# で実物を取得して置き換えるまで、インストールに進むことは禁止。
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
