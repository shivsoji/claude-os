# Claude-OS Architecture Decisions

Solutions to the critical gaps identified in the v0.1.0 red team review.

---

## 1. Offline-First: Ollama as the Default Brain

**Problem:** The OS is a brick without an Anthropic API key.

**Solution:** Two-tier intelligence model. Ollama handles everything it can locally. Claude API is called only when local models can't handle the task.

### Design

```
User prompt
    │
    ▼
┌─────────────────────┐
│   Router (shell)    │
│                     │
│  Complexity check:  │
│  - Simple command?  │──▶ Execute directly (no LLM needed)
│  - Routine task?    │──▶ Ollama (local, free, instant)
│  - Complex reason?  │──▶ Claude API (cloud, paid, powerful)
│  - No API key?      │──▶ Ollama (always available fallback)
│  - Offline?         │──▶ Ollama (works without internet)
└─────────────────────┘
```

### Routing Rules

| Task Type | Route | Examples |
|-----------|-------|---------|
| Direct commands | No LLM | `ls`, `git status`, `systemctl restart` |
| Simple questions | Ollama (phi3/llama3.2) | "What port is nginx on?", "How do I tar a directory?" |
| Memory operations | Ollama + embeddings | Summarization, semantic search, context compression |
| File generation | Ollama (codellama) | Simple scripts, configs, skill files |
| Complex reasoning | Claude API | Multi-step debugging, architecture decisions, novel problems |
| System evolution | Claude API | Planning what to install, analyzing capability gaps |
| Master agent routine | Ollama | Signal analysis, health decisions, agent coordination |
| Master agent complex | Claude API | Goal planning, cross-agent reasoning |

### Implementation

```bash
# claude-os-route — decides where to send a prompt
# Called by shell-agent before invoking Claude

estimate_complexity() {
  local prompt="$1"
  local word_count=$(echo "$prompt" | wc -w)
  local has_code=$(echo "$prompt" | grep -cE 'debug|architect|design|plan|refactor|migrate')
  local has_multi_step=$(echo "$prompt" | grep -cE 'and then|after that|step.*step|first.*then')

  # Score 0-10: 0=trivial, 10=complex
  local score=0
  [ "$word_count" -gt 50 ] && score=$((score + 2))
  [ "$word_count" -gt 200 ] && score=$((score + 2))
  [ "$has_code" -gt 0 ] && score=$((score + 3))
  [ "$has_multi_step" -gt 0 ] && score=$((score + 2))
  echo "$score"
}

route_prompt() {
  local prompt="$1"
  local complexity=$(estimate_complexity "$prompt")
  local has_api_key=$([ -n "${ANTHROPIC_API_KEY:-}" ] && echo "true" || echo "false")
  local is_online=$(ping -c1 -W1 1.1.1.1 >/dev/null 2>&1 && echo "true" || echo "false")

  if [ "$complexity" -le 3 ] || [ "$has_api_key" = "false" ] || [ "$is_online" = "false" ]; then
    echo "ollama"
  else
    echo "claude"
  fi
}
```

### Boot Sequence Change

```
Boot → systemd
  → Ollama starts (no internet needed)
  → Master agent starts with Ollama backend (immediate)
  → Pull default model if not cached (gemma4:31b-cloud, ~19GB, one-time)
  → Shell agent starts
    → If ANTHROPIC_API_KEY set: Claude Code as shell
    → If no key: Ollama-powered shell (simpler but functional)
  → System is fully operational, online or offline
```

### What Changes

- `claude-os-bootstrap` pulls `gemma4:31b-cloud` + `nomic-embed-text` on first boot (if online)
- Shell agent checks for API key. If missing, launches an Ollama-backed interactive mode
- Master agent uses Ollama for routine decisions (signal analysis, health)
- Master agent escalates to Claude API for complex tasks (if key available)
- Memory summarization uses Ollama (always local)
- Embedding generation uses Ollama `nomic-embed-text` (always local)

---

## 2. The Master Agent Must Actually Think

**Problem:** The master is a bash poll loop, not an intelligent agent.

**Solution:** The master runs two loops — a fast bash loop for mechanical tasks, and a slow Ollama/Claude loop for reasoning.

### Design

```
Master Agent (two loops)
│
├── Fast Loop (bash, every 5s) ──────────────────────
│   ├── Process inbox messages (mechanical)
│   ├── Update agent registry (mechanical)
│   ├── Gather system metrics (mechanical)
│   └── Emit signals (mechanical)
│
└── Think Loop (Ollama/Claude, every 60s) ──────────
    ├── Read pending signals
    ├── Analyze: "What needs attention?"
    ├── Decide: "What should I do about it?"
    ├── Act: Execute decisions
    └── Reflect: "What did I learn?"
```

