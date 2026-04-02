#!/usr/bin/env bash
# claude-os-health — Self-healing health guardian
# Runs as root (via systemd timer) every 30 seconds.
# Autonomously keeps the system intact.
#
# Usage:
#   claude-os-health check-and-heal   — Full health check + auto-healing
#   claude-os-health status            — Report health status
#   claude-os-health restart <service> — Restart a service
#   claude-os-health kill-hog <pid>    — Kill a runaway process
#   claude-os-health clear-disk        — Emergency disk cleanup

set -uo pipefail

STATE_DIR="/var/lib/claude-os"
AWARENESS_DIR="$STATE_DIR/awareness"
SIGNALS_DIR="$AWARENESS_DIR/signals"
HEAL_LOG="$AWARENESS_DIR/heal.log"

export PATH="/run/current-system/sw/bin:$PATH"

mkdir -p "$SIGNALS_DIR"

heal_log() {
  echo "[$(date -Iseconds)] [health] $*" >> "$HEAL_LOG"
}

emit_heal_signal() {
  local action="$1" details="$2"
  echo "{\"ts\":\"$(date -Iseconds)\",\"severity\":\"info\",\"source\":\"health-guardian\",\"type\":\"heal-action\",\"message\":\"$action\",\"details\":$details}" \
    > "$SIGNALS_DIR/heal-$(date +%s%N).json"
}

case "${1:-help}" in
  check-and-heal)
    # === 1. Restart failed critical services ===
    CRITICAL_SERVICES="claude-os-master claude-os-awareness sshd NetworkManager"
    for svc in $CRITICAL_SERVICES; do
      if systemctl is-failed "$svc.service" >/dev/null 2>&1; then
        heal_log "Restarting failed service: $svc"
        systemctl restart "$svc.service" 2>/dev/null
        emit_heal_signal "Restarted failed service: $svc" "{\"service\":\"$svc\"}"
      fi
    done

    # === 2. Memory pressure relief ===
mem_avail=$(grep MemAvailable /proc/meminfo | awk '{print $2}')
mem_total=$(grep MemTotal /proc/meminfo | awk '{print $2}')
mem_pct=$((100 - (mem_avail * 100 / mem_total)))

    if [ "$mem_pct" -gt 95 ]; then
      heal_log "CRITICAL: Memory at ${mem_pct}%, clearing caches"
      sync
      echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
      emit_heal_signal "Dropped page caches (memory at ${mem_pct}%)" "{\"mem_pct\":$mem_pct}"
    fi

    # === 3. Disk pressure relief ===
disk_pct=$(df / | tail -1 | awk '{print $5}' | tr -d '%')
    if [ "$disk_pct" -gt 90 ]; then
      heal_log "Disk at ${disk_pct}%, running cleanup"

      # Clear nix garbage
      nix-collect-garbage --delete-older-than 3d 2>/dev/null || true

      # Clear old journal logs
      journalctl --vacuum-time=3d 2>/dev/null || true

      # Clear old awareness history
      find "$AWARENESS_DIR/history" -name "*.json" -mtime +1 -delete 2>/dev/null || true

      # Clear old signal stream
      if [ -f "$AWARENESS_DIR/signal-stream.jsonl" ]; then
        tail -100 "$AWARENESS_DIR/signal-stream.jsonl" > "$AWARENESS_DIR/signal-stream.jsonl.tmp"
        mv "$AWARENESS_DIR/signal-stream.jsonl.tmp" "$AWARENESS_DIR/signal-stream.jsonl"
      fi

      emit_heal_signal "Disk cleanup performed (was at ${disk_pct}%)" "{\"disk_pct\":$disk_pct}"
    fi

    # === 4. Kill runaway processes ===
    # Processes using >80% CPU for extended time (check /proc/pid/stat)
    ps aux --sort=-%cpu | awk 'NR>1 && $3>80' | while read -r user pid cpu mem vsz rss tty stat start time cmd; do
      # Don't kill system or critical processes
      case "$cmd" in
        *qemu*|*systemd*|*journald*|*sshd*|*claude-os*|*node*|*claude*) continue ;;
      esac
      # Only kill if running for > 5 minutes with high CPU
  etime=$(ps -o etimes= -p "$pid" 2>/dev/null | tr -d ' ')
      if [ -n "$etime" ] && [ "$etime" -gt 300 ]; then
        heal_log "Killing runaway process: PID $pid ($cmd) at ${cpu}% CPU for ${etime}s"
        kill -15 "$pid" 2>/dev/null
        sleep 2
        kill -9 "$pid" 2>/dev/null || true
        emit_heal_signal "Killed runaway: PID $pid ($cmd)" "{\"pid\":$pid,\"cpu\":$cpu,\"cmd\":\"$cmd\"}"
      fi
    done

    # === 5. Zombie reaping ===
