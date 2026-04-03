#!/usr/bin/env bash
# claude-os-evolve — The evolution engine
# Called by Claude (master or shell agent) to mutate the system.
# Each mutation is tracked, versioned, and rollback-capable.
#
# Usage:
#   claude-os-evolve add-package <pkg>         — Add a package to the genome
#   claude-os-evolve remove-package <pkg>      — Remove a package
#   claude-os-evolve add-service <name> <desc> — Register a new service
#   claude-os-evolve add-capability <cap>      — Register a new capability
#   claude-os-evolve add-skill <name> <file>   — Register a learned skill
#   claude-os-evolve apply                     — Apply pending mutations (nixos-rebuild)
#   claude-os-evolve rollback                  — Rollback to previous generation
#   claude-os-evolve status                    — Show current genome status
#   claude-os-evolve log                       — Show evolution history
#   claude-os-evolve fitness                   — Show fitness metrics

set -uo pipefail

STATE_DIR="${CLAUDE_OS_STATE:-/var/lib/claude-os}"
GENOME="$STATE_DIR/genome/manifest.json"
EVOLUTION_LOG="$STATE_DIR/evolution/log.json"
USER_PACKAGES="$STATE_DIR/state/user-packages.nix"
MUTATION_DIR="$STATE_DIR/evolution/pending"

export PATH="/run/current-system/sw/bin:$PATH"

mkdir -p "$MUTATION_DIR" "$STATE_DIR/evolution/history"

# --- Helpers ---
timestamp() { date -Iseconds; }

log_mutation() {
  local type="$1" description="$2" details="${3:-{}}"
  local gen=$(jq '.generation' "$EVOLUTION_LOG" 2>/dev/null || echo 0)
  local mutation_id="gen${gen}-$(date +%s)-$(head -c4 /dev/urandom | od -An -tx1 | tr -d ' ')"

  # Validate details is valid JSON, fall back to wrapping as string
  if ! echo "$details" | jq . >/dev/null 2>&1; then
    details="{\"raw\":$(echo "$details" | jq -R .)}"
  fi

  # Ensure evolution log exists and is valid
  if [ ! -f "$EVOLUTION_LOG" ] || ! jq . "$EVOLUTION_LOG" >/dev/null 2>&1; then
    echo '{"mutations":[],"generation":0,"born":"'"$(timestamp)"'","version":1}' > "$EVOLUTION_LOG"
  fi

  local tmp=$(mktemp)
  jq --arg id "$mutation_id" --arg type "$type" --arg desc "$description" \
     --arg ts "$(timestamp)" --argjson details "$details" \
    '.mutations += [{"id":$id,"type":$type,"description":$desc,"timestamp":$ts,"details":$details}]' \
    "$EVOLUTION_LOG" > "$tmp" && mv "$tmp" "$EVOLUTION_LOG"

  echo "$mutation_id"
}

update_fitness() {
  local field="$1" increment="${2:-1}"
  local tmp=$(mktemp)
  jq --arg f "$field" --argjson i "$increment" \
    '.fitness[$f] = ((.fitness[$f] // 0) + $i)' \
    "$GENOME" > "$tmp" && mv "$tmp" "$GENOME"
}

