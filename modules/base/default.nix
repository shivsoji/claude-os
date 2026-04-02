{ config, pkgs, lib, ... }:

{
  imports = [
    ./boot.nix
    ./hardware.nix
    ./networking.nix
    ./users.nix
    ./nix-settings.nix
  ];

  # System identity
  system.stateVersion = "24.11";

  # Base system packages available to all users
  environment.systemPackages = with pkgs; [
    # Core utilities
    coreutils
    curl
    wget
    git
    jq
    sqlite
    htop
    tmux
    tree
    file
    unzip
    ripgrep
    fd

    # System tools
    inotify-tools
    socat
    procps
    util-linux
    pciutils
    usbutils
    lsof

    # Editors (fallback)
    vim

    # Node.js (for Claude Code and MCP servers)
    # nodejs_22 includes npm by default
    nodejs_22
  ];

  # Enable dbus (required for many system services)
  services.dbus.enable = true;

  # Timezone and locale
  time.timeZone = "UTC";
  i18n.defaultLocale = "en_US.UTF-8";

  # Console configuration
  console = {
    font = "Lat2-Terminus16";
    keyMap = "us";
  };
}
