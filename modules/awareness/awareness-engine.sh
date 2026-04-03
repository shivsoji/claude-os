#!/usr/bin/env bash
# claude-os-awareness — The nervous system daemon
# Aggregates ALL system signals into a unified stream.
# Feeds the master agent with processed, actionable signals.
#
# Signal sources:
#   1. journald    — service failures, kernel events, auth, errors
#   2. resources   — CPU, memory, disk, network, swap
#   3. processes   — runaway processes, zombie detection, OOM
#   4. agents      — shell agent activity, conflicts, load
#   5. evolution   — genome changes, capability gaps
#   6. network     — connectivity, DNS, open ports

set -uo pipefail

STATE_DIR="${CLAUDE_OS_STATE:-/var/lib/claude-os}"
AWARENESS_DIR="$STATE_DIR/awareness"
SIGNALS_DIR="$AWARENESS_DIR/signals"
STREAM_FILE="$AWARENESS_DIR/signal-stream.jsonl"
SNAPSHOT_FILE="$AWARENESS_DIR/system-status.json"
AGENTS_DIR="$STATE_DIR/agents"

export PATH="/run/current-system/sw/bin:$PATH"

mkdir -p "$SIGNALS_DIR" "$AWARENESS_DIR/history"

log() {
  echo "[$(date -Iseconds)] [awareness] $*"
}

# --- Emit a signal to the stream ---
emit_signal() {
  local severity="$1" source="$2" signal_type="$3" message="$4" details="${5:-{}}"
  local ts=$(date -Iseconds)
  local sig="{\"ts\":\"$ts\",\"severity\":\"$severity\",\"source\":\"$source\",\"type\":\"$signal_type\",\"message\":\"$message\",\"details\":$details}"

  # Append to stream
  echo "$sig" >> "$STREAM_FILE"

  # Write to signals dir for master to pick up
  if [ "$severity" = "critical" ] || [ "$severity" = "warning" ]; then
    echo "$sig" > "$SIGNALS_DIR/$(date +%s%N)-${source}-${signal_type}.json"
  fi
}

# --- Signal Source: System Resources ---
sense_resources() {
  local mem_total=$(grep MemTotal /proc/meminfo | awk '{print $2}')
  local mem_avail=$(grep MemAvailable /proc/meminfo | awk '{print $2}')
  local mem_pct=$((100 - (mem_avail * 100 / mem_total)))
  local swap_total=$(grep SwapTotal /proc/meminfo | awk '{print $2}')
  local swap_used=$(( swap_total - $(grep SwapFree /proc/meminfo | awk '{print $2}') ))
  local load=$(cut -d' ' -f1 /proc/loadavg)
  local disk_pct=$(df / | tail -1 | awk '{print $5}' | tr -d '%')
  local cpu_count=$(nproc)

  # Write snapshot
  cat > "$AWARENESS_DIR/resources.json" << EOF
{
  "ts": "$(date -Iseconds)",
  "cpu": {"load_1m": $load, "cores": $cpu_count},
  "memory": {"total_kb": $mem_total, "available_kb": $mem_avail, "used_pct": $mem_pct},
  "swap": {"total_kb": $swap_total, "used_kb": $swap_used},
  "disk": {"root_used_pct": $disk_pct}
}
EOF

  # Emit signals on thresholds
  if [ "$mem_pct" -gt 90 ]; then
    emit_signal "critical" "resources" "memory-pressure" "Memory usage at ${mem_pct}%" "{\"used_pct\":$mem_pct}"
  elif [ "$mem_pct" -gt 75 ]; then
    emit_signal "warning" "resources" "memory-high" "Memory usage at ${mem_pct}%" "{\"used_pct\":$mem_pct}"
  fi

  if [ "$disk_pct" -gt 90 ]; then
    emit_signal "critical" "resources" "disk-pressure" "Disk usage at ${disk_pct}%" "{\"used_pct\":$disk_pct}"
  elif [ "$disk_pct" -gt 75 ]; then
    emit_signal "warning" "resources" "disk-high" "Disk usage at ${disk_pct}%" "{\"used_pct\":$disk_pct}"
  fi

  # Load average > 2x cores
  local load_int=${load%.*}
  if [ "$load_int" -gt $((cpu_count * 2)) ]; then
    emit_signal "warning" "resources" "high-load" "Load average $load (${cpu_count} cores)" "{\"load\":$load}"
  fi
}

