# Claude-OS Docker Container
# Runs the full Claude-OS stack without NixOS or QEMU.
# Uses the nix package manager inside a lightweight base image.
#
# Build:  docker build -t claude-os .
# Run:    docker run -it -p 2222:22 -p 8420:8420 -p 11434:11434 \
#           -v claude-os-state:/var/lib/claude-os \
#           --name claude-os claude-os
#
# SSH:    ssh -p 2222 claude@localhost  (password: claude-os)
# API:    curl http://localhost:8420/v1/health
# Ollama: curl http://localhost:11434/api/version

FROM nixos/nix:latest AS builder

# Enable flakes
RUN echo "experimental-features = nix-command flakes" >> /etc/nix/nix.conf

# Copy source
WORKDIR /build
COPY flake.nix flake.lock ./
COPY modules/ modules/
COPY mcp-servers/ mcp-servers/
COPY platform/ platform/
COPY skills/ skills/

# Build the system closure for the container target
# We only need the packages, not the full NixOS system
RUN nix build --extra-experimental-features "nix-command flakes" \
    nixpkgs#bashInteractive \
    nixpkgs#coreutils \
    nixpkgs#systemd \
    nixpkgs#openssh \
    nixpkgs#git \
    nixpkgs#jq \
    nixpkgs#sqlite \
    nixpkgs#curl \
    nixpkgs#nodejs_22 \
    nixpkgs#htop \
    nixpkgs#tmux \
    nixpkgs#ripgrep \
    nixpkgs#fd \
    nixpkgs#inotify-tools \
    nixpkgs#socat \
    nixpkgs#procps \
    nixpkgs#ollama \
    nixpkgs#python3 \
    nixpkgs#vim \
    -o /build/result

# ============================================
# Runtime image — minimal, no nix needed
# ============================================
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
ENV CLAUDE_OS_STATE=/var/lib/claude-os

