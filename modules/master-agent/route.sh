#!/usr/bin/env bash
# claude-os-route — Complexity router: decides Ollama vs Claude API
#
# Usage:
#   claude-os-route query "prompt text"    — Route a query, return answer
#   claude-os-route check "prompt text"    — Just report which backend
#   claude-os-route ollama "prompt text"   — Force Ollama
#   claude-os-route claude "prompt text"   — Force Claude API
#   claude-os-route status                 — Show routing config

set -uo pipefail

STATE_DIR="${CLAUDE_OS_STATE:-/var/lib/claude-os}"
OLLAMA_URL="${OLLAMA_URL:-http://127.0.0.1:11434}"
OLLAMA_MODEL="${OLLAMA_MODEL:-phi3:mini}"
API_BUDGET_FILE="$STATE_DIR/state/api-budget.json"

export PATH="/run/current-system/sw/bin:$PATH"

# Initialize daily API budget tracker
init_budget() {
  if [ ! -f "$API_BUDGET_FILE" ]; then
    echo '{"date":"'"$(date +%Y-%m-%d)"'","calls":0,"limit":100}' > "$API_BUDGET_FILE"
  fi
  # Reset if new day
  local tracked_date=$(jq -r '.date' "$API_BUDGET_FILE" 2>/dev/null)
  if [ "$tracked_date" != "$(date +%Y-%m-%d)" ]; then
    jq --arg d "$(date +%Y-%m-%d)" '.date = $d | .calls = 0' "$API_BUDGET_FILE" > "$API_BUDGET_FILE.tmp" \
      && mv "$API_BUDGET_FILE.tmp" "$API_BUDGET_FILE"
  fi
}

check_api_budget() {
  init_budget
  local calls=$(jq '.calls' "$API_BUDGET_FILE" 2>/dev/null || echo 0)
  local limit=$(jq '.limit' "$API_BUDGET_FILE" 2>/dev/null || echo 100)
  [ "$calls" -lt "$limit" ]
}

increment_api_calls() {
  init_budget
  jq '.calls += 1' "$API_BUDGET_FILE" > "$API_BUDGET_FILE.tmp" \
    && mv "$API_BUDGET_FILE.tmp" "$API_BUDGET_FILE"
}

# Score complexity 0-10
score_complexity() {
  local prompt="$1"
  local score=0
  local word_count=$(echo "$prompt" | wc -w | tr -d ' ')

  # Length signals
  [ "$word_count" -gt 50 ] && score=$((score + 1))
  [ "$word_count" -gt 150 ] && score=$((score + 1))
  [ "$word_count" -gt 300 ] && score=$((score + 2))

  # Complexity keywords
  echo "$prompt" | grep -qiE 'debug|architect|design|refactor|migrate|security|optimize' && score=$((score + 2))
  echo "$prompt" | grep -qiE 'and then|after that|step.by.step|first.*then|multi.step' && score=$((score + 1))
  echo "$prompt" | grep -qiE 'explain why|trade.off|compare|pros and cons|best approach' && score=$((score + 1))
  echo "$prompt" | grep -qiE 'across.*files|entire.*codebase|all.*modules|system.wide' && score=$((score + 1))

  # Cap at 10
  [ "$score" -gt 10 ] && score=10
  echo "$score"
}

# Check if Ollama is available
ollama_available() {
  curl -sf "$OLLAMA_URL/api/version" >/dev/null 2>&1
}

# Check if Claude API is available
claude_available() {
  [ -n "${ANTHROPIC_API_KEY:-}" ] && curl -sf --max-time 3 https://api.anthropic.com >/dev/null 2>&1
}