# --- Signal Source: Processes ---
sense_processes() {
  # Zombie processes
  local zombies=$(ps aux | awk '$8 ~ /Z/' | wc -l)
  if [ "$zombies" -gt 0 ]; then
    emit_signal "warning" "processes" "zombies" "$zombies zombie processes detected" "{\"count\":$zombies}"
  fi

  # Top CPU consumers
  local top_cpu=$(ps aux --sort=-%cpu | head -4 | tail -3 | awk '{printf "{\"pid\":%s,\"cpu\":%s,\"cmd\":\"%s\"},", $2, $3, $11}')
  echo "{\"ts\":\"$(date -Iseconds)\",\"top_cpu\":[${top_cpu%,}]}" > "$AWARENESS_DIR/processes.json"

  # Any process using >50% CPU for detection
  ps aux --sort=-%cpu | awk 'NR>1 && $3>50 {print $2, $3, $11}' | while read -r pid cpu cmd; do
    emit_signal "warning" "processes" "cpu-hog" "PID $pid ($cmd) using ${cpu}% CPU" "{\"pid\":$pid,\"cpu\":$cpu,\"cmd\":\"$cmd\"}"
  done
}

# --- Signal Source: Systemd Services ---
sense_services() {
  local failed=$(systemctl --failed --no-legend 2>/dev/null)
  local failed_count=$(echo "$failed" | grep -c '.' || echo 0)

  # Write service status
  local active_count=$(systemctl list-units --type=service --state=active --no-legend 2>/dev/null | wc -l)
  echo "{\"ts\":\"$(date -Iseconds)\",\"active\":$active_count,\"failed\":$failed_count}" > "$AWARENESS_DIR/services.json"

  if [ "$failed_count" -gt 0 ]; then
    echo "$failed" | while read -r unit loaded active sub desc; do
      emit_signal "critical" "services" "service-failed" "Service failed: $unit" "{\"unit\":\"$unit\",\"sub\":\"$sub\"}"
    done
  fi
}

# --- Signal Source: Journald (recent errors) ---
sense_journal() {
  # Scan last 10 seconds of journal for errors/warnings
  journalctl --since "10 seconds ago" --priority=err --no-pager -o json 2>/dev/null | \
    head -5 | while read -r line; do
      local unit=$(echo "$line" | jq -r '._SYSTEMD_UNIT // "unknown"' 2>/dev/null)
      local msg=$(echo "$line" | jq -r '.MESSAGE // ""' 2>/dev/null | head -c 200)
      if [ -n "$msg" ]; then
        emit_signal "warning" "journal" "error-logged" "$unit: $msg" "{\"unit\":\"$unit\"}"
      fi
    done
}

# --- Signal Source: Agent Activity ---
sense_agents() {
  local registry="$AGENTS_DIR/registry.json"
  [ -f "$registry" ] || return

  local agent_count=$(jq '.agents | length' "$registry" 2>/dev/null || echo 0)
  local alive=0
  local dead_pids=""

  # Check which agents are actually alive
  for pid in $(jq -r '.agents[].pid' "$registry" 2>/dev/null); do
    if kill -0 "$pid" 2>/dev/null; then
      alive=$((alive + 1))
    else
      dead_pids="$dead_pids $pid"
    fi
  done

  local dead=$((agent_count - alive))

  # Write agent status
  cat > "$AWARENESS_DIR/agents.json" << EOF
{
  "ts": "$(date -Iseconds)",
  "registered": $agent_count,
  "alive": $alive,
  "dead": $dead,
  "agents": $(jq '.agents' "$registry" 2>/dev/null || echo '[]')
}
EOF

  if [ "$dead" -gt 0 ]; then
    emit_signal "info" "agents" "dead-agents" "$dead dead agents detected (registered but PID gone)" "{\"dead\":$dead,\"dead_pids\":\"${dead_pids# }\"}"
    # Auto-prune dead agents
    for pid in $dead_pids; do
      local tmp=$(mktemp)
      jq --arg pid "$pid" '.agents = [.agents[] | select(.pid != ($pid|tonumber))]' "$registry" > "$tmp" 2>/dev/null && mv "$tmp" "$registry"
    done
  fi

  # Detect resource conflicts: multiple agents modifying same files
  # (simplified: check if multiple agents are running nix operations)
  local nix_procs=$(pgrep -c "nix-build\|nixos-rebuild" 2>/dev/null || echo 0)
  if [ "$nix_procs" -gt 1 ]; then
    emit_signal "warning" "agents" "nix-conflict" "$nix_procs concurrent nix operations detected" "{\"count\":$nix_procs}"
  fi
}

