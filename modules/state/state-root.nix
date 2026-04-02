{ config, pkgs, lib, ... }:

{
  # Create the persistent state directory tree on boot
  systemd.tmpfiles.rules = [
    # Root state directory
    "d /var/lib/claude-os 0755 claude users -"

    # Memory subsystem
    "d /var/lib/claude-os/memory 0755 claude users -"
    "d /var/lib/claude-os/memory/facts 0755 claude users -"
    "d /var/lib/claude-os/memory/sessions 0755 claude users -"

    # Skills registry
    "d /var/lib/claude-os/skills 0755 claude users -"
    "d /var/lib/claude-os/skills/builtins 0755 claude users -"

    # Agent message bus
    "d /var/lib/claude-os/agents 0755 claude users -"
    "d /var/lib/claude-os/agents/inbox 0755 claude users -"
    "d /var/lib/claude-os/agents/outbox 0755 claude users -"

    # Awareness / monitoring data
    "d /var/lib/claude-os/awareness 0755 claude users -"

    # Event queue
    "d /var/lib/claude-os/events 0755 claude users -"

    # Session archives
    "d /var/lib/claude-os/sessions 0755 claude users -"

    # Dynamic state (accumulated packages, services, config)
    "d /var/lib/claude-os/state 0755 claude users -"

    # Backups
    "d /var/lib/claude-os/backups 0755 claude users -"
  ];

  # Seed bootstrap memory on first boot
  systemd.services.claude-os-bootstrap = {
    description = "Claude-OS First Boot Bootstrap";
    wantedBy = [ "multi-user.target" ];
    after = [ "systemd-tmpfiles-setup.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      User = "claude";
      Group = "users";
    };
    script = ''
      STATE_DIR="/var/lib/claude-os"

      # Only bootstrap if this is the first boot (no memory exists yet)
      if [ ! -f "$STATE_DIR/memory/facts/system-identity.md" ]; then
        cat > "$STATE_DIR/memory/facts/system-identity.md" << 'EOF'
---
name: System Identity
description: Core identity of this Claude-OS instance
type: system
---

# System Identity

I am Claude-OS, an AI-native operating system built on NixOS.
- Architecture: x86_64 (amd64)
- Init system: systemd
- Package manager: Nix (with flakes)
- Primary interface: Claude Code CLI
- State directory: /var/lib/claude-os/

I grow my capabilities by installing packages dynamically via Nix.
Every package I install gets a skill file so I know how to use it.
My memory persists across reboots in /var/lib/claude-os/memory/.
EOF

        # Seed the user packages file
        if [ ! -f "$STATE_DIR/state/user-packages.nix" ]; then
          cat > "$STATE_DIR/state/user-packages.nix" << 'EOF'
# Dynamically accumulated user packages
# Managed by the capability manager — do not edit manually
{ pkgs }:
with pkgs; [
  # Packages added by capability-manager will appear here
]
EOF
        fi

        # Seed the skill registry
        if [ ! -f "$STATE_DIR/skills/registry.json" ]; then
          echo '{"skills": [], "version": 1}' > "$STATE_DIR/skills/registry.json"
        fi

        # Seed tool usage tracking
        if [ ! -f "$STATE_DIR/state/tool-usage.json" ]; then
          echo '{"tools": {}, "version": 1}' > "$STATE_DIR/state/tool-usage.json"
        fi

        echo "Claude-OS bootstrap complete — first boot initialized."
      fi
    '';
  };
}
