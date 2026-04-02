#!/usr/bin/env bash
# claude-os-sense — Query live system awareness
# Fast read-only queries into the awareness layer.
#
# Usage:
#   claude-os-sense              — Full system snapshot (JSON)
#   claude-os-sense brief        — One-line system summary
#   claude-os-sense resources    — CPU/memory/disk
#   claude-os-sense signals [n]  — Recent signals
#   claude-os-sense health       — Health status
#   claude-os-sense agents       — Agent status
#   claude-os-sense network      — Network status
#   claude-os-sense watch        — Live signal stream (tail -f)

set -uo pipefail

STATE_DIR="${CLAUDE_OS_STATE:-/var/lib/claude-os}"
AWARENESS_DIR="$STATE_DIR/awareness"

export PATH="/run/current-system/sw/bin:$PATH"

case "${1:-snapshot}" in
  snapshot|"")
    cat "$AWARENESS_DIR/system-status.json" 2>/dev/null || echo '{"error": "No snapshot yet"}'
    ;;

  brief)
    if [ -f "$AWARENESS_DIR/system-status.json" ]; then
      jq -r '
        "CPU: \(.resources.cpu.load_1m // "?") load | " +
        "MEM: \(.resources.memory.used_pct // "?")% | " +
        "DISK: \(.resources.disk.root_used_pct // "?")% | " +
        "Agents: \(.agents.alive // 0) alive | " +
        "Gen: \(.genome.generation // 0) | " +
        "Caps: \(.genome.capabilities // 0) | " +
        "Mem: \(.memory.entities // 0) entities | " +
        "Net: \(if .network.online then "UP" else "DOWN" end) | " +
        "Signals: \(.pending_signals // 0) pending"
      ' "$AWARENESS_DIR/system-status.json" 2>/dev/null
    else
      echo "Awareness engine not yet running."
    fi
    ;;

  resources)
    cat "$AWARENESS_DIR/resources.json" 2>/dev/null | jq . || echo "No resource data"
    ;;

  signals)
    n="${2:-20}"
    if [ -f "$AWARENESS_DIR/signal-stream.jsonl" ]; then
      echo "=== Last $n Signals ==="
      tail -"$n" "$AWARENESS_DIR/signal-stream.jsonl" | jq -r '"\(.ts) [\(.severity)] \(.source)/\(.type): \(.message)"' 2>/dev/null
    else
      echo "No signals yet."
    fi
    ;;

  pending)
    echo "=== Pending Signals ==="
    for sig in "$AWARENESS_DIR/signals"/*.json; do
      [ -f "$sig" ] || { echo "None."; break; }
      jq -r '"\(.severity | ascii_upcase): [\(.source)] \(.message)"' "$sig" 2>/dev/null
    done
    ;;

  health)
    cat "$AWARENESS_DIR/health.json" 2>/dev/null | jq . || echo "No health data"
    ;;

  agents)
    cat "$AWARENESS_DIR/agents.json" 2>/dev/null | jq . || echo "No agent data"
    ;;

  network)
    cat "$AWARENESS_DIR/network.json" 2>/dev/null | jq . || echo "No network data"
    ;;

  watch)
    echo "Live signal stream (Ctrl+C to stop)..."
    tail -f "$AWARENESS_DIR/signal-stream.jsonl" 2>/dev/null | \
      jq -r '"\(.ts) [\(.severity)] \(.source)/\(.type): \(.message)"' 2>/dev/null
    ;;

  help|*)
    echo "claude-os-sense — Query live system awareness"
    echo ""
    echo "  (no args)    Full JSON snapshot"
    echo "  brief        One-line summary"
    echo "  resources    CPU/memory/disk"
    echo "  signals [n]  Recent signals"
    echo "  pending      Unprocessed signals"
    echo "  health       Health guardian status"
    echo "  agents       Agent status"
    echo "  network      Network status"
    echo "  watch        Live signal stream"
    ;;
esac
