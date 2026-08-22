# 実機で `nixos-generate-config --show-hardware-config --no-filesystems` を実行した
# 出力(2026-08-22 取得)。ファイルシステムは hosts/jupiter/disko.nix が宣言する
# のでここには無い。initrd の USB イーサドライバもここには出ないため、
# hosts/jupiter/default.nix の boot.initrd.availableKernelModules で宣言する。
{
  config,
  lib,
  modulesPath,
  ...
}:
{
  imports = [ (modulesPath + "/installer/scan/not-detected.nix") ];

  boot.initrd.availableKernelModules = [
    "nvme"
    "xhci_pci"
    "thunderbolt"
    "usbhid"
    "usb_storage"
    "sd_mod"
    "rtsx_pci_sdmmc"
  ];
  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [ "kvm-amd" ];
  boot.extraModulePackages = [ ];

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
  hardware.cpu.amd.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;
}
