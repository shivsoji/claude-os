#!/usr/bin/env bash
# claude-os-agents — Multi-agent coordinator
# Proper concurrency: flock locking, heartbeats, conflict detection.
#
# Usage:
#   claude-os-agents list              — List all active agents
#   claude-os-agents status            — Detailed agent status
#   claude-os-agents send <id> <msg>   — Send message to agent
#   claude-os-agents broadcast <msg>   — Send to all agents
#   claude-os-agents lock <resource> [timeout]  — Acquire flock (default 30s timeout)
#   claude-os-agents unlock <resource> — Release flock
#   claude-os-agents locks             — Show active locks
#   claude-os-agents conflicts         — Detect active conflicts
#   claude-os-agents heartbeat         — Write heartbeat for current process
#   claude-os-agents prune             — Remove dead agents and stale locks

set -uo pipefail

STATE_DIR="${CLAUDE_OS_STATE:-/var/lib/claude-os}"
AGENTS_DIR="$STATE_DIR/agents"
LOCKS_DIR="$AGENTS_DIR/locks"
HEARTBEAT_DIR="$AGENTS_DIR/heartbeats"
REGISTRY="$AGENTS_DIR/registry.json"

export PATH="/run/current-system/sw/bin:$PATH"

mkdir -p "$LOCKS_DIR" "$HEARTBEAT_DIR"

