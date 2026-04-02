{ config, pkgs, lib, ... }:

{
  # Main user account — login shell is the shell-agent
  users.users.claude = {
    isNormalUser = true;
    description = "Claude-OS User";
    extraGroups = [
      "wheel"         # sudo access
      "networkmanager" # network management
      "video"          # GPU access
      "render"         # GPU rendering
      "docker"         # Container access (when docker is enabled)
    ];
    # Login shell is set by the shell-agent module
    # Password set for initial access — should be changed on first login
    initialPassword = "claude-os";
    home = "/home/claude";
    createHome = true;
  };

  # Passwordless sudo for nix operations and system management
  security.sudo.extraRules = [
    {
      users = [ "claude" ];
      commands = [
        { command = "${pkgs.nix}/bin/nix*"; options = [ "NOPASSWD" ]; }
        { command = "/run/current-system/sw/bin/nixos-rebuild"; options = [ "NOPASSWD" ]; }
        { command = "/run/current-system/sw/bin/systemctl"; options = [ "NOPASSWD" ]; }
      ];
    }
  ];

  # Auto-login on the first TTY (direct to Claude shell)
  services.getty.autologinUser = "claude";
}
