{ config, pkgs, lib, ... }:

let
  mcpConfigJson = pkgs.writeText "claude-os-mcp-config.json" (builtins.toJSON {
    mcpServers = {
      agent-bus = {
        command = "node";
        args = [
          "--experimental-strip-types"
          "/var/lib/claude-os/mcp-servers/agent-bus/src/index.ts"
        ];
        env = {
          CLAUDE_OS_STATE = "/var/lib/claude-os";
        };
      };
      memory-graph = {
        command = "node";
        args = [
          "--experimental-strip-types"
          "/var/lib/claude-os/mcp-servers/memory-graph/src/index.ts"
        ];
        env = {
          CLAUDE_OS_STATE = "/var/lib/claude-os";
        };
      };
    };
  });
in
{
  # Install MCP server source to the state directory on boot
  systemd.services.claude-os-mcp-setup = {
    description = "Set up Claude-OS MCP Servers";
    wantedBy = [ "multi-user.target" ];
    after = [ "claude-os-bootstrap.service" "claude-code-install.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      User = "claude";
      Group = "users";
    };
    path = [ pkgs.nodejs_22 pkgs.git pkgs.python3 ];
    environment = {
      HOME = "/home/claude";
      NPM_CONFIG_PREFIX = "/home/claude/.npm-global";
    };
    script = ''
      MCP_BASE="/var/lib/claude-os/mcp-servers"

      # --- Agent Bus MCP ---
      AGENT_DIR="$MCP_BASE/agent-bus"
      mkdir -p "$AGENT_DIR/src"
      cp ${../../mcp-servers/agent-bus/package.json} "$AGENT_DIR/package.json"
      cp ${../../mcp-servers/agent-bus/src/index.ts} "$AGENT_DIR/src/index.ts"
      cd "$AGENT_DIR" && npm install --production 2>&1 || true

      # --- Memory Graph MCP ---
      MEM_DIR="$MCP_BASE/memory-graph"
      mkdir -p "$MEM_DIR/src"
      cp ${../../mcp-servers/memory-graph/package.json} "$MEM_DIR/package.json"
      cp ${../../mcp-servers/memory-graph/src/index.ts} "$MEM_DIR/src/index.ts"
      cd "$MEM_DIR" && npm install --production 2>&1 || true

      # --- Write MCP config ---
      cp ${mcpConfigJson} /var/lib/claude-os/mcp-config.json

      echo "MCP servers configured (agent-bus, memory-graph)"
    '';
  };
}
