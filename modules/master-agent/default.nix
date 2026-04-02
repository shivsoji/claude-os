{ config, pkgs, lib, ... }:

let
  claudeMdMaster = import ./claude-md-master.nix { inherit config pkgs lib; };

  # Script that watches the message bus and dispatches to Claude
  masterAgent = pkgs.writeShellScriptBin "claude-os-master" ''
    set -uo pipefail

    STATE_DIR="/var/lib/claude-os"
    AGENTS_DIR="$STATE_DIR/agents"
    INBOX="$AGENTS_DIR/inbox"
    LOG="/var/log/claude-os-master.log"

    export PATH="/home/claude/.npm-global/bin:$PATH"
    export NPM_CONFIG_PREFIX="/home/claude/.npm-global"
    export HOME="/home/claude"

    log() {
      echo "[$(date -Iseconds)] $*" >> "$LOG"
      echo "[$(date -Iseconds)] $*"
    }

    # Ensure directories exist
    mkdir -p "$INBOX" "$AGENTS_DIR/outbox" "$STATE_DIR/awareness"

    # Write master agent PID for discovery
    echo $$ > "$AGENTS_DIR/master.pid"

    # Initialize agent registry
    if [ ! -f "$AGENTS_DIR/registry.json" ]; then
      echo '{"agents":[],"version":1}' > "$AGENTS_DIR/registry.json"
    fi

    log "Master agent starting (PID $$)"

    # --- System context gathering ---
    gather_context() {
      local ctx="$STATE_DIR/awareness/system-status.json"
      {
        echo "{"
        echo "  \"timestamp\": \"$(date -Iseconds)\","
        echo "  \"uptime\": \"$(uptime -p 2>/dev/null || uptime)\","
        echo "  \"load\": \"$(cat /proc/loadavg 2>/dev/null || echo unknown)\","
        echo "  \"memory\": {"
        if [ -f /proc/meminfo ]; then
          local total=$(grep MemTotal /proc/meminfo | awk '{print $2}')
          local avail=$(grep MemAvailable /proc/meminfo | awk '{print $2}')
          echo "    \"total_kb\": $total,"
          echo "    \"available_kb\": $avail"
        else
          echo "    \"total_kb\": 0, \"available_kb\": 0"
        fi
        echo "  },"
        echo "  \"disk_usage\": \"$(df -h / 2>/dev/null | tail -1 | awk '{print $5}')\","
        echo "  \"active_agents\": $(cat "$AGENTS_DIR/registry.json" 2>/dev/null | ${pkgs.jq}/bin/jq '.agents | length' 2>/dev/null || echo 0)"
        echo "}"
      } > "$ctx"
    }

    # --- Process inbox messages ---
    process_inbox() {
      for msg_file in "$INBOX"/*.json; do
        [ -f "$msg_file" ] || continue

        local msg_type=$(${pkgs.jq}/bin/jq -r '.type // "unknown"' "$msg_file" 2>/dev/null)
        log "Processing message: $msg_type from $msg_file"

        case "$msg_type" in
          shell-login)
            local pid=$(${pkgs.jq}/bin/jq -r '.pid' "$msg_file" 2>/dev/null)
            local user=$(${pkgs.jq}/bin/jq -r '.user' "$msg_file" 2>/dev/null)
            local ts=$(${pkgs.jq}/bin/jq -r '.timestamp' "$msg_file" 2>/dev/null)
            log "Shell agent login: user=$user pid=$pid"

            # Register the agent
            local registry="$AGENTS_DIR/registry.json"
            local tmp=$(mktemp)
            ${pkgs.jq}/bin/jq --arg pid "$pid" --arg user "$user" --arg ts "$ts" \
              '.agents += [{"type":"shell","pid":($pid|tonumber),"user":$user,"started":$ts,"status":"active"}]' \
              "$registry" > "$tmp" && mv "$tmp" "$registry"

            # Create outbox for this agent
            mkdir -p "$AGENTS_DIR/outbox/shell-$pid"

            # Send welcome context to the shell agent
            gather_context
            local status=$(cat "$STATE_DIR/awareness/system-status.json" 2>/dev/null)
            cat > "$AGENTS_DIR/outbox/shell-$pid/welcome.json" << ENDMSG
{
  "type": "welcome",
  "from": "master",
  "timestamp": "$(date -Iseconds)",
  "system_status": $status,
  "message": "Shell agent registered. System is healthy."
}
ENDMSG
            ;;

          shell-logout)
            local pid=$(${pkgs.jq}/bin/jq -r '.pid' "$msg_file" 2>/dev/null)
            log "Shell agent logout: pid=$pid"

            # Remove from registry
            local registry="$AGENTS_DIR/registry.json"
            local tmp=$(mktemp)
            ${pkgs.jq}/bin/jq --arg pid "$pid" \
              '.agents = [.agents[] | select(.pid != ($pid|tonumber))]' \
              "$registry" > "$tmp" && mv "$tmp" "$registry"

            # Clean up outbox
            rm -rf "$AGENTS_DIR/outbox/shell-$pid"
            ;;

          capability-request)
            local package=$(${pkgs.jq}/bin/jq -r '.package' "$msg_file" 2>/dev/null)
            local from_pid=$(${pkgs.jq}/bin/jq -r '.from_pid' "$msg_file" 2>/dev/null)
            log "Capability request: package=$package from pid=$from_pid"
            # Phase 4 will implement the actual capability manager
            ;;

          *)
            log "Unknown message type: $msg_type"
            ;;
        esac

        # Archive processed message
        mv "$msg_file" "$STATE_DIR/events/$(basename "$msg_file")" 2>/dev/null || rm "$msg_file"
      done
    }

    # --- Monitor system health ---
    check_health() {
      # Check for failed systemd services
      local failed=$(systemctl --failed --no-legend 2>/dev/null | wc -l)
      if [ "$failed" -gt 0 ]; then
        log "WARNING: $failed failed systemd services detected"
      fi

      # Update system context
      gather_context
    }

    # --- Main loop ---
    log "Master agent entering main loop"

    CYCLE=0
    while true; do
      CYCLE=$((CYCLE + 1))

      # Process any pending messages
      process_inbox

      # Health check every 6 cycles (30 seconds)
      if [ $((CYCLE % 6)) -eq 0 ]; then
        check_health
      fi

      # Context refresh every 12 cycles (60 seconds)
      if [ $((CYCLE % 12)) -eq 0 ]; then
        gather_context
        log "Context refreshed (cycle $CYCLE)"
      fi

      sleep 5
    done
  '';

in
{
  environment.systemPackages = [ masterAgent ];

  # Master agent systemd service
  systemd.services.claude-os-master = {
    description = "Claude-OS Master Agent";
    wantedBy = [ "multi-user.target" ];
    after = [
      "network-online.target"
      "claude-os-bootstrap.service"
      "claude-code-install.service"
    ];
    wants = [ "network-online.target" ];
    requires = [ "claude-os-bootstrap.service" ];

    serviceConfig = {
      Type = "simple";
      User = "claude";
      Group = "users";
      Restart = "always";
      RestartSec = 5;
      ExecStart = "${masterAgent}/bin/claude-os-master";
      Environment = [
        "HOME=/home/claude"
        "PATH=/home/claude/.npm-global/bin:${pkgs.nodejs_22}/bin:${pkgs.jq}/bin:${pkgs.coreutils}/bin:${pkgs.procps}/bin:${pkgs.systemd}/bin:${pkgs.bash}/bin:/run/current-system/sw/bin"
      ];

      # Logging
      StandardOutput = "journal";
      StandardError = "journal";

      # Hardening
      ProtectSystem = "strict";
      ReadWritePaths = [
        "/var/lib/claude-os"
        "/var/log"
        "/home/claude"
      ];
      PrivateTmp = true;
    };
  };

  # Write the master agent's CLAUDE.md to state dir on boot
  systemd.services.claude-os-master-config = {
    description = "Generate Master Agent Configuration";
    wantedBy = [ "multi-user.target" ];
    before = [ "claude-os-master.service" ];
    after = [ "claude-os-bootstrap.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      User = "claude";
      Group = "users";
    };
    script = ''
      mkdir -p /var/lib/claude-os/agents
      cat > /var/lib/claude-os/agents/master-claude.md << 'MASTERMD'
${claudeMdMaster}
MASTERMD
    '';
  };
}