### Think Loop Implementation

The think loop sends a structured prompt to Ollama (or Claude for complex situations):

```
You are the master agent of Claude-OS. Here is your current situation:

## System Status
{system-status.json contents}

## Pending Signals (last 60s)
{recent signals from signal-stream.jsonl}

## Active Agents
{registry.json contents}

## Active Goals
{goals/active/*.json}

## Recent Evolution
{last 5 mutations from evolution log}

Based on this, respond with a JSON action plan:
{
  "analysis": "what I observe",
  "actions": [
    {"type": "heal", "target": "service-name", "reason": "why"},
    {"type": "evolve", "command": "claude-os-evolve ...", "reason": "why"},
    {"type": "message", "agent": "shell-123", "content": "context to share"},
    {"type": "remember", "fact": "something learned", "type": "system_fact"},
    {"type": "none", "reason": "everything is fine"}
  ]
}
```

The bash loop parses the JSON response and executes each action.

### Cost Control

- Ollama calls are free (local). Use for 90% of think cycles.
- Claude API calls are budgeted. Track `api_calls_today` in genome fitness.
- Configurable: `CLAUDE_OS_API_BUDGET=100` (max API calls per day)
- Think loop interval adjustable: idle system → every 5 min, active → every 30s

---

## 3. Security: Sandbox-Execute-Review Model

**Problem:** Claude has unrestricted sudo. Any prompt injection = full compromise.

**Solution:** Three-tier execution model with review gates.

### Tiers

```
Tier 1: Safe (auto-execute)
  - Read-only operations (ls, cat, ps, systemctl status)
  - Ephemeral nix shell (sandboxed, no system change)
  - Memory operations (remember, recall)
  - Awareness queries (sense, health status)

Tier 2: Reversible (execute + log)
  - Package installation (tracked in genome, rollback-capable)
  - Service start/stop (systemd handles recovery)
  - File creation in /home/claude or /var/lib/claude-os
  - Skill file generation

Tier 3: Irreversible (require confirmation)
  - nixos-rebuild switch (system mutation)
  - File deletion outside state directory
  - Network-facing service exposure
  - Credential/key operations
  - Package removal
```

### Implementation

```bash
# claude-os-exec — wraps dangerous operations with review gates

exec_tier1() {
  # Auto-execute, just log
  echo "[tier1] $*" >> /var/lib/claude-os/audit.log
  "$@"
}

exec_tier2() {
  # Execute + snapshot for rollback
  echo "[tier2] $*" >> /var/lib/claude-os/audit.log
  claude-os-evolve snapshot-pre "$*"
  "$@"
}

exec_tier3() {
  # Require explicit confirmation
  echo "[tier3] REVIEW REQUIRED: $*" >> /var/lib/claude-os/audit.log

  # If running as master agent in autonomous mode:
  if [ "${CLAUDE_OS_AUTONOMOUS:-false}" = "true" ]; then
    # Queue for next human session
    echo "{\"action\":\"$*\",\"reason\":\"$REASON\",\"ts\":\"$(date -Iseconds)\"}" \
      > /var/lib/claude-os/review-queue/$(date +%s).json
    echo "QUEUED: Action requires human review. Added to review queue."
    return 1
  fi

  # If running as shell agent (human present):
  echo "⚠ This action is irreversible:"
  echo "  $*"
  echo ""
  read -p "Execute? [y/N] " confirm
  [ "$confirm" = "y" ] && "$@" || echo "Cancelled."
}
```

### Audit Trail

Every operation logged to `/var/lib/claude-os/audit.log`:
```
[2026-04-03T10:00:00] [tier1] [shell-1234] ls /etc
[2026-04-03T10:00:05] [tier2] [shell-1234] claude-os-cap install ffmpeg
[2026-04-03T10:00:30] [tier3] [shell-1234] QUEUED: nixos-rebuild switch
[2026-04-03T10:01:00] [tier3] [master] QUEUED: rm -rf /var/lib/old-data
```

### Review Queue

When the master agent wants to do something irreversible but no human is present, it queues the action. Next time a shell agent starts, Claude presents the queue:

```
Welcome back. The master agent has 2 actions pending review:

1. [2h ago] Install docker and enable service
   Reason: Goal "set up container environment" requires it
   
2. [1h ago] Run nixos-rebuild switch (generation 4)
   Reason: 3 new packages accumulated since last rebuild

Approve all? [y/n/review each]
```

