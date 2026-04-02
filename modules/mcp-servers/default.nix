{ config, pkgs, lib, ... }:

let
  # Build the agent-bus MCP server as a nix derivation
  agentBusMcp = pkgs.buildNpmPackage {
    pname = "claude-os-agent-bus";
    version = "0.1.0";
    src = ../../mcp-servers/agent-bus;
    npmDepsHash = lib.fakeHash; # Will be replaced after first build
    dontNpmBuild = true; # We run TypeScript directly via tsx/node
    installPhase = ''
      mkdir -p $out/lib/agent-bus
      cp -r node_modules $out/lib/agent-bus/
      cp -r src $out/lib/agent-bus/
      cp package.json $out/lib/agent-bus/

      mkdir -p $out/bin
      cat > $out/bin/agent-bus-mcp << 'EOF'
      #!/bin/sh
      exec node --experimental-strip-types $out/lib/agent-bus/src/index.ts "$@"
      EOF
      chmod +x $out/bin/agent-bus-mcp
    '';
  };

  # For now, use a simpler approach: run the MCP server via npx/node directly
  # from the source directory, installed via npm on the system
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
      # Future MCP servers will be added here:
      # os-control = { ... };
      # memory-graph = { ... };
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
    path = [ pkgs.nodejs_22 pkgs.git ];
    environment = {
      HOME = "/home/claude";
      NPM_CONFIG_PREFIX = "/home/claude/.npm-global";
    };
    script = ''
      # Copy MCP server source to state dir
      MCP_DIR="/var/lib/claude-os/mcp-servers/agent-bus"
      mkdir -p "$MCP_DIR/src"

      # Copy source files
      cp ${../../mcp-servers/agent-bus/package.json} "$MCP_DIR/package.json"
      cp ${../../mcp-servers/agent-bus/src/index.ts} "$MCP_DIR/src/index.ts"

      # Install dependencies
      cd "$MCP_DIR"
      npm install --production 2>&1 || true

      # Write MCP config for Claude
      cp ${mcpConfigJson} /var/lib/claude-os/mcp-config.json

      echo "MCP servers configured"
    '';
  };
}
