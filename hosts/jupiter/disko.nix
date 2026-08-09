# jupiter: LUKS2(TPM2 自動解錠はインストール後に systemd-cryptenroll で登録)
# + btrfs subvolume + zstd。デバイス名はマシン確定時に実値へ(インストール前ゲート 1)
{ ... }:
{
  disko.devices.disk.main = {
    type = "disk";
    device = "/dev/nvme0n1"; # ★実機確定時に必ず実デバイスへ変更
    content = {
      type = "gpt";
      partitions = {
        ESP = {
          size = "1G";
          type = "EF00";
          content = {
            type = "filesystem";
            format = "vfat";
            mountpoint = "/boot";
            mountOptions = [ "umask=0077" ];
          };
        };
        luks = {
          size = "100%";
          content = {
            type = "luks";
            name = "cryptroot";
            settings.allowDiscards = true;
            # nixos-anywhere の --disk-encryption-keys /tmp/secret.key <src> とペア(High-4)
            settings.keyFile = "/tmp/secret.key";
            # インストール時は --disk-encryption-keys を使用。
            # TPM2 enroll は初回起動後: sudo systemd-cryptenroll --tpm2-device=auto <dev>
            content = {
              type = "btrfs";
              extraArgs = [ "-f" ];
              subvolumes = {
                "@root" = {
                  mountpoint = "/";
                  mountOptions = [
                    "compress=zstd"
                    "noatime"
                  ];
                };
                "@home" = {
                  mountpoint = "/home";
                  mountOptions = [
                    "compress=zstd"
                    "noatime"
                  ];
                };
                "@nix" = {
                  mountpoint = "/nix";
                  mountOptions = [
                    "compress=zstd"
                    "noatime"
                  ];
                };
                "@swap" = {
                  mountpoint = "/.swap";
                  swap.swapfile.size = "16G";
                };
              };
            };
          };
        };
      };
    };
  };
}
