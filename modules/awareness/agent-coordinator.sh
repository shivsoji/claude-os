#!/usr/bin/env bash
# claude-os-agents — Multi-agent coordinator
# Tracks all shell agents, detects conflicts, manages resources.
#
# Usage:
#   claude-os-agents list              — List all active agents
#   claude-os-agents status            — Detailed agent status
#   claude-os-agents send <id> <msg>   — Send message to agent
#   claude-os-agents broadcast <msg>   — Send to all agents
#   claude-os-agents lock <resource>   — Acquire a resource lock
#   claude-os-agents unlock <resource> — Release a resource lock
#   claude-os-agents locks             — Show active locks
#   claude-os-agents conflicts         — Detect active conflicts

set -uo pipefail

STATE_DIR="${CLAUDE_OS_STATE:-/var/lib/claude-os}"
AGENTS_DIR="$STATE_DIR/agents"
LOCKS_DIR="$AGENTS_DIR/locks"
REGISTRY="$AGENTS_DIR/registry.json"

export PATH="/run/current-system/sw/bin:$PATH"

mkdir -p "$LOCKS_DIR"

case "${1:-help}" in
  list)
    [ -f "$REGISTRY" ] || { echo "No agents registered."; exit 0; }

    echo "=== Active Agents ==="
alive=0 dead=0
    jq -r '.agents[] | "\(.type)\t\(.pid)\t\(.user)\t\(.started)\t\(.status)"' "$REGISTRY" 2>/dev/null | \
      while IFS=$'\t' read -r type pid user started status; do
        if kill -0 "$pid" 2>/dev/null; then
      cpu=$(ps -o %cpu= -p "$pid" 2>/dev/null | tr -d ' ')
      mem=$(ps -o rss= -p "$pid" 2>/dev/null | tr -d ' ')
      mem_mb=$(( ${mem:-0} / 1024 ))
          echo "  [$type] PID=$pid user=$user CPU=${cpu:-?}% MEM=${mem_mb}MB since $started"
          alive=$((alive + 1))
        else
          echo "  [$type] PID=$pid DEAD (registered $started)"
          dead=$((dead + 1))
        fi
      done

    echo ""
    echo "Total: $alive alive, $dead dead"
    ;;

  status)
    [ -f "$REGISTRY" ] || { echo "{}"; exit 0; }

    # Build detailed status
    echo "{"
    echo "  \"agents\": ["

first=true
    jq -c '.agents[]' "$REGISTRY" 2>/dev/null | while read -r agent; do
  pid=$(echo "$agent" | jq -r '.pid')
  alive="false"
  cpu="0" mem="0" threads="0"

      if kill -0 "$pid" 2>/dev/null; then
        alive="true"
        cpu=$(ps -o %cpu= -p "$pid" 2>/dev/null | tr -d ' ' || echo "0")
        mem=$(ps -o rss= -p "$pid" 2>/dev/null | tr -d ' ' || echo "0")
        threads=$(ls /proc/$pid/task/ 2>/dev/null | wc -l || echo "0")
      fi

      [ "$first" = "true" ] && first=false || echo ","
      echo "    $(echo "$agent" | jq -c ". + {alive:$alive, cpu:$cpu, mem_kb:$mem, threads:$threads}")"
    done

    echo "  ],"
    echo "  \"locks\": $(ls "$LOCKS_DIR" 2>/dev/null | jq -R -s 'split("\n") | map(select(. != ""))' 2>/dev/null || echo '[]'),"
    echo "  \"total_alive\": $(jq '[.agents[].pid] | map(select(. as $p | "'$(ps -eo pid= | tr -d ' ' | jq -R -s 'split("\n")' 2>/dev/null)'" | contains([$p|tostring]))) | length' "$REGISTRY" 2>/dev/null || echo 0)"
    echo "}"
    ;;

  send)
    agent_id="${2:?Usage: claude-os-agents send <agent-id> <message>}"
    shift 2
    message="${*:?Missing message}"