---

## 4. Task-Aware Context, Not Generic Relevance

**Problem:** Context loading is generic. Long tasks lose state.

**Solution:** Task context objects that track operational state, not just facts.

### Design

Every active task gets a context object:

```json
{
  "task_id": "debug-segfault-442",
  "started": "2026-04-03T10:00:00Z",
  "goal": "Fix segfault in module X",
  "state": "investigating",
  "tried": [
    {"action": "Added -g flag to compiler", "result": "Still crashes", "ts": "..."},
    {"action": "Ran valgrind", "result": "Use-after-free in line 42", "ts": "..."}
  ],
  "next_steps": ["Fix the free() call in module X line 42", "Run tests"],
  "relevant_files": ["/src/module_x.c:42", "/tests/test_module_x.c"],
  "relevant_memories": [12, 45, 67],
  "scratch_pad": "The UAF happens because buffer is freed in cleanup() but accessed in process(). Need to add ref counting or reorder."
}
```

### How It Works

1. **Task detection:** When Claude starts working on something non-trivial, it creates a task context via `claude-os-plan create`
2. **State capture:** After each significant action, Claude updates the task context with what it tried and what happened
3. **Session survival:** If the session ends mid-task, the task context persists. On next login, Claude sees: "You have an active task: Fix segfault in module X. Last state: found UAF via valgrind, next step: fix free() in line 42."
4. **Context loading:** Instead of loading generic memories, load the task context + its linked memories. Much more relevant, much fewer wasted tokens.
5. **Completion:** When the task is done, compress the task context into a memory entity and link it to relevant skills/facts.

### Context Budget Allocation

```
Session context budget: 8000 tokens
├── Active task context:     3000 tokens (highest priority)
├── Task-relevant memories:  2000 tokens (linked entities)
├── System status:            500 tokens (brief snapshot)
├── Recent events:            500 tokens (signals since last session)
└── General memories:        2000 tokens (relevance-scored backfill)
```

---

## 5. From Package Manager to Capability Composer

**Problem:** "Evolution" is just `apt install` with JSON.

**Solution:** Capabilities are compositions, not packages. The system learns patterns and creates reusable environments.

### Capability Compositions

```json
{
  "name": "python-data-science",
  "packages": ["python3", "python3Packages.pandas", "python3Packages.numpy", "python3Packages.matplotlib", "python3Packages.jupyter"],
  "services": [],
  "env_vars": {"JUPYTER_CONFIG_DIR": "/var/lib/claude-os/jupyter"},
  "post_install": "pip install scikit-learn",
  "learned_from": ["task-analyze-csv-123", "task-plot-data-456"],
  "use_count": 7,
  "last_used": "2026-04-03"
}
```

### Auto-Composition

The master agent (in its think loop) observes patterns:

```
Think loop observation:
- User installed python3 (3 sessions ago)
- Then installed pandas (same session)
- Then installed matplotlib (next session)
- Then installed jupyter (next session)

Decision: Create composite capability "python-data-science" containing
all 4 packages. Next time user mentions data analysis, install the
whole stack at once.
```

### Capability Inference

When a user says "I need to analyze some data," instead of asking "which packages?", the system:

1. Checks existing capabilities: do we have "data-analysis"? No.
2. Checks Ollama: "What packages are typically needed for data analysis?" → python, pandas, numpy, matplotlib
3. Checks history: has user done this before? → Yes, they used python+pandas last time
4. Proposes: "I'll set up python-data-science (python3, pandas, numpy, matplotlib, jupyter). This matches what you used last time plus jupyter for interactive work."
5. User confirms → installs as a composition, not 5 separate packages

---

## 6. Proper Multi-Agent Coordination

**Problem:** File-based message bus breaks under concurrency.

**Solution:** Use `flock` for locking, Unix domain sockets for messaging, and heartbeats for liveness.

### Locking with flock

```bash
# Atomic lock with timeout and heartbeat
acquire_lock() {
  local resource="$1"
  local timeout="${2:-30}"
  local lockfile="/var/lib/claude-os/agents/locks/${resource}.lock"

  exec 200>"$lockfile"
  if flock -w "$timeout" 200; then
    # Write holder info
    echo "{\"pid\":$$,\"acquired\":\"$(date -Iseconds)\"}" > "$lockfile.info"
    return 0
  else
    return 1
  fi
}

release_lock() {
  local resource="$1"
  local lockfile="/var/lib/claude-os/agents/locks/${resource}.lock"
  flock -u 200
  rm -f "$lockfile.info"
}
```

