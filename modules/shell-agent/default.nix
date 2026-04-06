{ config, pkgs, lib, ... }:

let
  # Generate the CLAUDE.md system prompt for the shell agent
  claudeMd = import ./claude-md-shell.nix { inherit config pkgs lib; };

  # The shell-agent wrapper script
  shellAgent = pkgs.writeShellScriptBin "claude-shell" ''
    STATE_DIR="/var/lib/claude-os"
    SESSION_DIR="/tmp/claude-os-session-$$"
    CLAUDE_PROJECT_DIR="$HOME/.claude/projects/-var-lib-claude-os"
    NPM_GLOBAL="/home/claude/.npm-global"

    export PATH="$NPM_GLOBAL/bin:/run/current-system/sw/bin:$PATH"
    export NPM_CONFIG_PREFIX="$NPM_GLOBAL"

    # If SSH passes a command (non-interactive), run it directly in bash
    if [ -n "$SSH_ORIGINAL_COMMAND" ]; then
      exec /run/current-system/sw/bin/bash -c "$SSH_ORIGINAL_COMMAND"
    fi
    # If invoked with -c (as login shell with command), run the command
    if [ "$1" = "-c" ] && [ -n "$2" ]; then
      exec /run/current-system/sw/bin/bash -c "$2"
    fi

    # --- Ensure state directory exists ---
    mkdir -p "$STATE_DIR" 2>/dev/null || true
    mkdir -p "$SESSION_DIR"
    mkdir -p "$CLAUDE_PROJECT_DIR/memory"
    mkdir -p "$NPM_GLOBAL"

    # Generate the system prompt (CLAUDE.md) for this session
    cat > "$SESSION_DIR/CLAUDE.md" << 'SYSTEM_PROMPT'
${claudeMd}
SYSTEM_PROMPT

    # Copy CLAUDE.md to the state directory so Claude picks it up
    cp "$SESSION_DIR/CLAUDE.md" "$STATE_DIR/CLAUDE.md" 2>/dev/null || true

    # Sync persistent memory into Claude's project memory dir
    if [ -d "$STATE_DIR/memory/facts" ]; then
      cp -r "$STATE_DIR/memory/facts/"* "$CLAUDE_PROJECT_DIR/memory/" 2>/dev/null || true
    fi

    # Load persisted environment variables
    if [ -f "$STATE_DIR/state/env.sh" ]; then
      . "$STATE_DIR/state/env.sh"
    fi

    # Notify master agent of login (if message bus exists)
    if [ -d "$STATE_DIR/agents/inbox" ]; then
      echo "{\"type\": \"shell-login\", \"pid\": $$, \"user\": \"$(whoami)\", \"timestamp\": \"$(date -Iseconds)\"}" \
        > "$STATE_DIR/agents/inbox/shell-login-$$.json" 2>/dev/null || true
    fi

    # Start heartbeat background process
    mkdir -p "$STATE_DIR/agents/heartbeats"
    (while true; do
      claude-os-agents heartbeat $$ 2>/dev/null || true
      sleep 10
    done) &
    HEARTBEAT_PID=$!

    # Set up logout notification trap
    cleanup() {
      kill $HEARTBEAT_PID 2>/dev/null || true
      rm -f "$STATE_DIR/agents/heartbeats/$$.json" 2>/dev/null || true
      if [ -d "$STATE_DIR/agents/inbox" ]; then
        echo "{\"type\": \"shell-logout\", \"pid\": $$, \"timestamp\": \"$(date -Iseconds)\"}" \
          > "$STATE_DIR/agents/inbox/shell-logout-$$.json" 2>/dev/null || true
      fi
      rm -rf "$SESSION_DIR" 2>/dev/null || true
    }
    trap cleanup EXIT

    # --- Launch Claude ---
    export CLAUDE_OS_STATE="$STATE_DIR"
    export CLAUDE_OS_SESSION="$SESSION_DIR"

    # Change to state directory (or home if not available yet)
    cd "$STATE_DIR" 2>/dev/null || cd "$HOME"

    # Build MCP config argument if available
    MCP_ARG=""
    if [ -f "$STATE_DIR/mcp-config.json" ]; then
      MCP_ARG="--mcp-config $STATE_DIR/mcp-config.json"
    fi

    # Wait for the install service if claude is not yet available
    if ! command -v claude >/dev/null 2>&1; then
      echo "============================================"
      echo "  Welcome to Claude-OS"
      echo "============================================"
      echo ""
      echo "Waiting for Claude Code CLI to install..."
      # Wait up to 120 seconds for the systemd service to finish
      for i in $(seq 1 24); do
        if command -v claude >/dev/null 2>&1; then
          break
        fi
        sleep 5
        echo "  Still installing... (''${i}0s)"
      done
    fi

    if command -v claude >/dev/null 2>&1; then
      echo "Claude Code is ready. Launching..."
      echo ""
      exec claude --dangerously-skip-permissions $MCP_ARG "$@"
    else
      echo ""
      echo "Claude Code is not yet available."
      echo "Install manually: npm install -g @anthropic-ai/claude-code"
      echo "Then run: claude --dangerously-skip-permissions"
      echo ""
      echo "Dropping to bash shell..."
      exec ${pkgs.bash}/bin/bash --login
    fi
  '';
in
{
  # Install the shell-agent script
  environment.systemPackages = [ shellAgent ];

  # Register as a valid login shell
  environment.shells = [ "${shellAgent}/bin/claude-shell" ];

  # Set as the claude user's login shell
  users.users.claude.shell = "${shellAgent}/bin/claude-shell";

  # First-boot service: install Claude Code CLI
  systemd.services.claude-code-install = {
    description = "Install Claude Code CLI";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      User = "claude";
      Group = "users";
    };
    path = [ pkgs.nodejs_22 pkgs.git ];
    environment = {
      HOME = "/home/claude";
      NPM_CONFIG_PREFIX = "/home/claude/.npm-global";
    };
    script = ''
      mkdir -p /home/claude/.npm-global
      npm install -g @anthropic-ai/claude-code
    '';
  };

  # Ensure npm global bin is in PATH for all users
  environment.sessionVariables = {
    NPM_CONFIG_PREFIX = "/home/claude/.npm-global";
  };
  environment.extraInit = ''
    export PATH="/home/claude/.npm-global/bin:$PATH"
  '';
}