zombies=$(ps aux | awk '$8 ~ /Z/ {print $2}')
    if [ -n "$zombies" ]; then
      for zpid in $zombies; do
    ppid=$(ps -o ppid= -p "$zpid" 2>/dev/null | tr -d ' ')
        if [ -n "$ppid" ] && [ "$ppid" != "1" ]; then
          heal_log "Sending SIGCHLD to parent $ppid of zombie $zpid"
          kill -17 "$ppid" 2>/dev/null || true
        fi
      done
    fi

    # === 6. Ensure critical directories exist ===
    for dir in memory/facts skills genome evolution agents/inbox agents/outbox awareness goals; do
      mkdir -p "$STATE_DIR/$dir" 2>/dev/null || true
      chown claude:users "$STATE_DIR/$dir" 2>/dev/null || true
    done

    # === 7. Write health status ===
failed_count=$(systemctl --failed --no-legend 2>/dev/null | wc -l)
    cat > "$AWARENESS_DIR/health.json" << EOF
{
  "ts": "$(date -Iseconds)",
  "healthy": $([ "$failed_count" -eq 0 ] && [ "$mem_pct" -lt 90 ] && [ "$disk_pct" -lt 90 ] && echo "true" || echo "false"),
  "memory_pct": $mem_pct,
  "disk_pct": $disk_pct,
  "failed_services": $failed_count,
  "heals_today": $(grep "$(date +%Y-%m-%d)" "$HEAL_LOG" 2>/dev/null | wc -l || echo 0)
}
EOF
    ;;

  status)
    if [ -f "$AWARENESS_DIR/health.json" ]; then
      cat "$AWARENESS_DIR/health.json" | jq .
    else
      echo "No health data yet. Waiting for first check."
    fi
    ;;

  restart)
    svc="${2:?Usage: claude-os-health restart <service>}"
    systemctl restart "$svc" 2>&1
    heal_log "Manual restart: $svc"
    emit_heal_signal "Manual restart: $svc" "{\"service\":\"$svc\"}"
    systemctl status "$svc" --no-pager
    ;;

  kill-hog)
    pid="${2:?Usage: claude-os-health kill-hog <pid>}"
cmd=$(ps -o comm= -p "$pid" 2>/dev/null)
    kill -15 "$pid" 2>/dev/null
    sleep 2
    kill -9 "$pid" 2>/dev/null || true
    heal_log "Manual kill: PID $pid ($cmd)"
    echo "Killed PID $pid ($cmd)"
    ;;

  clear-disk)
    echo "Emergency disk cleanup..."
    nix-collect-garbage --delete-older-than 1d 2>/dev/null || true
    journalctl --vacuum-size=100M 2>/dev/null || true
    find /tmp -type f -mtime +1 -delete 2>/dev/null || true
    heal_log "Emergency disk cleanup"
    echo "Done. Disk: $(df -h / | tail -1 | awk '{print $5}') used"
    ;;

  help|*)
    echo "claude-os-health — Self-healing health guardian"
    echo ""
    echo "  check-and-heal   Full check + auto-heal (run by timer)"
    echo "  status           Health status report"
    echo "  restart <svc>    Restart a service"
    echo "  kill-hog <pid>   Kill a runaway process"
    echo "  clear-disk       Emergency disk cleanup"
    ;;
esac
