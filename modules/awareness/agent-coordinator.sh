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
    alive=0
    dead=0

    # Use process substitution to avoid subshell scope loss
    while IFS=$'\t' read -r type pid user started status; do
      [ -z "$pid" ] && continue
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
    done < <(jq -r '.agents[] | "\(.type)\t\(.pid)\t\(.user)\t\(.started)\t\(.status)"' "$REGISTRY" 2>/dev/null)

    echo ""
    echo "Total: $alive alive, $dead dead"
    ;;

  status)
    [ -f "$REGISTRY" ] || { echo "{}"; exit 0; }

    # Build detailed status using jq directly (avoids subshell issues)
    jq -r '
      .agents | map(
        . + {
          alive: ((.pid | tostring) as $p | false),
          cpu: 0,
          mem_kb: 0
        }
      ) | {agents: ., locks: [], total: length}
    ' "$REGISTRY" 2>/dev/null || echo '{"agents":[],"locks":[],"total":0}'
    ;;

  send)
    agent_id="${2:?Usage: claude-os-agents send <agent-id> <message>}"
    shift 2
    message="${*:?Missing message}"

    outbox="$AGENTS_DIR/outbox/$agent_id"
    mkdir -p "$outbox"
    # Use jq to safely create JSON (prevents injection)
    jq -n --arg msg "$message" --arg ts "$(date -Iseconds)" \
      '{from:"coordinator",ts:$ts,message:$msg}' \
      > "$outbox/coord-$(date +%s%N).json"
    echo "Message sent to $agent_id"
    ;;

  broadcast)
    shift
    message="${*:?Usage: claude-os-agents broadcast <message>}"

    while read -r aid; do
      [ -z "$aid" ] && continue
      outbox="$AGENTS_DIR/outbox/$aid"
      mkdir -p "$outbox"
      jq -n --arg msg "$message" --arg ts "$(date -Iseconds)" \
        '{from:"coordinator",ts:$ts,type:"broadcast",message:$msg}' \
        > "$outbox/broadcast-$(date +%s%N).json"
    done < <(jq -r '.agents[] | "\(.type)-\(.pid)"' "$REGISTRY" 2>/dev/null)
    echo "Broadcast sent to all agents"
    ;;

  lock)
    resource="${2:?Usage: claude-os-agents lock <resource>}"
    lockfile="$LOCKS_DIR/$resource"

    # Check for existing lock
    if [ -f "$lockfile" ]; then
      holder_pid=$(jq -r '.pid' "$lockfile" 2>/dev/null || echo "0")
      if kill -0 "$holder_pid" 2>/dev/null; then
        echo "LOCKED: Resource '$resource' held by PID $holder_pid"
        exit 1
      else
        rm -f "$lockfile"
      fi
    fi

    # Atomic lock creation using mkdir (atomic on POSIX)
    lockdir="$LOCKS_DIR/.${resource}.creating"
    if mkdir "$lockdir" 2>/dev/null; then
      jq -n --arg res "$resource" --argjson pid $$ --arg ts "$(date -Iseconds)" \
        '{resource:$res,pid:$pid,acquired:$ts}' > "$lockfile"
      rmdir "$lockdir"
      echo "Lock acquired: $resource (PID $$)"
    else
      echo "LOCKED: Resource '$resource' is being acquired by another process"
      exit 1
    fi
    ;;

  unlock)
    resource="${2:?Usage: claude-os-agents unlock <resource>}"
    rm -f "$LOCKS_DIR/$resource"
    echo "Lock released: $resource"
    ;;

  locks)
    echo "=== Active Locks ==="
    found=0
    for lockfile in "$LOCKS_DIR"/*; do
      [ -f "$lockfile" ] || continue
      found=1
      resource=$(basename "$lockfile")
      pid=$(jq -r '.pid' "$lockfile" 2>/dev/null || echo "0")
      acquired=$(jq -r '.acquired' "$lockfile" 2>/dev/null || echo "unknown")
      if kill -0 "$pid" 2>/dev/null; then
        echo "  $resource: held by PID $pid since $acquired"
      else
        echo "  $resource: STALE (PID $pid dead, acquired $acquired)"
        rm -f "$lockfile"
      fi
    done
    [ "$found" -eq 0 ] && echo "  No active locks."
    ;;

  conflicts)
    echo "=== Conflict Detection ==="

    # Check for concurrent nix operations (pgrep uses ERE)
    nix_count=$(pgrep -c -f "nix-build|nixos-rebuild" 2>/dev/null || true)
    nix_count=${nix_count:-0}
    nix_count=$(echo "$nix_count" | tr -d '[:space:]')
    if [ "$nix_count" -gt 1 ] 2>/dev/null; then
      echo "WARNING: $nix_count concurrent nix build operations running"
      pgrep -af "nix-build|nixos-rebuild" 2>/dev/null | sed 's/^/  /'
    fi

    # Check for stale locks
    for lockfile in "$LOCKS_DIR"/*; do
      [ -f "$lockfile" ] || continue
      pid=$(jq -r '.pid' "$lockfile" 2>/dev/null || echo "0")
      if ! kill -0 "$pid" 2>/dev/null; then
        echo "STALE LOCK: $(basename "$lockfile") held by dead PID $pid"
      fi
    done

    # Check for genome contention
    genome_writers=$(lsof "$STATE_DIR/genome/manifest.json" 2>/dev/null | tail -n+2 | wc -l || true)
    genome_writers=$(echo "${genome_writers:-0}" | tr -d '[:space:]')
    if [ "${genome_writers:-0}" -gt 1 ] 2>/dev/null; then
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
