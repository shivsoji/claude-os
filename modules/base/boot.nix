{ config, pkgs, lib, ... }:

{
  # Bootloader: let the VM module handle this when virtualised
  # For bare-metal, systemd-boot will be configured in hardware-configuration.nix
  boot.loader.grub.enable = lib.mkDefault false;

  # Use latest kernel for best hardware support
  boot.kernelPackages = pkgs.linuxPackages_latest;

  # Kernel modules for VM and hardware support
  boot.initrd.availableKernelModules = [
    "virtio_pci"
    "virtio_scsi"
    "virtio_blk"
    "virtio_net"
    "ahci"
    "xhci_pci"
    "sd_mod"
    "sr_mod"
  ];

  # tmpfs for /tmp
  boot.tmp.useTmpfs = true;
}
