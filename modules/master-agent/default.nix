{ config, pkgs, lib, ... }:

let
  claudeMdMaster = import ./claude-md-master.nix { inherit config pkgs lib; };

  # The evolution engine CLI — called by Claude to mutate the system
  evolutionEngine = pkgs.writeShellScriptBin "claude-os-evolve" (builtins.readFile ./evolve.sh);

  # The capability manager CLI — called by Claude to acquire tools
  capabilityManager = pkgs.writeShellScriptBin "claude-os-cap" (builtins.readFile ./capability-manager.sh);

  # The goal planner CLI — structures goals into plans
  goalPlanner = pkgs.writeShellScriptBin "claude-os-plan" (builtins.readFile ./goal-planner.sh);

  # Complexity router — Ollama vs Claude API dispatch
  complexityRouter = pkgs.writeShellScriptBin "claude-os-route" (builtins.readFile ./route.sh);

  # Tiered execution with audit trail
  tieredExec = pkgs.writeShellScriptBin "claude-os-exec" (builtins.readFile ./exec.sh);

  # Master agent launcher — starts Claude as a persistent daemon
  masterAgent = pkgs.writeShellScriptBin "claude-os-master" ''
    set -uo pipefail

    STATE_DIR="/var/lib/claude-os"
    MASTER_DIR="$STATE_DIR/agents/master"
    GENOME_DIR="$STATE_DIR/genome"
    LOG="/var/log/claude-os-master.log"

    export PATH="/home/claude/.npm-global/bin:${pkgs.jq}/bin:${pkgs.nodejs_22}/bin:${pkgs.git}/bin:/run/current-system/sw/bin:$PATH"
    export NPM_CONFIG_PREFIX="/home/claude/.npm-global"
    export HOME="/home/claude"
    export CLAUDE_OS_STATE="$STATE_DIR"

    log() {
      echo "[$(date -Iseconds)] [master] $*" | tee -a "$LOG"
    }

    # --- Initialize master state ---
    mkdir -p "$MASTER_DIR" "$GENOME_DIR" "$STATE_DIR/agents/inbox" \
             "$STATE_DIR/agents/outbox" "$STATE_DIR/evolution" \
             "$STATE_DIR/goals" "$STATE_DIR/awareness" \
             "$STATE_DIR/skills" "$STATE_DIR/events"

    echo $$ > "$MASTER_DIR/pid"

    # Initialize agent registry
    if [ ! -f "$STATE_DIR/agents/registry.json" ]; then
      echo '{"agents":[],"version":1}' > "$STATE_DIR/agents/registry.json"
    fi

    # Initialize evolution log
    if [ ! -f "$STATE_DIR/evolution/log.json" ]; then
      echo '{"mutations":[],"generation":0,"born":"'"$(date -Iseconds)"'","version":1}' \
        > "$STATE_DIR/evolution/log.json"
    fi

    # Initialize genome (the system's current capability manifest)
    if [ ! -f "$GENOME_DIR/manifest.json" ]; then
      ${pkgs.jq}/bin/jq -n \
        --arg born "$(date -Iseconds)" \
        '{version:1,generation:0,born:$born,packages:{base:["coreutils","curl","wget","git","jq","sqlite","htop","tmux","ripgrep","fd","nodejs_22","vim","socat","inotify-tools"],user:[]},services:{base:["sshd","networkmanager","claude-os-master","claude-os-bootstrap"],user:[]},skills:[],capabilities:["shell","networking","ssh","file-management","version-control","text-editing","json-processing"],fitness:{tasks_completed:0,packages_installed:0,skills_learned:0,errors_recovered:0,uptime_hours:0}}' \
        > "$GENOME_DIR/manifest.json"
    fi

    # --- Write the master CLAUDE.md ---
    cat > "$MASTER_DIR/CLAUDE.md" << 'CLAUDE_MD'
