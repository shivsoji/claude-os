#!/usr/bin/env bash
# claude-os-compose — Capability composition manager
# Learns which packages are installed together and bundles them.
#
# Usage:
#   claude-os-compose detect              — Scan history for co-install patterns
#   claude-os-compose create <name> <pkg1,pkg2,...> [description]
#   claude-os-compose list                — Show all compositions
#   claude-os-compose show <name>         — Show composition details
#   claude-os-compose install <name>      — Install all packages in a composition
#   claude-os-compose suggest <goal>      — Suggest a composition for a goal (via Ollama)

set -uo pipefail

STATE_DIR="${CLAUDE_OS_STATE:-/var/lib/claude-os}"
COMP_DIR="$STATE_DIR/compositions"
GENOME="$STATE_DIR/genome/manifest.json"
EVOLUTION_LOG="$STATE_DIR/evolution/log.json"
OLLAMA_URL="${OLLAMA_URL:-http://127.0.0.1:11434}"
OLLAMA_MODEL="${OLLAMA_MODEL:-gemma4:31b-cloud}"

export PATH="/run/current-system/sw/bin:$PATH"

mkdir -p "$COMP_DIR"

case "${1:-help}" in
  detect)
    echo "=== Detecting co-install patterns ==="

    # Analyze evolution log for packages installed in the same session window (within 5 min)
    if [ ! -f "$EVOLUTION_LOG" ]; then
      echo "No evolution log yet."
      exit 0
    fi

    # Extract add-package mutations with timestamps
    jq -r '.mutations[] | select(.type == "add-package") | "\(.timestamp)\t\(.details.package // .description)"' \
      "$EVOLUTION_LOG" 2>/dev/null | sort > /tmp/pkg-timeline.txt

    if [ ! -s /tmp/pkg-timeline.txt ]; then
      echo "No package installations recorded yet."
      echo "Install some packages with 'claude-os-cap install <pkg>' to build patterns."
      exit 0
    fi

    # Group packages installed within 5-minute windows
    echo "Package installation timeline:"
    cat /tmp/pkg-timeline.txt | while IFS=$'\t' read -r ts pkg; do
      echo "  $ts: $pkg"
    done

    # Find packages that always appear together in user packages
    user_pkgs=$(jq -r '.packages.user[]' "$GENOME" 2>/dev/null)
    pkg_count=$(echo "$user_pkgs" | grep -c '.' || echo 0)

    if [ "$pkg_count" -ge 2 ]; then
      echo ""
      echo "Current user packages ($pkg_count):"
      echo "$user_pkgs" | sed 's/^/  /'
      echo ""
      echo "Consider bundling related packages into a composition:"
      echo "  claude-os-compose create <name> pkg1,pkg2,pkg3 'description'"
    fi

    rm -f /tmp/pkg-timeline.txt
    ;;

  create)
    name="${2:?Usage: claude-os-compose create <name> <pkg1,pkg2,...> [description]}"
    packages="${3:?Missing packages (comma-separated)}"
    description="${4:-Composition: $name}"

    # Create composition file
    jq -n \
      --arg name "$name" \
      --arg desc "$description" \
      --arg pkgs "$packages" \
      --arg ts "$(date -Iseconds)" \
      '{
        name: $name,
        description: $desc,
        packages: ($pkgs | split(",")),
        created: $ts,
        use_count: 0,
        last_used: null,
        learned_from: []
      }' > "$COMP_DIR/$name.json"

    echo "Composition created: $name"
    echo "  Packages: $packages"
    echo "  Install with: claude-os-compose install $name"
    ;;

  list)
    echo "=== Capability Compositions ==="
    found=0
    for comp in "$COMP_DIR"/*.json; do
      [ -f "$comp" ] || continue
      found=1
      jq -r '"\(.name) (\(.packages | length) packages, used \(.use_count) times): \(.description)"' "$comp" 2>/dev/null
    done
    [ "$found" -eq 0 ] && echo "  No compositions yet. Create one or run 'detect' to find patterns."
    ;;

  show)
    name="${2:?Usage: claude-os-compose show <name>}"
    comp="$COMP_DIR/$name.json"
    [ -f "$comp" ] || { echo "Composition not found: $name"; exit 1; }
    jq '.' "$comp"
    ;;

  install)
    name="${2:?Usage: claude-os-compose install <name>}"
    comp="$COMP_DIR/$name.json"
    [ -f "$comp" ] || { echo "Composition not found: $name"; exit 1; }

    echo "Installing composition: $name"
    jq -r '.packages[]' "$comp" | while read -r pkg; do
      echo "  Installing: $pkg"
      claude-os-cap install "$pkg" 2>&1 | tail -1
    done

    # Update use count
    tmp=$(mktemp)
    jq '.use_count += 1 | .last_used = (now | todate)' "$comp" > "$tmp" && mv "$tmp" "$comp"

    # Register as capability
    claude-os-evolve add-capability "$name" 2>/dev/null || true

    echo ""
    echo "Composition '$name' installed. Run 'claude-os-evolve apply' to make persistent."
    ;;

  suggest)
    shift
    goal="${*:?Usage: claude-os-compose suggest <goal description>}"

    # Check if Ollama is available
    if ! curl -sf "$OLLAMA_URL/api/version" >/dev/null 2>&1; then
      echo "Ollama not available. Cannot suggest compositions."
      exit 1
    fi

    # Get current capabilities for context
    current_caps=$(jq -r '.capabilities | join(", ")' "$GENOME" 2>/dev/null || echo "basic")
    current_pkgs=$(jq -r '(.packages.base + .packages.user) | join(", ")' "$GENOME" 2>/dev/null || echo "")
    existing_comps=$(ls "$COMP_DIR"/*.json 2>/dev/null | while read -r f; do jq -r '.name' "$f"; done | tr '\n' ', ')

    prompt="You are Claude-OS. A user wants to: $goal

Current capabilities: $current_caps
Current packages: $current_pkgs
Existing compositions: ${existing_comps:-none}

Suggest a composition of nixpkgs packages that would fulfill this goal.
Respond with ONLY valid JSON:
{\"name\": \"composition-name\", \"packages\": [\"pkg1\", \"pkg2\"], \"description\": \"what this enables\"}"

    echo "Analyzing goal with Ollama..."
    response=$(curl -sf --max-time 60 "$OLLAMA_URL/api/chat" -d "$(jq -n \
      --arg model "$OLLAMA_MODEL" \
      --arg prompt "$prompt" \
      '{model: $model, messages: [{role: "user", content: $prompt}], stream: false}'
    )" | jq -r '.message.content // ""' 2>/dev/null)

    if [ -z "$response" ]; then
      echo "No response from Ollama."
      exit 1
    fi

    # Try to parse the JSON response
    comp_name=$(echo "$response" | jq -r '.name // empty' 2>/dev/null)
    if [ -n "$comp_name" ]; then
      echo ""
      echo "Suggested composition:"
      echo "$response" | jq '.' 2>/dev/null || echo "$response"
      echo ""
      echo "To create: claude-os-compose create $comp_name $(echo "$response" | jq -r '.packages | join(",")' 2>/dev/null) \"$(echo "$response" | jq -r '.description' 2>/dev/null)\""
    else
      echo ""
      echo "Suggestion:"
      echo "$response"
    fi
    ;;

  help|*)
    echo "claude-os-compose — Capability compositions"
    echo ""
    echo "  detect               Scan history for co-install patterns"
    echo "  create <name> <pkgs> Create a composition (pkgs comma-separated)"
    echo "  list                 List all compositions"
    echo "  show <name>          Show composition details"
    echo "  install <name>       Install all packages in a composition"
    echo "  suggest <goal>       Ask Ollama to suggest packages for a goal"
    ;;
esac