outbox="$AGENTS_DIR/outbox/$agent_id"
    mkdir -p "$outbox"
    echo "{\"from\":\"coordinator\",\"ts\":\"$(date -Iseconds)\",\"message\":\"$message\"}" \
      > "$outbox/coord-$(date +%s%N).json"
    echo "Message sent to $agent_id"
    ;;

  broadcast)
    shift
    message="${*:?Usage: claude-os-agents broadcast <message>}"

    jq -r '.agents[] | "\(.type)-\(.pid)"' "$REGISTRY" 2>/dev/null | while read -r aid; do
  outbox="$AGENTS_DIR/outbox/$aid"
      mkdir -p "$outbox"
      echo "{\"from\":\"coordinator\",\"ts\":\"$(date -Iseconds)\",\"type\":\"broadcast\",\"message\":\"$message\"}" \
        > "$outbox/broadcast-$(date +%s%N).json"
    done
    echo "Broadcast sent to all agents"
    ;;

  lock)
    resource="${2:?Usage: claude-os-agents lock <resource>}"
    lockfile="$LOCKS_DIR/$resource"

    if [ -f "$lockfile" ]; then
  holder=$(cat "$lockfile")
  holder_pid=$(echo "$holder" | jq -r '.pid' 2>/dev/null)
      if kill -0 "$holder_pid" 2>/dev/null; then
        echo "LOCKED: Resource '$resource' held by PID $holder_pid"
        exit 1
      else
        # Stale lock — remove
        rm -f "$lockfile"
      fi
    fi

    echo "{\"resource\":\"$resource\",\"pid\":$$,\"acquired\":\"$(date -Iseconds)\"}" > "$lockfile"
    echo "Lock acquired: $resource (PID $$)"
    ;;

  unlock)
    resource="${2:?Usage: claude-os-agents unlock <resource>}"
    rm -f "$LOCKS_DIR/$resource"
    echo "Lock released: $resource"
    ;;

  locks)
    echo "=== Active Locks ==="
    for lockfile in "$LOCKS_DIR"/*; do
      [ -f "$lockfile" ] || { echo "No active locks."; break; }
  resource=$(basename "$lockfile")
  holder=$(cat "$lockfile")
  pid=$(echo "$holder" | jq -r '.pid' 2>/dev/null)
  acquired=$(echo "$holder" | jq -r '.acquired' 2>/dev/null)
      if kill -0 "$pid" 2>/dev/null; then
        echo "  $resource: held by PID $pid since $acquired"
      else
        echo "  $resource: STALE (PID $pid dead, acquired $acquired)"
        rm -f "$lockfile"
      fi
    done
    ;;

  conflicts)
    echo "=== Conflict Detection ==="

    # Check for concurrent nix operations
nix_procs=$(pgrep -a "nix-build\|nixos-rebuild" 2>/dev/null)
    if [ $(echo "$nix_procs" | grep -c '.' || echo 0) -gt 1 ]; then
      echo "WARNING: Multiple nix build operations running:"
      echo "$nix_procs" | sed 's/^/  /'
    fi

    # Check for stale locks
    for lockfile in "$LOCKS_DIR"/*; do
      [ -f "$lockfile" ] || continue
  pid=$(jq -r '.pid' "$lockfile" 2>/dev/null)
      if ! kill -0 "$pid" 2>/dev/null; then
        echo "STALE LOCK: $(basename "$lockfile") held by dead PID $pid"
      fi
    done

    # Check for agents modifying the same files
    # (simplified: look for agents writing to genome)
genome_writers=$(lsof "$STATE_DIR/genome/manifest.json" 2>/dev/null | tail -n+2 | wc -l)
    if [ "$genome_writers" -gt 1 ]; then
      echo "WARNING: $genome_writers processes have genome open for writing"
    fi

    echo "Scan complete."
    ;;

  help|*)
    echo "claude-os-agents — Multi-agent coordinator"
    echo ""
    echo "  list              List active agents"
    echo "  status            Detailed agent JSON status"
    echo "  send <id> <msg>   Message an agent"
    echo "  broadcast <msg>   Message all agents"
    echo "  lock <resource>   Acquire resource lock"
    echo "  unlock <resource> Release resource lock"
    echo "  locks             Show active locks"
    echo "  conflicts         Detect conflicts"
    ;;
esac