${claudeMdMaster}
CLAUDE_MD

    # --- System context snapshot ---
    gather_context() {
      cat > "$STATE_DIR/awareness/system-status.json" << CTXEOF
{
  "timestamp": "$(date -Iseconds)",
  "uptime": "$(uptime -p 2>/dev/null || uptime)",
  "load": "$(cat /proc/loadavg 2>/dev/null || echo unknown)",
  "memory": {
    "total_kb": $(grep MemTotal /proc/meminfo 2>/dev/null | awk '{print $2}' || echo 0),
    "available_kb": $(grep MemAvailable /proc/meminfo 2>/dev/null | awk '{print $2}' || echo 0)
  },
  "disk_usage": "$(df -h / 2>/dev/null | tail -1 | awk '{print $5}')",
  "active_agents": $(${pkgs.jq}/bin/jq '.agents | length' "$STATE_DIR/agents/registry.json" 2>/dev/null || echo 0),
  "generation": $(${pkgs.jq}/bin/jq '.generation' "$STATE_DIR/evolution/log.json" 2>/dev/null || echo 0),
  "capabilities": $(${pkgs.jq}/bin/jq '.capabilities | length' "$GENOME_DIR/manifest.json" 2>/dev/null || echo 0),
  "skills_count": $(${pkgs.jq}/bin/jq '.skills | length' "$GENOME_DIR/manifest.json" 2>/dev/null || echo 0)
}
CTXEOF
    }

    # --- Process inbox ---
    process_inbox() {
      for msg_file in "$STATE_DIR/agents/inbox"/*.json; do
        [ -f "$msg_file" ] || continue

        local msg_type=$(${pkgs.jq}/bin/jq -r '.type // "unknown"' "$msg_file" 2>/dev/null)
        log "Processing: $msg_type ($(basename "$msg_file"))"

        case "$msg_type" in
          shell-login)
            local pid=$(${pkgs.jq}/bin/jq -r '.pid' "$msg_file")
            local user=$(${pkgs.jq}/bin/jq -r '.user' "$msg_file")
            # Register agent
            local tmp=$(mktemp)
            ${pkgs.jq}/bin/jq --arg pid "$pid" --arg user "$user" --arg ts "$(date -Iseconds)" \
              '.agents += [{"type":"shell","pid":($pid|tonumber),"user":$user,"started":$ts,"status":"active"}]' \
              "$STATE_DIR/agents/registry.json" > "$tmp" && mv "$tmp" "$STATE_DIR/agents/registry.json"
            mkdir -p "$STATE_DIR/agents/outbox/shell-$pid"
            log "Shell agent registered: pid=$pid user=$user"
            ;;
          shell-logout)
            local pid=$(${pkgs.jq}/bin/jq -r '.pid' "$msg_file")
            local tmp=$(mktemp)
            ${pkgs.jq}/bin/jq --arg pid "$pid" \
              '.agents = [.agents[] | select(.pid != ($pid|tonumber))]' \
              "$STATE_DIR/agents/registry.json" > "$tmp" && mv "$tmp" "$STATE_DIR/agents/registry.json"
            rm -rf "$STATE_DIR/agents/outbox/shell-$pid"
            log "Shell agent deregistered: pid=$pid"
            ;;
          goal)
            # A user has set a goal — queue it for the planner
            cp "$msg_file" "$STATE_DIR/goals/$(basename "$msg_file")"
            log "Goal queued: $(${pkgs.jq}/bin/jq -r '.description // .goal // "unknown"' "$msg_file")"
            ;;
          evolve)
            # Trigger evolution — the Claude session will handle this
            log "Evolution trigger received"
            ;;
        esac

        mv "$msg_file" "$STATE_DIR/events/$(basename "$msg_file")" 2>/dev/null || rm "$msg_file"
      done
    }

    # --- Health monitoring ---
    check_health() {
      local failed=$(systemctl --failed --no-legend 2>/dev/null | wc -l)
      if [ "$failed" -gt 0 ]; then
        log "WARNING: $failed failed services"
        systemctl --failed --no-legend >> "$LOG" 2>/dev/null
      fi
      gather_context
    }

    # --- Main orchestration loop ---
    log "Master agent starting (generation $(${pkgs.jq}/bin/jq '.generation' "$STATE_DIR/evolution/log.json" 2>/dev/null || echo 0))"
    gather_context

    CYCLE=0
    while true; do
      CYCLE=$((CYCLE + 1))

      process_inbox

      # Health check every 6 cycles (30s)
      if [ $((CYCLE % 6)) -eq 0 ]; then
        check_health
      fi

      # Process queued goals every 4 cycles (20s)
      if [ $((CYCLE % 4)) -eq 0 ]; then
        for goal_file in "$STATE_DIR/goals"/*.json; do
          [ -f "$goal_file" ] || continue
          log "Processing goal: $(basename "$goal_file")"
          # Move to active goals — Claude (via shell or future planner) picks these up
          mkdir -p "$STATE_DIR/goals/active"
          mv "$goal_file" "$STATE_DIR/goals/active/" 2>/dev/null || true
        done
      fi

      # Prune dead agents every 12 cycles (60s)
      if [ $((CYCLE % 12)) -eq 0 ]; then
        local tmp=$(mktemp)
        local alive="[]"
        for agent_pid in $(${pkgs.jq}/bin/jq -r '.agents[].pid' "$STATE_DIR/agents/registry.json" 2>/dev/null); do
          if kill -0 "$agent_pid" 2>/dev/null; then
            alive=$(echo "$alive" | ${pkgs.jq}/bin/jq ". + [$agent_pid]")
          fi
        done
        ${pkgs.jq}/bin/jq --argjson alive "$alive" \
          '[.agents[] | select(.pid | IN($alive[]))] as $live | .agents = $live' \
          "$STATE_DIR/agents/registry.json" > "$tmp" 2>/dev/null && mv "$tmp" "$STATE_DIR/agents/registry.json"
      fi

      # === THINK LOOP: AI reasoning every 12 cycles (60s) ===
      if [ $((CYCLE % 12)) -eq 0 ]; then
        OLLAMA_URL="http://127.0.0.1:11434"
        if ${pkgs.curl}/bin/curl -sf "$OLLAMA_URL/api/version" >/dev/null 2>&1; then
          # Gather context for the think prompt
          sys_status=$(cat "$STATE_DIR/awareness/system-status.json" 2>/dev/null || echo '{}')
          recent_signals=$(tail -10 "$STATE_DIR/awareness/signal-stream.jsonl" 2>/dev/null | ${pkgs.jq}/bin/jq -Rs 'split("\n") | map(select(. != "") | fromjson? // {}) | map("\(.ts // "") [\(.severity // "")] \(.source // "")/\(.type // ""): \(.message // "")") | join("\n")' 2>/dev/null || echo "none")
          agent_count=$(${pkgs.jq}/bin/jq '.agents | length' "$STATE_DIR/agents/registry.json" 2>/dev/null || echo 0)
          genome_gen=$(${pkgs.jq}/bin/jq '.generation' "$GENOME_DIR/manifest.json" 2>/dev/null || echo 0)
          pending_goals=$(ls "$STATE_DIR/goals/active/"*.json 2>/dev/null | wc -l || echo 0)
          health_status=$(cat "$STATE_DIR/awareness/health.json" 2>/dev/null || echo '{"healthy":true}')

          think_prompt="You are the master agent of Claude-OS (generation $genome_gen).
Analyze the system state and decide what actions to take.

SYSTEM STATUS:
$(echo "$sys_status" | ${pkgs.jq}/bin/jq -r '"CPU: \(.resources.cpu.load_1m // "?") | MEM: \(.resources.memory.used_pct // "?")% | DISK: \(.resources.disk.root_used_pct // "?")%"' 2>/dev/null || echo "unavailable")

HEALTH: $(echo "$health_status" | ${pkgs.jq}/bin/jq -r 'if .healthy then "OK" else "DEGRADED (failed: \(.failed_services // 0))" end' 2>/dev/null || echo "unknown")

RECENT SIGNALS:
$recent_signals

ACTIVE AGENTS: $agent_count
PENDING GOALS: $pending_goals

Respond with a JSON object:
{\"analysis\": \"brief observation\", \"actions\": [{\"type\": \"none|heal|remember|log\", \"detail\": \"what to do\"}]}
Only suggest actions if something actually needs attention. If everything is fine, respond with type 'none'."

          # Call Ollama
          think_response=$(${pkgs.curl}/bin/curl -sf --max-time 30 "$OLLAMA_URL/api/chat" -d "$(${pkgs.jq}/bin/jq -n \
            --arg prompt "$think_prompt" \
            '{model: "phi3:mini", messages: [{role: "user", content: $prompt}], stream: false}'
          )" | ${pkgs.jq}/bin/jq -r '.message.content // ""' 2>/dev/null)

          if [ -n "$think_response" ]; then
            # Log the thinking
            log "THINK: $(echo "$think_response" | ${pkgs.jq}/bin/jq -r '.analysis // .[:200]' 2>/dev/null || echo "$think_response" | head -c 200)"

            # Try to parse and execute actions
            echo "$think_response" | ${pkgs.jq}/bin/jq -c '.actions[]?' 2>/dev/null | while read -r action; do
              action_type=$(echo "$action" | ${pkgs.jq}/bin/jq -r '.type' 2>/dev/null)
              action_detail=$(echo "$action" | ${pkgs.jq}/bin/jq -r '.detail // .reason // ""' 2>/dev/null)

              case "$action_type" in
                heal)
                  log "THINK-ACT: heal — $action_detail"
                  ;;
                remember)
                  log "THINK-ACT: remember — $action_detail"
                  claude-os-memory remember system_fact "master-observation" "$action_detail" 2>/dev/null || true
                  ;;
                log)
                  log "THINK-ACT: log — $action_detail"
                  ;;
                none)
                  # All good, nothing to do
                  ;;
              esac
            done
          fi
        fi
      fi

      sleep 5
    done
  '';

in
{
  environment.systemPackages = [
    masterAgent
    evolutionEngine
    capabilityManager
    goalPlanner
    complexityRouter
    tieredExec
  ];

  # Master agent systemd service
  systemd.services.claude-os-master = {
    description = "Claude-OS Master Agent";
    wantedBy = [ "multi-user.target" ];
    after = [
      "network-online.target"
      "claude-os-bootstrap.service"
    ];
    wants = [ "network-online.target" ];
    requires = [ "claude-os-bootstrap.service" ];

    serviceConfig = {
      Type = "simple";
      User = "claude";
      Group = "users";
      Restart = "always";
      RestartSec = 5;
      ExecStart = "${masterAgent}/bin/claude-os-master";
      StandardOutput = "journal";
      StandardError = "journal";

      # Allow system modifications for evolution
      ProtectSystem = "no";
    };
  };

  # Write the master agent's CLAUDE.md to state dir
  systemd.services.claude-os-master-config = {
    description = "Generate Master Agent Configuration";
    wantedBy = [ "multi-user.target" ];
    before = [ "claude-os-master.service" ];
    after = [ "claude-os-bootstrap.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      User = "claude";
      Group = "users";
    };
    script = ''
      mkdir -p /var/lib/claude-os/agents/master
      cat > /var/lib/claude-os/agents/master/CLAUDE.md << 'MASTERMD'
${claudeMdMaster}
MASTERMD
    '';
  };
}
