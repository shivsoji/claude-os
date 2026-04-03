#!/usr/bin/env bash
# claude-os-cap — Capability manager
# Handles three tiers of package acquisition:
#   1. ephemeral  — nix shell (one-shot, disappears)
#   2. session    — nix shell kept alive for the session
#   3. persistent — added to genome, system rebuilt
#
# Also generates skill files for newly installed packages.
#
# Usage:
#   claude-os-cap use <pkg> [command...]   — Ephemeral: run command in nix shell
#   claude-os-cap install <pkg>            — Persistent: add to genome + rebuild
#   claude-os-cap search <query>           — Search nixpkgs
#   claude-os-cap has <pkg>                — Check if package is available
#   claude-os-cap list                     — List installed user packages
#   claude-os-cap skill <pkg>              — Generate a skill file for a package

set -uo pipefail

STATE_DIR="${CLAUDE_OS_STATE:-/var/lib/claude-os}"
GENOME="$STATE_DIR/genome/manifest.json"
SKILLS_DIR="$STATE_DIR/skills"
USAGE_FILE="$STATE_DIR/state/tool-usage.json"

export PATH="/run/current-system/sw/bin:$PATH"

mkdir -p "$SKILLS_DIR"

# Track usage for promotion heuristics
track_usage() {
  local pkg="$1"
  if [ ! -f "$USAGE_FILE" ]; then
    echo '{"tools":{},"version":1}' > "$USAGE_FILE"
  fi
  local tmp=$(mktemp)
  jq --arg p "$pkg" \
    '.tools[$p] = ((.tools[$p] // 0) + 1)' \
    "$USAGE_FILE" > "$tmp" && mv "$tmp" "$USAGE_FILE"
}

# Generate a skill file for a package
generate_skill() {
  local pkg="$1"
  local skill_file="$SKILLS_DIR/$pkg.skill.md"

  # Check if a builtin skill exists
  if [ -f "/run/current-system/sw/share/claude-os/skills/$pkg.skill.md" ]; then
    cp "/run/current-system/sw/share/claude-os/skills/$pkg.skill.md" "$skill_file"
    echo "Skill loaded (builtin): $pkg"
    return
  fi

  # Check if we already have a skill
  if [ -f "$skill_file" ]; then
    echo "Skill exists: $pkg"
    return
  fi

  # Auto-generate from --help and man page
  echo "Generating skill for: $pkg"

  local help_text=""
  # Try to get help text
  help_text=$(nix shell "nixpkgs#$pkg" --command "$pkg" --help 2>&1 | head -80 || true)
  if [ -z "$help_text" ]; then
    help_text=$(nix shell "nixpkgs#$pkg" --command "$pkg" -h 2>&1 | head -80 || true)
  fi

  cat > "$skill_file" << SKILL
---
package: $pkg
version: auto-detected
capabilities: [auto-generated]
requires: []
generated: $(date -Iseconds)
---

# $pkg

## What it does
Auto-generated skill file for $pkg. Refine this after using the tool.

## Help output
\`\`\`
${help_text:-No help text available. Run: nix shell nixpkgs#$pkg --command $pkg --help}
\`\`\`

## Notes
- This skill was auto-generated on first install
- Edit this file to add common tasks, gotchas, and usage patterns
- The master agent will refine this skill based on observed usage
SKILL

  # Register in genome
  claude-os-evolve add-skill "$pkg" "$skill_file" 2>/dev/null || true
  echo "Skill generated: $skill_file"
}

case "${1:-help}" in
  use)
    pkg="${2:?Usage: claude-os-cap use <pkg> [command...]}"
    shift 2
    track_usage "$pkg"

    if [ $# -gt 0 ]; then
      # Run specific command
      exec nix shell "nixpkgs#$pkg" --command "$@"
    else
      # Drop into a shell with the package
      echo "Entering ephemeral shell with $pkg..."
      exec nix shell "nixpkgs#$pkg"
    fi
    ;;

  install)
    pkg="${2:?Usage: claude-os-cap install <pkg>}"
    echo "Installing $pkg persistently..."

    # Verify the package exists in nixpkgs
    if ! nix eval "nixpkgs#${pkg}.name" 2>/dev/null >/dev/null; then
      echo "Error: package '$pkg' not found in nixpkgs"
      echo "Try: claude-os-cap search $pkg"
      exit 1
    fi

    # Add to genome
    claude-os-evolve add-package "$pkg"

    # Generate a skill file
    generate_skill "$pkg"

    # Detect capabilities from package name/description
    pkg_desc=$(nix eval --raw "nixpkgs#${pkg}.meta.description" 2>/dev/null || echo "")
    if [ -n "$pkg_desc" ]; then
      echo "Description: $pkg_desc"
      # Simple capability extraction from description keywords
      for kw in "video" "audio" "image" "web" "database" "compiler" "editor" "server" "crypto" "network"; do
        if echo "$pkg_desc" | grep -qi "$kw"; then
          claude-os-evolve add-capability "$kw-processing" 2>/dev/null || true
        fi
      done
    fi

    echo ""
    echo "Package $pkg added to genome."
    echo "To apply immediately: claude-os-evolve apply"
    echo "Or use ephemerally now: claude-os-cap use $pkg"
    ;;

  search)
    query="${2:?Usage: claude-os-cap search <query>}"
    echo "Searching nixpkgs for: $query"
    nix search nixpkgs "$query" 2>/dev/null | head -40
    ;;

  has)
    pkg="${2:?Usage: claude-os-cap has <pkg>}"
    if command -v "$pkg" >/dev/null 2>&1; then
      echo "yes (installed)"
      exit 0
    elif nix eval "nixpkgs#${pkg}.name" 2>/dev/null >/dev/null; then
      echo "available (in nixpkgs, not installed)"
      exit 0
    else
      echo "not found"
      exit 1
    fi
    ;;

  list)
    echo "=== Installed User Packages ==="
    jq -r '.packages.user[]' "$GENOME" 2>/dev/null || echo "None"
    echo ""
    echo "=== Usage Counts ==="
    jq -r '.tools | to_entries | sort_by(-.value) | .[] | "  \(.key): \(.value) uses"' \
      "$USAGE_FILE" 2>/dev/null || echo "  No usage tracked yet"
    ;;

  skill)
    pkg="${2:?Usage: claude-os-cap skill <pkg>}"
    generate_skill "$pkg"
    ;;

  help|*)
    echo "claude-os-cap — Capability manager"
    echo ""
    echo "Usage:"
    echo "  claude-os-cap use <pkg> [cmd...]   Ephemeral: run in nix shell"
    echo "  claude-os-cap install <pkg>        Persistent: add to genome"
    echo "  claude-os-cap search <query>       Search nixpkgs"
    echo "  claude-os-cap has <pkg>            Check availability"
    echo "  claude-os-cap list                 List user packages"
    echo "  claude-os-cap skill <pkg>          Generate skill file"
    ;;
esac
