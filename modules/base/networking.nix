{ config, pkgs, lib, ... }:

{
  # Hostname
  networking.hostName = "claude-os";

  # NetworkManager for flexible network management
  networking.networkmanager.enable = true;

  # Firewall: allow SSH, block everything else by default
  networking.firewall = {
    enable = true;
    allowedTCPPorts = [ 22 ];
  };

  # Enable SSH for remote access
  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "no";
      PasswordAuthentication = true; # Will switch to key-only after first setup
    };
  };

  # DNS resolution
  networking.nameservers = [ "1.1.1.1" "8.8.8.8" ];
}
