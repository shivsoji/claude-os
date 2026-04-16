{ config, pkgs, lib, ... }:

{
  # Ensure platform directory exists with correct ownership
  systemd.tmpfiles.rules = [
    "d /var/lib/claude-os/platform 0755 claude users -"
    "d /var/lib/claude-os/platform/src 0755 claude users -"
    "d /var/lib/claude-os/platform/src/db 0755 claude users -"
    "d /var/lib/claude-os/platform/src/engine 0755 claude users -"
  ];

  # Platform API systemd service
  systemd.services.claude-os-platform = {
    description = "Claude-OS Managed Agents Platform API";
    wantedBy = [ "multi-user.target" ];
    after = [
      "claude-os-bootstrap.service"
      "claude-os-master.service"
      "claude-os-memory-init.service"
      "ollama.service"
    ];
    wants = [ "ollama.service" ];

    serviceConfig = {
      Type = "simple";
      User = "claude";
      Group = "users";
      Restart = "always";
      RestartSec = 5;
      StandardOutput = "journal";
      StandardError = "journal";
      ProtectSystem = "no";
    };

    path = with pkgs; [ nodejs_22 git jq sqlite curl ];
    environment = {
      HOME = "/home/claude";
      NPM_CONFIG_PREFIX = "/home/claude/.npm-global";
      CLAUDE_OS_STATE = "/var/lib/claude-os";
      OLLAMA_URL = "http://127.0.0.1:11434";
      PLATFORM_PORT = "8420";
      NODE_ENV = "production";
    };

    script = ''
      PLATFORM_DIR="/var/lib/claude-os/platform"
      SRC_DIR="$PLATFORM_DIR/src"

      # Ensure dirs exist and are writable
      mkdir -p "$SRC_DIR/db" "$SRC_DIR/engine" "$PLATFORM_DIR/node_modules"

      # Copy platform source (install -m to force overwrite)
      install -m 644 ${../../platform/package.json} "$PLATFORM_DIR/package.json"
      install -m 644 ${../../platform/src/server.ts} "$SRC_DIR/server.ts"
      install -m 644 ${../../platform/src/db/schema.sql} "$SRC_DIR/db/schema.sql"
      install -m 644 ${../../platform/src/db/index.ts} "$SRC_DIR/db/index.ts"
      install -m 644 ${../../platform/src/engine/executor.ts} "$SRC_DIR/engine/executor.ts"

      # Portal
      mkdir -p "$PLATFORM_DIR/portal"
      install -m 644 ${../../platform/portal/index.html} "$PLATFORM_DIR/portal/index.html"

      # Install dependencies
      cd "$PLATFORM_DIR"
      export PATH="/home/claude/.npm-global/bin:$PATH"
      npm install --omit=dev 2>&1 || true

      # Start the server
      exec node --experimental-strip-types src/server.ts
    '';
  };

  # Open firewall port
  networking.firewall.allowedTCPPorts = [ 8420 ];

  # Register platform as a capability
  systemd.services.claude-os-platform-register = {
    description = "Register Platform in Genome";
    wantedBy = [ "multi-user.target" ];
    after = [ "claude-os-bootstrap.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      User = "claude";
      Group = "users";
    };
    script = ''
      GENOME="/var/lib/claude-os/genome/manifest.json"
      [ -f "$GENOME" ] || exit 0

      if ! ${pkgs.jq}/bin/jq -e '.capabilities | index("managed-agents")' "$GENOME" >/dev/null 2>&1; then
        tmp=$(mktemp)
        ${pkgs.jq}/bin/jq '.capabilities += ["managed-agents","platform-api","agent-orchestration"]' \
          "$GENOME" > "$tmp" && mv "$tmp" "$GENOME"
      fi
    '';
  };
}
