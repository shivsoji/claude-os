#!/usr/bin/env bash
# claude-os-plan — Goal planner
# Structures user goals into executable plans.
# Plans are stored as JSON and can be executed step-by-step.
#
# Usage:
#   claude-os-plan create <goal-description>  — Create a new plan
#   claude-os-plan list                       — List all plans
#   claude-os-plan show <plan-id>             — Show plan details
#   claude-os-plan step <plan-id> <step-num>  — Mark step as complete
#   claude-os-plan complete <plan-id>         — Mark plan as complete
#   claude-os-plan active                     — Show active plans
#   claude-os-plan capabilities <goal>        — List capabilities needed for a goal

set -uo pipefail

STATE_DIR="${CLAUDE_OS_STATE:-/var/lib/claude-os}"
PLANS_DIR="$STATE_DIR/goals/plans"
GENOME="$STATE_DIR/genome/manifest.json"

export PATH="/run/current-system/sw/bin:$PATH"

mkdir -p "$PLANS_DIR"

plan_id() {
  echo "plan-$(date +%s)-$(head -c3 /dev/urandom | od -An -tx1 | tr -d ' ')"
}

case "${1:-help}" in
  create)
    shift
    goal="${*:?Usage: claude-os-plan create <goal description>}"
    id=$(plan_id)

    # Get current capabilities for context
    current_caps=$(jq -r '.capabilities | join(", ")' "$GENOME" 2>/dev/null || echo "basic")
    current_pkgs=$(jq -r '(.packages.base + .packages.user) | join(", ")' "$GENOME" 2>/dev/null || echo "")
    current_skills=$(jq -r '.skills | join(", ")' "$GENOME" 2>/dev/null || echo "none")

    # Use jq to safely generate JSON (prevents injection from goal text)
    jq -n \
      --arg id "$id" \
      --arg goal "$goal" \
      --arg ts "$(date -Iseconds)" \
      --arg caps "$current_caps" \
      --arg pkgs "$current_pkgs" \
      --arg skills "$current_skills" \
      '{
        id: $id,
        goal: $goal,
        status: "pending",
        created: $ts,
        context: {
          capabilities_at_creation: $caps,
          packages_at_creation: $pkgs,
          skills_at_creation: $skills
        },
        analysis: {
          missing_capabilities: [],
          required_packages: [],
          required_skills: [],
          estimated_steps: 0,
          notes: ("Awaiting analysis by Claude. Run: claude-os-plan capabilities " + $goal)
        },
        steps: [],
        outcome: null
      }' > "$PLANS_DIR/$id.json"

    echo "Plan created: $id"
    echo "Goal: $goal"
    echo ""
    echo "Current capabilities: $current_caps"
    echo "Current skills: $current_skills"
    echo ""
    echo "Next: Analyze what's needed with 'claude-os-plan capabilities \"$goal\"'"
    echo "Then add steps and execute them."
    ;;

  capabilities)
    shift
    goal="${*:?Usage: claude-os-plan capabilities <goal>}"
    echo "=== Capability Analysis for Goal ==="
    echo "Goal: $goal"
    echo ""

    # Show what we have
    echo "--- Current System ---"
    echo "Capabilities: $(jq -r '.capabilities | join(", ")' "$GENOME" 2>/dev/null)"
    echo "Packages (base): $(jq -r '.packages.base | join(", ")' "$GENOME" 2>/dev/null)"
    echo "Packages (user): $(jq -r '.packages.user | join(", ")' "$GENOME" 2>/dev/null || echo "none")"
    echo "Skills: $(jq -r '.skills | join(", ")' "$GENOME" 2>/dev/null || echo "none")"
    echo ""

    echo "--- Analysis ---"
    echo "This is a static view. For intelligent analysis, ask Claude:"
    echo "  'What packages and capabilities do I need to: $goal'"
    echo ""
    echo "Claude can then use these commands:"
    echo "  claude-os-cap search <query>    — Find packages"
    echo "  claude-os-cap install <pkg>     — Install a package"
    echo "  claude-os-evolve add-capability — Register new capability"
    echo "  claude-os-evolve apply          — Rebuild system"
    ;;

  list)
    echo "=== All Plans ==="
    for plan in "$PLANS_DIR"/*.json; do
      [ -f "$plan" ] || continue
      echo "$(jq -r '"\(.id) [\(.status)] \(.goal)"' "$plan")"
    done
    if [ ! "$(ls -A "$PLANS_DIR" 2>/dev/null)" ]; then
      echo "No plans yet. Create one: claude-os-plan create <goal>"
    fi
    ;;

  active)
    echo "=== Active Plans ==="
    found=0
    for plan in "$PLANS_DIR"/*.json; do
      [ -f "$plan" ] || continue
      status=$(jq -r '.status' "$plan")
      if [ "$status" = "pending" ] || [ "$status" = "in-progress" ]; then
        found=1
        echo ""
        echo "Plan: $(jq -r '.id' "$plan")"
        echo "Goal: $(jq -r '.goal' "$plan")"
        echo "Status: $status"
        echo "Steps: $(jq '.steps | length' "$plan") total, $(jq '[.steps[] | select(.done == true)] | length' "$plan") done"
      fi
    done
    if [ "$found" -eq 0 ]; then
      echo "No active plans."
    fi
    ;;

  show)
    id="${2:?Usage: claude-os-plan show <plan-id>}"
    plan="$PLANS_DIR/$id.json"
    if [ ! -f "$plan" ]; then
      echo "Plan not found: $id"
      exit 1
    fi
    jq '.' "$plan"
    ;;

  step)
    id="${2:?Usage: claude-os-plan step <plan-id> <step-num>}"
    step_num="${3:?Usage: claude-os-plan step <plan-id> <step-num>}"
    plan="$PLANS_DIR/$id.json"
    if [ ! -f "$plan" ]; then
      echo "Plan not found: $id"
      exit 1
    fi

    tmp=$(mktemp)
    jq --argjson n "$step_num" \
      '.steps[$n].done = true | .steps[$n].completed_at = (now | todate) | .status = "in-progress"' \
      "$plan" > "$tmp" && mv "$tmp" "$plan"

    echo "Step $step_num marked as complete"

    # Check if all steps are done
    total=$(jq '.steps | length' "$plan")
    done=$(jq '[.steps[] | select(.done == true)] | length' "$plan")
    echo "Progress: $done / $total steps"
    ;;

  complete)
    id="${2:?Usage: claude-os-plan complete <plan-id>}"
    plan="$PLANS_DIR/$id.json"
    if [ ! -f "$plan" ]; then
      echo "Plan not found: $id"
      exit 1
    fi

    tmp=$(mktemp)
    jq '.status = "completed" | .completed_at = (now | todate)' "$plan" > "$tmp" && mv "$tmp" "$plan"

    # Update genome fitness
    claude-os-evolve add-capability "goal-completed" 2>/dev/null || true

    goal=$(jq -r '.goal' "$plan")
    echo "Plan $id completed!"
    echo "Goal achieved: $goal"
    ;;

  help|*)
    echo "claude-os-plan — Goal planner"
    echo ""
    echo "Usage:"
    echo "  claude-os-plan create <goal>            Create a new plan"
    echo "  claude-os-plan list                     List all plans"
    echo "  claude-os-plan active                   Show active plans"
    echo "  claude-os-plan show <plan-id>           Show plan details"
    echo "  claude-os-plan step <plan-id> <step>    Mark step complete"
    echo "  claude-os-plan complete <plan-id>       Complete a plan"
    echo "  claude-os-plan capabilities <goal>      Analyze requirements"
    ;;
esac
