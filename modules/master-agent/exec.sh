#!/usr/bin/env bash
# claude-os-exec — Tiered execution with audit trail and review queue
#
# Every operation in Claude-OS goes through this gate.
# Tier 1 (safe):        auto-execute, log only
# Tier 2 (reversible):  execute + pre-snapshot, logged
# Tier 3 (irreversible): require confirmation or queue for review
#
# Usage:
#   claude-os-exec <command...>         — Auto-classify and execute
#   claude-os-exec --tier1 <command...> — Force tier 1 (safe)
#   claude-os-exec --tier2 <command...> — Force tier 2 (reversible)
#   claude-os-exec --tier3 <command...> — Force tier 3 (confirm)
#   claude-os-exec --audit [n]          — Show audit log
#   claude-os-exec --review             — Show pending review queue
#   claude-os-exec --approve <id>       — Approve a queued action

set -uo pipefail

STATE_DIR="${CLAUDE_OS_STATE:-/var/lib/claude-os}"
AUDIT_LOG="$STATE_DIR/audit.log"
REVIEW_DIR="$STATE_DIR/review-queue"
AGENT_ID="${CLAUDE_OS_AGENT_ID:-shell-$$}"

export PATH="/run/current-system/sw/bin:$PATH"

mkdir -p "$REVIEW_DIR"
touch "$AUDIT_LOG"