case "${1:-help}" in
  list)
    [ -f "$REGISTRY" ] || { echo "No agents registered."; exit 0; }

    echo "=== Active Agents ==="
    alive=0
    dead=0

    while IFS=$'\t' read -r type pid user started status; do
      [ -z "$pid" ] && continue
      # Check heartbeat (more reliable than kill -0)
      hb_file="$HEARTBEAT_DIR/$pid.json"
      if [ -f "$hb_file" ]; then
        hb_age=$(( $(date +%s) - $(date -d "$(jq -r '.ts' "$hb_file" 2>/dev/null)" +%s 2>/dev/null || echo 0) ))
        if [ "$hb_age" -lt 30 ]; then
          cpu=$(jq -r '.cpu // "?"' "$hb_file" 2>/dev/null)
          mem=$(jq -r '.mem_mb // "?"' "$hb_file" 2>/dev/null)
          echo "  [$type] PID=$pid user=$user CPU=${cpu}% MEM=${mem}MB since $started (heartbeat: ${hb_age}s ago)"
          alive=$((alive + 1))
          continue
        fi
      fi
      # Fall back to kill -0
      if kill -0 "$pid" 2>/dev/null; then
        cpu=$(ps -o %cpu= -p "$pid" 2>/dev/null | tr -d ' ')
        mem_kb=$(ps -o rss= -p "$pid" 2>/dev/null | tr -d ' ')
        mem_mb=$(( ${mem_kb:-0} / 1024 ))
        echo "  [$type] PID=$pid user=$user CPU=${cpu:-?}% MEM=${mem_mb}MB since $started (no heartbeat)"
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
    jq -r '.agents' "$REGISTRY" 2>/dev/null || echo '[]'
    ;;

  send)
    agent_id="${2:?Usage: claude-os-agents send <agent-id> <message>}"
    shift 2
    message="${*:?Missing message}"

    outbox="$AGENTS_DIR/outbox/$agent_id"
    mkdir -p "$outbox"
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
    resource="${2:?Usage: claude-os-agents lock <resource> [timeout_secs]}"
    timeout="${3:-30}"
    lockfile="$LOCKS_DIR/${resource}.lock"

    # flock-based locking: atomic, released on process death
    exec 200>"$lockfile"
    if flock -w "$timeout" 200; then
      # Write holder info (for inspection only, flock is the real lock)
      jq -n --arg res "$resource" --argjson pid $$ --arg ts "$(date -Iseconds)" \
        '{resource:$res,pid:$pid,acquired:$ts}' > "$lockfile.info"
      echo "Lock acquired: $resource (PID $$, timeout ${timeout}s)"
      echo "IMPORTANT: Lock is held by this process. It releases when this shell exits."
      echo "To explicitly release: claude-os-agents unlock $resource"
    else
      echo "TIMEOUT: Could not acquire lock '$resource' within ${timeout}s"
      holder=$(cat "$lockfile.info" 2>/dev/null | jq -r '.pid // "unknown"')
      echo "Current holder: PID $holder"
      exit 1
    fi
    ;;

  unlock)
    resource="${2:?Usage: claude-os-agents unlock <resource>}"
    lockfile="$LOCKS_DIR/${resource}.lock"
    # Release flock
    if [ -f "$lockfile" ]; then
      flock -u 200 2>/dev/null || true
      rm -f "$lockfile" "$lockfile.info"
      echo "Lock released: $resource"
    else
      echo "No lock found: $resource"
    fi
    ;;

  locks)
    echo "=== Active Locks ==="
    found=0
    for infofile in "$LOCKS_DIR"/*.lock.info; do
      [ -f "$infofile" ] || continue
      found=1
      resource=$(basename "$infofile" .lock.info)
      pid=$(jq -r '.pid' "$infofile" 2>/dev/null || echo "0")
      acquired=$(jq -r '.acquired' "$infofile" 2>/dev/null || echo "unknown")
      if kill -0 "$pid" 2>/dev/null; then
        echo "  $resource: held by PID $pid since $acquired"
      else
        echo "  $resource: STALE (PID $pid dead, acquired $acquired) — cleaning up"
        rm -f "$LOCKS_DIR/${resource}.lock" "$infofile"
      fi
    done
    [ "$found" -eq 0 ] && echo "  No active locks."
    ;;

  heartbeat)
    # Write heartbeat for current process (call from agent loop)
    pid="${2:-$$}"
    cpu=$(ps -o %cpu= -p "$pid" 2>/dev/null | tr -d ' ' || echo "0")
    mem_kb=$(ps -o rss= -p "$pid" 2>/dev/null | tr -d ' ' || echo "0")
    mem_mb=$(( ${mem_kb:-0} / 1024 ))
    jq -n --argjson pid "$pid" --arg ts "$(date -Iseconds)" \
      --arg cpu "$cpu" --argjson mem "$mem_mb" \
      '{pid:$pid,ts:$ts,cpu:$cpu,mem_mb:$mem}' \
      > "$HEARTBEAT_DIR/$pid.json"
    ;;

  prune)
    echo "=== Pruning dead agents and stale locks ==="
    [ -f "$REGISTRY" ] || { echo "No registry."; exit 0; }

    pruned=0
    # Prune dead agents from registry
    tmp=$(mktemp)
    while read -r pid; do
      [ -z "$pid" ] && continue
      alive=false

      # Check heartbeat first
      hb_file="$HEARTBEAT_DIR/$pid.json"
      if [ -f "$hb_file" ]; then
        hb_ts=$(jq -r '.ts' "$hb_file" 2>/dev/null)
        hb_epoch=$(date -d "$hb_ts" +%s 2>/dev/null || echo 0)
        now_epoch=$(date +%s)
        if [ $((now_epoch - hb_epoch)) -lt 30 ]; then
          alive=true
        fi
      fi

      # Fall back to kill -0
      if [ "$alive" = "false" ] && kill -0 "$pid" 2>/dev/null; then
        alive=true
      fi

      if [ "$alive" = "false" ]; then
        echo "  Removing dead agent: PID $pid"
        rm -f "$HEARTBEAT_DIR/$pid.json"
        rm -rf "$AGENTS_DIR/outbox/shell-$pid" "$AGENTS_DIR/outbox/task-$pid"
        pruned=$((pruned + 1))
      fi
    done < <(jq -r '.agents[].pid' "$REGISTRY" 2>/dev/null)

    # Rebuild registry with only alive agents
    alive_pids=""
    while read -r pid; do
      [ -z "$pid" ] && continue
      if kill -0 "$pid" 2>/dev/null; then
        alive_pids="$alive_pids $pid"
      fi
    done < <(jq -r '.agents[].pid' "$REGISTRY" 2>/dev/null)

    if [ -n "$alive_pids" ]; then
      jq_filter=$(echo "$alive_pids" | tr ' ' '\n' | grep -v '^$' | while read -r p; do echo "$p"; done | jq -R -s 'split("\n") | map(select(. != "") | tonumber)')
      jq --argjson alive "$jq_filter" '.agents = [.agents[] | select(.pid | IN($alive[]))]' "$REGISTRY" > "$tmp" && mv "$tmp" "$REGISTRY"
    else
      jq '.agents = []' "$REGISTRY" > "$tmp" && mv "$tmp" "$REGISTRY"
    fi

    # Prune stale locks
    for infofile in "$LOCKS_DIR"/*.lock.info; do
      [ -f "$infofile" ] || continue
      pid=$(jq -r '.pid' "$infofile" 2>/dev/null || echo "0")
      if ! kill -0 "$pid" 2>/dev/null; then
        resource=$(basename "$infofile" .lock.info)
        echo "  Removing stale lock: $resource (PID $pid)"
        rm -f "$LOCKS_DIR/${resource}.lock" "$infofile"
        pruned=$((pruned + 1))
      fi
    done

    # Prune stale heartbeats
    for hb in "$HEARTBEAT_DIR"/*.json; do
      [ -f "$hb" ] || continue
      pid=$(basename "$hb" .json)
      if ! kill -0 "$pid" 2>/dev/null; then
        rm -f "$hb"
      fi
    done

    echo "Pruned $pruned dead entries."
    ;;

  conflicts)
    echo "=== Conflict Detection ==="

    # Concurrent nix operations
    nix_count=$(pgrep -c -f "nix-build|nixos-rebuild" 2>/dev/null || true)
    nix_count=$(echo "${nix_count:-0}" | tr -d '[:space:]')
    if [ "${nix_count:-0}" -gt 1 ] 2>/dev/null; then
      echo "WARNING: $nix_count concurrent nix operations"
      pgrep -af "nix-build|nixos-rebuild" 2>/dev/null | sed 's/^/  /'
    fi

    # Stale locks
    for infofile in "$LOCKS_DIR"/*.lock.info; do
      [ -f "$infofile" ] || continue
      pid=$(jq -r '.pid' "$infofile" 2>/dev/null || echo "0")
      if ! kill -0 "$pid" 2>/dev/null; then
        echo "STALE LOCK: $(basename "$infofile" .lock.info) held by dead PID $pid"
      fi
    done

    # Genome contention
    genome_writers=$(lsof "$STATE_DIR/genome/manifest.json" 2>/dev/null | tail -n+2 | wc -l || true)
    genome_writers=$(echo "${genome_writers:-0}" | tr -d '[:space:]')
    if [ "${genome_writers:-0}" -gt 1 ] 2>/dev/null; then
      echo "WARNING: $genome_writers processes writing to genome"
    fi

    echo "Scan complete."
    ;;

  help|*)
    echo "claude-os-agents — Multi-agent coordinator"
    echo ""
    echo "  list                  List active agents (with heartbeat status)"
    echo "  status                Agent registry JSON"
    echo "  send <id> <msg>       Message an agent"
    echo "  broadcast <msg>       Message all agents"
    echo "  lock <res> [timeout]  Acquire flock (default 30s)"
    echo "  unlock <resource>     Release flock"
    echo "  locks                 Show active locks"
    echo "  heartbeat [pid]       Write heartbeat for a process"
    echo "  prune                 Remove dead agents and stale locks"
    echo "  conflicts             Detect conflicts"
    ;;
esac