# --- Commands ---
case "${1:-help}" in
  add-package)
    pkg="${2:?Usage: claude-os-evolve add-package <package>}"
    echo "Adding package: $pkg"

    # Check if already in genome
    if jq -e --arg p "$pkg" '.packages.user | index($p)' "$GENOME" >/dev/null 2>&1; then
      echo "Package $pkg already in genome"
      exit 0
    fi

    # Add to genome
    tmp=$(mktemp)
    jq --arg p "$pkg" '.packages.user += [$p]' "$GENOME" > "$tmp" && mv "$tmp" "$GENOME"

    # Add to user-packages.nix
    if [ -f "$USER_PACKAGES" ]; then
      # Insert before the closing bracket
      sed -i '/^]$/i\  '"$pkg" "$USER_PACKAGES"
    else
      cat > "$USER_PACKAGES" << EOF
{ pkgs }:
with pkgs; [
  $pkg
]
EOF
    fi

    # Log the mutation
    mid=$(log_mutation "add-package" "Added package: $pkg" "{\"package\":\"$pkg\"}")
    update_fitness "packages_installed"
    echo "Mutation $mid: package $pkg added to genome"
    echo "Run 'claude-os-evolve apply' to rebuild the system"
    ;;

  remove-package)
    pkg="${2:?Usage: claude-os-evolve remove-package <package>}"
    echo "Removing package: $pkg"

    tmp=$(mktemp)
    jq --arg p "$pkg" '.packages.user = [.packages.user[] | select(. != $p)]' \
      "$GENOME" > "$tmp" && mv "$tmp" "$GENOME"

    if [ -f "$USER_PACKAGES" ]; then
      sed -i "/^  $pkg$/d" "$USER_PACKAGES"
    fi

    log_mutation "remove-package" "Removed package: $pkg" "{\"package\":\"$pkg\"}"
    echo "Package $pkg removed from genome"
    ;;

  add-capability)
    cap="${2:?Usage: claude-os-evolve add-capability <capability>}"

    if jq -e --arg c "$cap" '.capabilities | index($c)' "$GENOME" >/dev/null 2>&1; then
      echo "Capability $cap already registered"
      exit 0
    fi

    tmp=$(mktemp)
    jq --arg c "$cap" '.capabilities += [$c]' "$GENOME" > "$tmp" && mv "$tmp" "$GENOME"
    log_mutation "add-capability" "Added capability: $cap" "{\"capability\":\"$cap\"}"
    echo "Capability registered: $cap"
    ;;

  add-skill)
    name="${2:?Usage: claude-os-evolve add-skill <name> <skill-file>}"
    skill_file="${3:?Usage: claude-os-evolve add-skill <name> <skill-file>}"

    if [ ! -f "$skill_file" ]; then
      echo "Error: skill file not found: $skill_file"
      exit 1
    fi

    # Copy skill to skills directory
    cp "$skill_file" "$STATE_DIR/skills/$name.skill.md"

    # Add to genome
    tmp=$(mktemp)
    jq --arg s "$name" \
      'if (.skills | index($s)) then . else .skills += [$s] end' \
      "$GENOME" > "$tmp" && mv "$tmp" "$GENOME"

    log_mutation "add-skill" "Learned skill: $name" "{\"skill\":\"$name\"}"
    update_fitness "skills_learned"
    echo "Skill learned: $name"
    ;;

  add-service)
    name="${2:?Usage: claude-os-evolve add-service <name> <description>}"
    desc="${3:-$name service}"

    tmp=$(mktemp)
    jq --arg s "$name" \
      'if (.services.user | index($s)) then . else .services.user += [$s] end' \
      "$GENOME" > "$tmp" && mv "$tmp" "$GENOME"

    log_mutation "add-service" "Added service: $name — $desc" "{\"service\":\"$name\"}"
    echo "Service registered: $name"
    ;;

  apply)
    echo "Applying evolution — rebuilding system..."

    # Increment generation
    gen=$(jq '.generation' "$EVOLUTION_LOG")
    new_gen=$((gen + 1))
    tmp=$(mktemp)
    jq --argjson g "$new_gen" '.generation = $g' "$EVOLUTION_LOG" > "$tmp" && mv "$tmp" "$EVOLUTION_LOG"
    tmp=$(mktemp)
    jq --argjson g "$new_gen" '.generation = $g' "$GENOME" > "$tmp" && mv "$tmp" "$GENOME"

    # Snapshot current genome to history
    cp "$GENOME" "$STATE_DIR/evolution/history/gen-${new_gen}-$(date +%Y%m%d%H%M%S).json"

    # Rebuild NixOS
    echo "Generation $new_gen — rebuilding NixOS..."
    if sudo nixos-rebuild switch --flake /etc/claude-os#claude-os 2>&1; then
      log_mutation "apply" "System evolved to generation $new_gen" "{\"generation\":$new_gen}"
      echo "Evolution successful! System is now generation $new_gen"
    else
      echo "ERROR: NixOS rebuild failed. Rolling back generation counter."
      tmp=$(mktemp)
      jq --argjson g "$gen" '.generation = $g' "$EVOLUTION_LOG" > "$tmp" && mv "$tmp" "$EVOLUTION_LOG"
      tmp=$(mktemp)
      jq --argjson g "$gen" '.generation = $g' "$GENOME" > "$tmp" && mv "$tmp" "$GENOME"
      log_mutation "apply-failed" "Failed to evolve to generation $new_gen" "{\"generation\":$new_gen}"
      update_fitness "errors_recovered"
      exit 1
    fi
    ;;

  rollback)
    echo "Rolling back to previous NixOS generation..."
    if sudo nixos-rebuild switch --rollback 2>&1; then
      gen=$(jq '.generation' "$EVOLUTION_LOG")
      log_mutation "rollback" "Rolled back from generation $gen" "{\"from_generation\":$gen}"
      echo "Rollback successful"
    else
      echo "ERROR: Rollback failed"
      exit 1
    fi
    ;;

  status)
    if [ ! -f "$GENOME" ]; then
      echo "Genome not initialized yet. Waiting for master agent."
      exit 0
    fi
    echo "=== Claude-OS Genome ==="
    echo "Generation: $(jq '.generation // 0' "$GENOME" 2>/dev/null)"
    echo "Born: $(jq -r '.born // "unknown"' "$GENOME" 2>/dev/null)"
    echo ""
    echo "Packages (base): $(jq '.packages.base | length' "$GENOME" 2>/dev/null)"
    echo "Packages (user): $(jq '.packages.user | length' "$GENOME" 2>/dev/null)"
    user_pkg_count=$(jq '.packages.user | length' "$GENOME" 2>/dev/null || echo 0)
    if [ "${user_pkg_count:-0}" -gt 0 ]; then
      echo "  User packages: $(jq -r '.packages.user | join(", ")' "$GENOME" 2>/dev/null)"
    fi
    echo ""
    echo "Capabilities: $(jq -r '.capabilities | join(", ")' "$GENOME" 2>/dev/null)"
    echo ""
    echo "Skills: $(jq '.skills | length' "$GENOME" 2>/dev/null)"
    skill_count=$(jq '.skills | length' "$GENOME" 2>/dev/null || echo 0)
    if [ "${skill_count:-0}" -gt 0 ]; then
      echo "  $(jq -r '.skills | join(", ")' "$GENOME" 2>/dev/null)"
    fi
    echo ""
    echo "Services (user): $(jq -r '.services.user | join(", ")' "$GENOME" 2>/dev/null || echo none)"
    echo ""
    echo "=== Fitness ==="
    jq '.fitness' "$GENOME" 2>/dev/null
    ;;

  log)
    echo "=== Evolution Log ==="
    echo "Current generation: $(jq '.generation' "$EVOLUTION_LOG" 2>/dev/null || echo 0)"
    echo "Total mutations: $(jq '.mutations | length' "$EVOLUTION_LOG" 2>/dev/null || echo 0)"
    echo ""
    jq -r '.mutations[-10:][] | "\(.timestamp) [\(.type)] \(.description)"' \
      "$EVOLUTION_LOG" 2>/dev/null || echo "No mutations yet"
    ;;

  fitness)
    echo "=== System Fitness ==="
    jq '.fitness' "$GENOME" 2>/dev/null || echo "{}"
    ;;

  help|*)
    echo "claude-os-evolve — System evolution engine"
    echo ""
    echo "Usage:"
    echo "  claude-os-evolve add-package <pkg>         Add a package"
    echo "  claude-os-evolve remove-package <pkg>      Remove a package"
    echo "  claude-os-evolve add-capability <cap>      Register a capability"
    echo "  claude-os-evolve add-skill <name> <file>   Learn a skill"
    echo "  claude-os-evolve add-service <name> <desc> Register a service"
    echo "  claude-os-evolve apply                     Rebuild system (next generation)"
    echo "  claude-os-evolve rollback                  Rollback to previous generation"
    echo "  claude-os-evolve status                    Show genome status"
    echo "  claude-os-evolve log                       Show evolution history"
    echo "  claude-os-evolve fitness                   Show fitness metrics"
    ;;
esac