### Agent Heartbeats

Each agent writes a heartbeat every 10 seconds:

```bash
# Background heartbeat in shell-agent
(while true; do
  echo "{\"pid\":$$,\"ts\":\"$(date -Iseconds)\",\"load\":$(ps -o %cpu= -p $$)}" \
    > "/var/lib/claude-os/agents/heartbeats/$$.json"
  sleep 10
done) &
```

Master agent checks heartbeats. If an agent misses 3 heartbeats (30s), it's declared dead and its locks are released.

### Message Passing via Unix Sockets

Replace file-based inbox with `socat` Unix domain sockets:

```bash
# Master listens
socat UNIX-LISTEN:/run/claude-os/master.sock,fork EXEC:/usr/bin/claude-os-master-handler

# Agent sends
echo '{"type":"goal","goal":"install docker"}' | socat - UNIX:/run/claude-os/master.sock
```

This is atomic, ordered, and doesn't have the directory-scanning race conditions of the current approach.

---

## 7. Skill Consumption, Not Just Generation

**Problem:** Skills are generated but never read by Claude.

**Solution:** Skills are injected into context when the relevant tool is invoked.

### Skill Injection Hook

When Claude is about to use a tool, the system checks for a skill file and prepends it:

```bash
# In the shell-agent wrapper, intercept tool usage
pre_command_hook() {
  local cmd="$1"
  local pkg=$(command -v "$cmd" | xargs readlink -f | xargs nix-store --query --deriver 2>/dev/null | sed 's/.*-//' | sed 's/-.*//')

  if [ -f "/var/lib/claude-os/skills/${pkg}.skill.md" ]; then
    # Inject skill into Claude's context via a system message
    cat "/var/lib/claude-os/skills/${pkg}.skill.md" > /tmp/current-skill.md
    echo "Skill loaded for: $pkg"
  fi
}
```

### Skill Refinement Loop

After Claude uses a tool:
1. Capture what commands were run and their exit codes
2. Compare against the skill file's "Common tasks" section
3. If a new pattern emerged, append it to the skill
4. If a documented pattern failed, annotate the skill with the failure

This makes skills a living document that improves with use, not a static `--help` dump.

---

## 8. Honest Identity: AI-Augmented OS, Not AI OS

**Problem:** The marketing overpromises. It's a chatbot with sudo, not a new OS paradigm.

**Solution:** Reframe around what it actually is and what it's becoming.

### What Claude-OS Actually Is (v0.1)

> A NixOS distribution preconfigured for AI-first system administration. Claude Code is your shell. The system tracks what tools you install, remembers what you've done, and heals itself when things break. Think of it as NixOS + an AI sysadmin that never sleeps.

### What Claude-OS Is Becoming (v1.0)

> An operating system where the AI is a first-class system component, not an application. The master agent makes autonomous decisions about system health, resource allocation, and capability management. The system genuinely evolves — learning from usage patterns, composing capabilities, and optimizing its own configuration. It works offline via local models and escalates to cloud AI only for complex reasoning.

### The Gap Between v0.1 and v1.0

| Capability | v0.1 (current) | v1.0 (target) |
|-----------|-----------------|----------------|
| Intelligence | Claude API (cloud-dependent) | Ollama local + Claude API escalation |
| Master agent | Bash poll loop | AI think loop with decision-making |
| Evolution | JSON logging of manual actions | Pattern detection, auto-composition |
| Security | Trust everything | Tiered execution with review gates |
| Context | Generic relevance scoring | Task-aware state management |
| Skills | Generated, never read | Injected on use, refined from observation |
| Multi-agent | File-based, racy | flock + sockets + heartbeats |
| Offline | Broken | Fully functional |

---

## Implementation Priority

### Phase A: Make It Real (next)
1. **Ollama as default brain** — master agent thinks via Ollama, shell falls back
2. **Master agent think loop** — actual AI decisions every 60s
3. **Task context objects** — operational state survives sessions
4. **Tier-based execution** — audit log + review queue for dangerous ops

### Phase B: Make It Smart
5. **Capability compositions** — learn package groups from patterns
6. **Skill injection + refinement** — skills consumed, not just stored
7. **Intelligent decay** — importance from relationships, not just access
8. **Embedding search** — Ollama nomic-embed-text for semantic recall

### Phase C: Make It Solid
9. **flock + sockets** — proper concurrency
10. **Agent heartbeats** — reliable liveness detection
11. **Config sandbox** — test nixos-rebuild in VM before applying
12. **Complexity router** — smart dispatch between Ollama and Claude API