# Base system
RUN apt-get update && apt-get install -y --no-install-recommends \
    bash curl wget git jq sqlite3 htop tmux vim \
    openssh-server \
    inotify-tools socat procps \
    python3 \
    ca-certificates locales sudo gnupg \
    && rm -rf /var/lib/apt/lists/* \
    && locale-gen en_US.UTF-8

# Install Node.js 22 (needed for --experimental-strip-types)
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y nodejs \
    && rm -rf /var/lib/apt/lists/*

ENV LANG=en_US.UTF-8

# Create claude user
RUN useradd -m -s /bin/bash -G sudo claude \
    && echo "claude:claude-os" | chpasswd \
    && echo "claude ALL=(ALL) NOPASSWD: /usr/bin/apt-get,/usr/bin/systemctl,/usr/bin/npm" >> /etc/sudoers.d/claude

# SSH setup
RUN mkdir -p /run/sshd && ssh-keygen -A
RUN sed -i 's/#PasswordAuthentication yes/PasswordAuthentication yes/' /etc/ssh/sshd_config

# Create state directory structure
RUN mkdir -p \
    /var/lib/claude-os/{memory/facts,memory/sessions,skills/builtins,genome,evolution/history,agents/inbox,agents/outbox,agents/heartbeats,agents/locks,agents/master,awareness/signals,awareness/history,events,goals/plans,goals/active,state,sessions,backups,review-queue,compositions,platform/src/db,platform/src/engine,mcp-servers/agent-bus/src,mcp-servers/memory-graph/src,skills/usage-log} \
    && chown -R claude:claude /var/lib/claude-os

# Copy Claude-OS components
WORKDIR /opt/claude-os

# Shell scripts → /usr/local/bin
COPY modules/master-agent/evolve.sh /usr/local/bin/claude-os-evolve
COPY modules/master-agent/capability-manager.sh /usr/local/bin/claude-os-cap
COPY modules/master-agent/goal-planner.sh /usr/local/bin/claude-os-plan
COPY modules/master-agent/route.sh /usr/local/bin/claude-os-route
COPY modules/master-agent/exec.sh /usr/local/bin/claude-os-exec
COPY modules/master-agent/compositions.sh /usr/local/bin/claude-os-compose
COPY modules/master-agent/skill-hooks.sh /usr/local/bin/claude-os-skill
COPY modules/memory/memory-graph.sh /usr/local/bin/claude-os-memory
COPY modules/awareness/awareness-engine.sh /usr/local/bin/claude-os-awareness
COPY modules/awareness/health-guardian.sh /usr/local/bin/claude-os-health
COPY modules/awareness/agent-coordinator.sh /usr/local/bin/claude-os-agents
COPY modules/awareness/sense.sh /usr/local/bin/claude-os-sense
RUN chmod +x /usr/local/bin/claude-os-*

# Memory graph schema
COPY modules/memory/schema.sql /opt/claude-os/schema.sql

# Skill files
COPY modules/skills/builtins/ /var/lib/claude-os/skills/builtins/
COPY skills/ /opt/claude-os/skills/

# Stage platform + MCP source in /opt (copied to volume at runtime)
COPY platform/package.json /opt/claude-os/platform-src/package.json
COPY platform/src/ /opt/claude-os/platform-src/src/
COPY mcp-servers/agent-bus/package.json /opt/claude-os/mcp-src/agent-bus/package.json
COPY mcp-servers/agent-bus/src/ /opt/claude-os/mcp-src/agent-bus/src/
COPY mcp-servers/memory-graph/package.json /opt/claude-os/mcp-src/memory-graph/package.json
COPY mcp-servers/memory-graph/src/ /opt/claude-os/mcp-src/memory-graph/src/
COPY platform/portal/ /opt/claude-os/portal/

# Shell agent CLAUDE.md (generate a static version)
COPY modules/shell-agent/claude-md-shell.nix /opt/claude-os/claude-md-shell.nix
COPY modules/master-agent/claude-md-master.nix /opt/claude-os/claude-md-master.nix

# npm deps installed at runtime (into the volume)

# Install Claude Code CLI
RUN npm install -g @anthropic-ai/claude-code 2>/dev/null || true

# Fix ownership
RUN chown -R claude:claude /var/lib/claude-os

# Bootstrap script — runs on container start
COPY <<'ENTRYPOINT_SCRIPT' /opt/claude-os/entrypoint.sh
#!/bin/bash
set -e

STATE_DIR=/var/lib/claude-os
export CLAUDE_OS_STATE=$STATE_DIR
export PATH="/usr/local/bin:$PATH"

echo "============================================"
echo "  Claude-OS Container Starting"
echo "============================================"

# Ensure directory structure exists (volume may be empty on first run)
mkdir -p $STATE_DIR/{memory/facts,memory/sessions,skills/builtins,skills/usage-log,genome,evolution/history,agents/inbox,agents/outbox,agents/heartbeats,agents/locks,agents/master,awareness/signals,awareness/history,events,goals/plans,goals/active,state,sessions,backups,review-queue,compositions,platform/src/db,platform/src/engine,mcp-servers/agent-bus/src,mcp-servers/memory-graph/src}
chown -R claude:claude $STATE_DIR

# Copy platform + MCP source into volume (if not already there)
if [ ! -f "$STATE_DIR/platform/package.json" ]; then
    echo "[init] Copying platform source to state volume..."
    cp -r /opt/claude-os/platform-src/* $STATE_DIR/platform/ 2>/dev/null || true
    cp -r /opt/claude-os/mcp-src/agent-bus/* $STATE_DIR/mcp-servers/agent-bus/ 2>/dev/null || true
    cp -r /opt/claude-os/mcp-src/memory-graph/* $STATE_DIR/mcp-servers/memory-graph/ 2>/dev/null || true
    mkdir -p $STATE_DIR/platform/portal
    cp -r /opt/claude-os/portal/* $STATE_DIR/platform/portal/ 2>/dev/null || true
    cd $STATE_DIR/platform && npm install --omit=dev 2>/dev/null || true
    chown -R claude:claude $STATE_DIR
fi

# Initialize memory graph
if [ ! -f "$STATE_DIR/memory/graph.sqlite" ]; then
    echo "[init] Creating memory graph..."
    sqlite3 "$STATE_DIR/memory/graph.sqlite" < /opt/claude-os/schema.sql
    # Seed
    sqlite3 "$STATE_DIR/memory/graph.sqlite" "INSERT INTO entities (type, name, content, tags) VALUES
        ('system', 'identity', 'I am Claude-OS, a self-evolving AI operating system.', 'core,identity'),
        ('system', 'architecture', 'Docker container with systemd, master/shell agents, memory graph.', 'core,architecture'),
        ('system', 'capabilities', 'Shell, networking, file management, version control, text editing.', 'core,capabilities');"
    sqlite3 "$STATE_DIR/memory/graph.sqlite" "INSERT INTO relations (src_id, dst_id, rel_type, weight) VALUES
        (1, 2, 'has', 1.0), (1, 3, 'has', 1.0), (2, 3, 'enables', 0.8);"
fi

# Initialize genome
if [ ! -f "$STATE_DIR/genome/manifest.json" ]; then
    echo "[init] Creating genome..."
    jq -n --arg born "$(date -Iseconds)" \
        '{version:1,generation:0,born:$born,packages:{base:["coreutils","curl","git","jq","sqlite3","htop","tmux","nodejs","python3","vim"],user:[]},services:{base:["sshd","claude-os-master","claude-os-awareness"],user:[]},skills:[],capabilities:["shell","networking","ssh","file-management","version-control","text-editing","json-processing","managed-agents","platform-api"],fitness:{tasks_completed:0,packages_installed:0,skills_learned:0,errors_recovered:0,uptime_hours:0}}' \
        > "$STATE_DIR/genome/manifest.json"
fi

# Initialize evolution log
if [ ! -f "$STATE_DIR/evolution/log.json" ]; then
    echo '{"mutations":[],"generation":0,"born":"'"$(date -Iseconds)"'","version":1}' > "$STATE_DIR/evolution/log.json"
fi

# Start SSH
echo "[init] Starting SSH..."
/usr/sbin/sshd

# Start awareness engine
echo "[init] Starting awareness engine..."
su claude -c "claude-os-awareness &" 2>/dev/null

# Start master agent
echo "[init] Starting master agent..."
su claude -c "claude-os-master &" 2>/dev/null

# Start platform API
echo "[init] Starting platform API on :8420..."
cd $STATE_DIR/platform
su claude -c "node --experimental-strip-types src/server.ts &" 2>/dev/null

# Wait for platform to be ready
for i in $(seq 1 10); do
    if curl -sf http://localhost:8420/v1/health >/dev/null 2>&1; then
        TOKEN=$(cat "$STATE_DIR/platform/api-token" 2>/dev/null)
        echo ""
        echo "============================================"
        echo "  Claude-OS is ready!"
        echo "============================================"
        echo ""
        echo "  SSH:      ssh -p 2222 claude@localhost"
        echo "  Password: claude-os"
        echo ""
        echo "  Platform: http://localhost:8420"
        echo "  API Token: ${TOKEN:0:20}..."
        echo ""
        echo "  Ollama:   Not started (run: ollama serve &)"
        echo "============================================"
        break
    fi
    sleep 2
done

# Drop into shell or keep running
if [ -t 0 ]; then
    exec su - claude
else
    # Detached mode — keep container alive
    tail -f /dev/null
fi
ENTRYPOINT_SCRIPT

RUN chmod +x /opt/claude-os/entrypoint.sh

# Expose ports
EXPOSE 22 8420 11434

# Persistent state volume
VOLUME /var/lib/claude-os

ENTRYPOINT ["/opt/claude-os/entrypoint.sh"]
