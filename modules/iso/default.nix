{ config, pkgs, lib, modulesPath, ... }:

{
  imports = [
    "${modulesPath}/installer/cd-dvd/installation-cd-minimal.nix"
  ];

  # ISO label
  image.fileName = lib.mkForce "claude-os-${config.system.nixos.release}-${pkgs.stdenv.hostPlatform.system}.iso";
  isoImage.volumeID = lib.mkForce "CLAUDE-OS";
  isoImage.squashfsCompression = "zstd -Xcompression-level 6";

  # First-run setup script
  environment.systemPackages = with pkgs; [
    (writeShellScriptBin "claude-os-install" ''
      echo "============================================"
      echo "  Claude-OS Installer"
      echo "============================================"
      echo ""
      echo "This will install Claude-OS to your disk."
      echo "WARNING: This will ERASE the target disk."
      echo ""

      # List available disks
      echo "Available disks:"
      lsblk -d -o NAME,SIZE,MODEL | grep -v "loop\|sr\|ram"
      echo ""

      read -p "Target disk (e.g., sda, nvme0n1): " DISK
      [ -z "$DISK" ] && { echo "No disk specified. Aborting."; exit 1; }
      DISK="/dev/$DISK"
      [ -b "$DISK" ] || { echo "Device $DISK not found. Aborting."; exit 1; }

      read -p "This will ERASE $DISK. Type YES to confirm: " CONFIRM
      [ "$CONFIRM" = "YES" ] || { echo "Aborted."; exit 1; }

      echo ""
      echo "Partitioning $DISK..."

      # GPT partition table: 512MB EFI + rest as root
      parted "$DISK" -- mklabel gpt
      parted "$DISK" -- mkpart ESP fat32 1MiB 512MiB
      parted "$DISK" -- set 1 esp on
      parted "$DISK" -- mkpart primary ext4 512MiB -8GiB
      parted "$DISK" -- mkpart primary linux-swap -8GiB 100%

      # Detect partition naming
      if [[ "$DISK" == *nvme* ]] || [[ "$DISK" == *mmcblk* ]]; then
        PART1="''${DISK}p1"
        PART2="''${DISK}p2"
        PART3="''${DISK}p3"
      else
        PART1="''${DISK}1"
        PART2="''${DISK}2"
        PART3="''${DISK}3"
      fi

      echo "Formatting..."
      mkfs.fat -F 32 -n boot "$PART1"
      mkfs.ext4 -L nixos "$PART2"
      mkswap -L swap "$PART3"

      echo "Mounting..."
      mount "$PART2" /mnt
      mkdir -p /mnt/boot
      mount "$PART1" /mnt/boot
      swapon "$PART3"

      echo "Generating NixOS configuration..."
      nixos-generate-config --root /mnt

      echo ""
      echo "Base config generated at /mnt/etc/nixos/"
      echo ""
      echo "To install Claude-OS, copy the flake and run:"
      echo "  nixos-install --flake /path/to/claude-os#claude-os"
      echo ""
      echo "Or for a quick install with the generated config:"
      echo "  nixos-install"
      echo ""
    '')
  ];

  # Auto-start message on boot from ISO
  services.getty.helpLine = lib.mkForce ''

    ██████╗██╗      █████╗ ██╗   ██╗██████╗ ███████╗       ██████╗ ███████╗
   ██╔════╝██║     ██╔══██╗██║   ██║██╔══██╗██╔════╝      ██╔═══██╗██╔════╝
   ██║     ██║     ███████║██║   ██║██║  ██║█████╗  █████╗██║   ██║███████╗
   ██║     ██║     ██╔══██║██║   ██║██║  ██║██╔══╝  ╚════╝██║   ██║╚════██║
   ╚██████╗███████╗██║  ██║╚██████╔╝██████╔╝███████╗      ╚██████╔╝███████║
    ╚═════╝╚══════╝╚═╝  ╚═╝ ╚═════╝ ╚═════╝ ╚══════╝       ╚═════╝╚══════╝

    AI-Native Operating System

    Login as 'claude' (password: claude-os) to start.
    Run 'claude-os-install' to install to disk.

  '';
}