# Route decision
decide_route() {
  local prompt="$1"
  local complexity=$(score_complexity "$prompt")
  local has_key=$([ -n "${ANTHROPIC_API_KEY:-}" ] && echo "true" || echo "false")
  local is_online=$(curl -sf --max-time 2 https://api.anthropic.com >/dev/null 2>&1 && echo "true" || echo "false")
  local ollama_up=$(ollama_available && echo "true" || echo "false")
  local within_budget=$(check_api_budget && echo "true" || echo "false")

  # Decision tree
  if [ "$ollama_up" = "false" ] && [ "$has_key" = "true" ] && [ "$is_online" = "true" ]; then
    echo "claude"  # Ollama down, use Claude
  elif [ "$complexity" -le 4 ]; then
    echo "ollama"  # Simple enough for local model
  elif [ "$has_key" = "false" ] || [ "$is_online" = "false" ]; then
    echo "ollama"  # No choice, offline or no key
  elif [ "$within_budget" = "false" ]; then
    echo "ollama"  # Over API budget
  elif [ "$complexity" -ge 7 ]; then
    echo "claude"  # Complex, use the best model
  else
    echo "ollama"  # Default to local
  fi
}

# Call Ollama API
call_ollama() {
  local prompt="$1"
  local system_prompt="${2:-You are a helpful AI assistant running locally on Claude-OS via Ollama. Be concise and practical.}"

  curl -sf "$OLLAMA_URL/api/chat" -d "$(jq -n \
    --arg model "$OLLAMA_MODEL" \
    --arg sys "$system_prompt" \
    --arg user "$prompt" \
    '{model: $model, messages: [{role: "system", content: $sys}, {role: "user", content: $user}], stream: false}'
  )" | jq -r '.message.content // "Error: no response from Ollama"'
}

# Generate embeddings via Ollama
generate_embedding() {
  local text="$1"
  curl -sf "$OLLAMA_URL/api/embed" -d "$(jq -n \
    --arg model "nomic-embed-text" \
    --arg input "$text" \
    '{model: $model, input: $input}'
  )"
}

case "${1:-help}" in
  query)
    shift
    prompt="${*:?Usage: claude-os-route query <prompt>}"
    route=$(decide_route "$prompt")

    if [ "$route" = "ollama" ]; then
      if ollama_available; then
        call_ollama "$prompt"
      else
        echo "Error: Ollama not available and no Claude API key set."
        exit 1
      fi
    else
      increment_api_calls
      # For Claude API, delegate to the claude CLI
      echo "$prompt" | claude --dangerously-skip-permissions --print 2>/dev/null || \
        call_ollama "$prompt"  # Fallback to Ollama if Claude fails
    fi
    ;;

  check)
    shift
    prompt="${*:?Usage: claude-os-route check <prompt>}"
    complexity=$(score_complexity "$prompt")
    route=$(decide_route "$prompt")
    echo "Complexity: $complexity/10"
    echo "Route: $route"
    echo "Ollama: $(ollama_available && echo 'available' || echo 'unavailable')"
    echo "Claude API: $([ -n "${ANTHROPIC_API_KEY:-}" ] && echo 'key set' || echo 'no key')"
    echo "API budget: $(jq -r '"\(.calls)/\(.limit) calls today"' "$API_BUDGET_FILE" 2>/dev/null || echo 'no tracking')"
    ;;

  ollama)
    shift
    prompt="${*:?Usage: claude-os-route ollama <prompt>}"
    call_ollama "$prompt"
    ;;

  claude)
    shift
    prompt="${*:?Usage: claude-os-route claude <prompt>}"
    increment_api_calls
    echo "$prompt" | claude --dangerously-skip-permissions --print 2>/dev/null || echo "Claude API unavailable"
    ;;

  embed)
    shift
    text="${*:?Usage: claude-os-route embed <text>}"
    generate_embedding "$text"
    ;;

  status)
    echo "=== Routing Status ==="
    echo "Ollama: $(ollama_available && echo 'UP' || echo 'DOWN') ($OLLAMA_URL, model: $OLLAMA_MODEL)"
    echo "Claude API: $([ -n "${ANTHROPIC_API_KEY:-}" ] && echo 'key configured' || echo 'NO KEY')"
    echo "Online: $(curl -sf --max-time 2 https://api.anthropic.com >/dev/null 2>&1 && echo 'yes' || echo 'no')"
    init_budget
    echo "API budget: $(jq -r '"\(.calls)/\(.limit) calls today"' "$API_BUDGET_FILE" 2>/dev/null)"
    echo ""
    echo "Routing rules:"
    echo "  complexity <= 4  → Ollama (local)"
    echo "  complexity >= 7  → Claude API (if available + budget)"
    echo "  no API key       → Ollama (always)"
    echo "  offline           → Ollama (always)"
    echo "  over budget       → Ollama (fallback)"
    ;;

  help|*)
    echo "claude-os-route — Complexity router"
    echo ""
    echo "  query <prompt>   Route and get answer"
    echo "  check <prompt>   Show which backend would be used"
    echo "  ollama <prompt>  Force local Ollama"
    echo "  claude <prompt>  Force Claude API"
    echo "  embed <text>     Generate embedding via Ollama"
    echo "  status           Show routing config"
    ;;
esac