# Classify a command into a tier
classify() {
  local cmd="$1"

  # Tier 1: read-only, queries, safe operations
  case "$cmd" in
    ls*|cat*|head*|tail*|grep*|find*|wc*|du*|df*|ps*|top*|htop*|\
    systemctl\ status*|systemctl\ is-active*|systemctl\ list*|\
    journalctl*|uname*|whoami*|id*|date*|uptime*|\
    claude-os-sense*|claude-os-memory\ recall*|claude-os-memory\ stats*|\
    claude-os-memory\ neighbors*|claude-os-evolve\ status*|claude-os-evolve\ log*|\
    claude-os-evolve\ fitness*|claude-os-agents\ list*|claude-os-agents\ status*|\
    claude-os-agents\ locks*|claude-os-agents\ conflicts*|\
    claude-os-cap\ search*|claude-os-cap\ has*|claude-os-cap\ list*|\
    claude-os-plan\ list*|claude-os-plan\ show*|claude-os-plan\ active*|\
    claude-os-route\ check*|claude-os-route\ status*|\
    nix\ search*|nix\ eval*|git\ status*|git\ log*|git\ diff*|\
    curl*|wget*|ping*|host*|dig*)
      echo 1
      return
      ;;
  esac

  # Tier 3: irreversible, dangerous operations
  case "$cmd" in
    nixos-rebuild*|claude-os-evolve\ apply*|\
    rm\ -rf*|rm\ -r\ /*|rmdir\ /*|\
    mkfs*|fdisk*|parted*|dd\ *|\
    systemctl\ disable*|systemctl\ mask*|\
    claude-os-evolve\ remove-package*|\
    passwd*|usermod*|userdel*|\
    iptables*|nft*|\
    shutdown*|reboot*|poweroff*|\
    *\|\ sudo*|sudo\ rm*|sudo\ dd*)
      echo 3
      return
      ;;
  esac

  # Tier 2: everything else (package installs, file writes, service control)
  echo 2
}

audit() {
  local tier="$1" cmd="$2" result="${3:-pending}"
  local ts=$(date -Iseconds)
  echo "[$ts] [tier$tier] [$AGENT_ID] [$result] $cmd" >> "$AUDIT_LOG"
}

exec_tier1() {
  local cmd="$*"
  audit 1 "$cmd" "exec"
  eval "$cmd"
}

exec_tier2() {
  local cmd="$*"
  audit 2 "$cmd" "exec"
  eval "$cmd"
  local exit_code=$?
  if [ $exit_code -ne 0 ]; then
    audit 2 "$cmd" "failed:$exit_code"
  fi
  return $exit_code
}

exec_tier3() {
  local cmd="$*"

  # Check if we're in an interactive session
  if [ -t 0 ] && [ -t 1 ]; then
    # Interactive: ask for confirmation
    echo ""
    echo "  TIER 3 — Irreversible operation detected:"
    echo "  > $cmd"
    echo ""
    read -p "  Execute? [y/N] " confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
      audit 3 "$cmd" "approved"
      eval "$cmd"
    else
      audit 3 "$cmd" "denied"
      echo "  Cancelled."
      return 1
    fi
  else
    # Non-interactive (master agent, cron): queue for review
    local review_id="review-$(date +%s)-$(head -c3 /dev/urandom | od -An -tx1 | tr -d ' ')"
    jq -n --arg id "$review_id" --arg cmd "$cmd" --arg agent "$AGENT_ID" --arg ts "$(date -Iseconds)" \
      '{id: $id, command: $cmd, agent: $agent, timestamp: $ts, status: "pending"}' \
      > "$REVIEW_DIR/$review_id.json"
    audit 3 "$cmd" "queued:$review_id"
    echo "QUEUED: Action requires human review (ID: $review_id)"
    echo "Run 'claude-os-exec --review' to see pending actions."
    return 2
  fi
}

case "${1:-}" in
  --tier1)
    shift
    exec_tier1 "$@"
    ;;

  --tier2)
    shift
    exec_tier2 "$@"
    ;;

  --tier3)
    shift
    exec_tier3 "$@"
    ;;

  --audit)
    n="${2:-20}"
    echo "=== Audit Log (last $n entries) ==="
    tail -"$n" "$AUDIT_LOG"
    ;;

  --review)
    echo "=== Pending Review Queue ==="
    found=0
    for review_file in "$REVIEW_DIR"/*.json; do
      [ -f "$review_file" ] || continue
      status=$(jq -r '.status' "$review_file" 2>/dev/null)
      [ "$status" = "pending" ] || continue
      found=1
      id=$(jq -r '.id' "$review_file")
      cmd=$(jq -r '.command' "$review_file")
      agent=$(jq -r '.agent' "$review_file")
      ts=$(jq -r '.timestamp' "$review_file")
      echo ""
      echo "  ID: $id"
      echo "  Command: $cmd"
      echo "  Agent: $agent"
      echo "  Queued: $ts"
    done
    [ "$found" -eq 0 ] && echo "  No pending actions."
    ;;

  --approve)
    review_id="${2:?Usage: claude-os-exec --approve <review-id>}"
    review_file="$REVIEW_DIR/$review_id.json"
    [ -f "$review_file" ] || { echo "Review ID not found: $review_id"; exit 1; }

    cmd=$(jq -r '.command' "$review_file")
    echo "Approving: $cmd"
    jq '.status = "approved"' "$review_file" > "$review_file.tmp" && mv "$review_file.tmp" "$review_file"
    audit 3 "$cmd" "approved-from-queue"
    eval "$cmd"
    ;;

  --reject)
    review_id="${2:?Usage: claude-os-exec --reject <review-id>}"
    review_file="$REVIEW_DIR/$review_id.json"
    [ -f "$review_file" ] || { echo "Review ID not found: $review_id"; exit 1; }

    jq '.status = "rejected"' "$review_file" > "$review_file.tmp" && mv "$review_file.tmp" "$review_file"
    audit 3 "$(jq -r '.command' "$review_file")" "rejected"
    echo "Rejected."
    ;;

  --help|"")
    echo "claude-os-exec — Tiered execution with audit trail"
    echo ""
    echo "  <command>          Auto-classify and execute"
    echo "  --tier1 <cmd>      Force safe execution"
    echo "  --tier2 <cmd>      Force reversible execution"
    echo "  --tier3 <cmd>      Force confirmation-required execution"
    echo "  --audit [n]        Show last n audit entries"
    echo "  --review           Show pending review queue"
    echo "  --approve <id>     Approve a queued action"
    echo "  --reject <id>      Reject a queued action"
    echo ""
    echo "Tier 1 (safe):        ls, cat, ps, systemctl status, claude-os-sense, etc."
    echo "Tier 2 (reversible):  package install, file write, service start/stop"
    echo "Tier 3 (irreversible): nixos-rebuild, rm -rf, system config changes"
    ;;

  *)
    # Auto-classify
    cmd="$*"
    tier=$(classify "$cmd")
    case "$tier" in
      1) exec_tier1 "$cmd" ;;
      2) exec_tier2 "$cmd" ;;
      3) exec_tier3 "$cmd" ;;
    esac
    ;;
esac