# --- Signal Source: Network ---
sense_network() {
  local online="false"
  if ping -c1 -W2 1.1.1.1 >/dev/null 2>&1; then
    online="true"
  fi

  local dns_ok="false"
  if host -W2 nixos.org >/dev/null 2>&1; then
    dns_ok="true"
  fi

  echo "{\"ts\":\"$(date -Iseconds)\",\"online\":$online,\"dns\":$dns_ok}" > "$AWARENESS_DIR/network.json"

  if [ "$online" = "false" ]; then
    emit_signal "critical" "network" "offline" "System is offline — no internet connectivity" "{}"
  fi
}

# --- Build unified snapshot ---
build_snapshot() {
  local genome_gen=$(jq '.generation' "$STATE_DIR/genome/manifest.json" 2>/dev/null || echo 0)
  local genome_caps=$(jq '.capabilities | length' "$STATE_DIR/genome/manifest.json" 2>/dev/null || echo 0)
  local genome_skills=$(jq '.skills | length' "$STATE_DIR/genome/manifest.json" 2>/dev/null || echo 0)
  local mem_entities=$(sqlite3 "$STATE_DIR/memory/graph.sqlite" "SELECT COUNT(*) FROM entities;" 2>/dev/null || echo 0)
  local pending_signals=$(ls "$SIGNALS_DIR"/*.json 2>/dev/null | wc -l || echo 0)

  # Merge all sub-snapshots
  jq -n \
    --arg ts "$(date -Iseconds)" \
    --argjson resources "$(cat "$AWARENESS_DIR/resources.json" 2>/dev/null || echo '{}')" \
    --argjson services "$(cat "$AWARENESS_DIR/services.json" 2>/dev/null || echo '{}')" \
    --argjson processes "$(cat "$AWARENESS_DIR/processes.json" 2>/dev/null || echo '{}')" \
    --argjson agents "$(cat "$AWARENESS_DIR/agents.json" 2>/dev/null || echo '{}')" \
    --argjson network "$(cat "$AWARENESS_DIR/network.json" 2>/dev/null || echo '{}')" \
    --argjson gen "$genome_gen" \
    --argjson caps "$genome_caps" \
    --argjson skills "$genome_skills" \
    --argjson mem_entities "$mem_entities" \
    --argjson pending "$pending_signals" \
    '{
      timestamp: $ts,
      resources: $resources,
      services: $services,
      processes: $processes,
      agents: $agents,
      network: $network,
      genome: {generation: $gen, capabilities: $caps, skills: $skills},
      memory: {entities: $mem_entities},
      pending_signals: $pending
    }' > "$SNAPSHOT_FILE"
}

# --- Trim signal stream (keep last 1000 lines) ---
trim_stream() {
  if [ -f "$STREAM_FILE" ] && [ "$(wc -l < "$STREAM_FILE")" -gt 1000 ]; then
    tail -500 "$STREAM_FILE" > "$STREAM_FILE.tmp" && mv "$STREAM_FILE.tmp" "$STREAM_FILE"
  fi
}

# ==========================================
# Main sensing loop
# ==========================================
log "Awareness engine starting"
touch "$STREAM_FILE"

CYCLE=0
while true; do
  CYCLE=$((CYCLE + 1))

  # Every cycle (5s): resources + processes
  sense_resources
  sense_processes

  # Every 2 cycles (10s): services + agents
  if [ $((CYCLE % 2)) -eq 0 ]; then
    sense_services
    sense_agents
  fi

  # Every 6 cycles (30s): journal + network + full snapshot
  if [ $((CYCLE % 6)) -eq 0 ]; then
    sense_journal
    sense_network
    build_snapshot
    log "Snapshot built (cycle $CYCLE, $(ls "$SIGNALS_DIR"/*.json 2>/dev/null | wc -l) pending signals)"
  fi

  # Every 60 cycles (5 min): trim + archive
  if [ $((CYCLE % 60)) -eq 0 ]; then
    trim_stream
    # Archive snapshot for history
    cp "$SNAPSHOT_FILE" "$AWARENESS_DIR/history/snapshot-$(date +%Y%m%d%H%M).json" 2>/dev/null || true
    # Keep only last 288 snapshots (24h at 5min intervals)
    ls -t "$AWARENESS_DIR/history/"*.json 2>/dev/null | tail -n +289 | xargs rm -f 2>/dev/null || true
  fi

  sleep 5
done
