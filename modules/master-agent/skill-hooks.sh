#!/usr/bin/env bash
# claude-os-skill — Skill injection and refinement
# Pre-use: loads relevant skill into context
# Post-use: captures command patterns and updates skill files
#
# Usage:
#   claude-os-skill lookup <command>        — Find and display skill for a command
#   claude-os-skill inject <command>        — Output skill content (for context injection)
#   claude-os-skill observe <command> <exit_code> [args...]  — Record usage pattern
#   claude-os-skill refine <package>        — Use Ollama to improve a skill file
#   claude-os-skill coverage                — Show which installed packages have skills

set -uo pipefail

STATE_DIR="${CLAUDE_OS_STATE:-/var/lib/claude-os}"
SKILLS_DIR="$STATE_DIR/skills"
USAGE_DIR="$STATE_DIR/skills/usage-log"
OLLAMA_URL="${OLLAMA_URL:-http://127.0.0.1:11434}"
OLLAMA_MODEL="${OLLAMA_MODEL:-gemma4:31b-cloud}"

export PATH="/run/current-system/sw/bin:$PATH"

mkdir -p "$USAGE_DIR"

# Map a command to its package name
command_to_package() {
  local cmd="$1"
  # Try: which -> readlink -> nix-store query
  local bin_path=$(command -v "$cmd" 2>/dev/null)
  if [ -n "$bin_path" ]; then
    local real_path=$(readlink -f "$bin_path" 2>/dev/null || echo "$bin_path")
    if [[ "$real_path" == /nix/store/* ]]; then
      echo "$real_path" | sed 's|/nix/store/[^/]*-||' | sed 's|/.*||' | sed 's|-[0-9].*||'
      return
    fi
  fi
  # Fallback: command name is the package name
  echo "$cmd"
}

case "${1:-help}" in
  lookup)
    cmd="${2:?Usage: claude-os-skill lookup <command>}"
    pkg=$(command_to_package "$cmd")

    # Check for skill file
    if [ -f "$SKILLS_DIR/$pkg.skill.md" ]; then
      echo "Skill found: $pkg"
      cat "$SKILLS_DIR/$pkg.skill.md"
    elif [ -f "$SKILLS_DIR/$cmd.skill.md" ]; then
      echo "Skill found: $cmd"
      cat "$SKILLS_DIR/$cmd.skill.md"
    else
      echo "No skill file for: $cmd (package: $pkg)"
      echo "Generate one: claude-os-cap skill $pkg"
    fi
    ;;

  inject)
    cmd="${2:?Usage: claude-os-skill inject <command>}"
    pkg=$(command_to_package "$cmd")

    # Output skill content silently (for context injection)
    for name in "$pkg" "$cmd"; do
      if [ -f "$SKILLS_DIR/$name.skill.md" ]; then
        cat "$SKILLS_DIR/$name.skill.md"
        exit 0
      fi
    done
    # No skill — output nothing
    ;;

  observe)
    cmd="${2:?Usage: claude-os-skill observe <command> <exit_code> [args...]}"
    exit_code="${3:-0}"
    shift 3 2>/dev/null || true
    args="$*"
    pkg=$(command_to_package "$cmd")

    # Log the usage
    jq -n \
      --arg cmd "$cmd" \
      --arg pkg "$pkg" \
      --argjson exit_code "$exit_code" \
      --arg args "$args" \
      --arg ts "$(date -Iseconds)" \
      '{command: $cmd, package: $pkg, exit_code: $exit_code, args: $args, timestamp: $ts}' \
      >> "$USAGE_DIR/$pkg.jsonl" 2>/dev/null

    # If command succeeded and we have a skill file, check if this pattern is new
    if [ "$exit_code" -eq 0 ] && [ -n "$args" ] && [ -f "$SKILLS_DIR/$pkg.skill.md" ]; then
      full_cmd="$cmd $args"
      # Check if this exact pattern is already in the skill
      if ! grep -qF "$full_cmd" "$SKILLS_DIR/$pkg.skill.md" 2>/dev/null; then
        # Append as an observed pattern
        echo "" >> "$SKILLS_DIR/$pkg.skill.md"
        echo "### Observed: $(date +%Y-%m-%d)" >> "$SKILLS_DIR/$pkg.skill.md"
        echo '```bash' >> "$SKILLS_DIR/$pkg.skill.md"
        echo "$full_cmd" >> "$SKILLS_DIR/$pkg.skill.md"
        echo '```' >> "$SKILLS_DIR/$pkg.skill.md"
      fi
    fi
    ;;

  refine)
    pkg="${2:?Usage: claude-os-skill refine <package>}"
    skill_file="$SKILLS_DIR/$pkg.skill.md"

    if [ ! -f "$skill_file" ]; then
      echo "No skill file for: $pkg"
      exit 1
    fi

    # Check for usage log
    usage_file="$USAGE_DIR/$pkg.jsonl"
    usage_summary=""
    if [ -f "$usage_file" ]; then
      total=$(wc -l < "$usage_file" | tr -d ' ')
      successes=$(grep '"exit_code":0' "$usage_file" | wc -l | tr -d ' ')
      recent_cmds=$(tail -10 "$usage_file" | jq -r '"\(.command) \(.args)"' 2>/dev/null | sort -u)
      usage_summary="Total uses: $total, successes: $successes
Recent commands:
$recent_cmds"
    fi

    if ! curl -sf "$OLLAMA_URL/api/version" >/dev/null 2>&1; then
      echo "Ollama not available. Cannot refine skill."
      exit 1
    fi

    current_skill=$(cat "$skill_file")

    prompt="You are improving a skill file for the '$pkg' tool on Claude-OS.
A skill file is like a manpage but written for an AI assistant.

Current skill file:
---
$current_skill
---

Usage data:
$usage_summary

Rewrite the skill file to be more useful. Keep the YAML frontmatter.
Add any common tasks that are missing based on the usage data.
Remove the 'Observed' sections and integrate those patterns properly.
Be concise and practical. Output ONLY the improved skill file content."

    echo "Refining skill for $pkg via Ollama..."
    response=$(curl -sf --max-time 120 "$OLLAMA_URL/api/chat" -d "$(jq -n \
      --arg model "$OLLAMA_MODEL" \
      --arg prompt "$prompt" \
      '{model: $model, messages: [{role: "user", content: $prompt}], stream: false}'
    )" | jq -r '.message.content // ""' 2>/dev/null)

    if [ -n "$response" ] && [ ${#response} -gt 100 ]; then
      # Backup old skill
      cp "$skill_file" "$skill_file.bak"
      echo "$response" > "$skill_file"
      echo "Skill refined: $skill_file"
      echo "Backup saved: $skill_file.bak"
    else
      echo "Refinement failed or response too short. Keeping original."
    fi
    ;;

  coverage)
    echo "=== Skill Coverage ==="
    # Check base packages
    base_pkgs=$(jq -r '.packages.base[]' "$STATE_DIR/genome/manifest.json" 2>/dev/null)
    user_pkgs=$(jq -r '.packages.user[]' "$STATE_DIR/genome/manifest.json" 2>/dev/null)

    has_skill=0
    no_skill=0

    for pkg in $base_pkgs $user_pkgs; do
      [ -z "$pkg" ] && continue
      if [ -f "$SKILLS_DIR/$pkg.skill.md" ]; then
        echo "  [+] $pkg"
        has_skill=$((has_skill + 1))
      else
        echo "  [-] $pkg (no skill)"
        no_skill=$((no_skill + 1))
      fi
    done

    total=$((has_skill + no_skill))
    echo ""
    echo "Coverage: $has_skill/$total packages have skills ($(( has_skill * 100 / (total > 0 ? total : 1) ))%)"
    ;;

  help|*)
    echo "claude-os-skill — Skill injection and refinement"
    echo ""
    echo "  lookup <command>              Find skill for a command"
    echo "  inject <command>              Output skill (for context injection)"
    echo "  observe <cmd> <code> [args]   Record a usage pattern"
    echo "  refine <package>              Improve skill via Ollama"
    echo "  coverage                      Show skill coverage"
    ;;
esac
