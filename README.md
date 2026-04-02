# Claude-OS

**A self-evolving, AI-native operating system built on NixOS.**

Claude-OS is an operating system where AI is not an app you run — it *is* the operating system. On boot, you are greeted by Claude, which has full control over the machine: installing software, managing services, remembering context across sessions, planning complex tasks, and growing its own capabilities with every interaction.

The system starts minimal and evolves. Like a biological organism, it has a **genome** that tracks its packages, capabilities, skills, and fitness. Every task you complete is a **mutation** that makes the system more capable. Every tool it installs gets a **skill file** so it knows how to use it next time. Every fact it learns is stored in a **memory graph** that persists across reboots and decays naturally over time.

---

## Philosophy

Traditional operating systems are static toolboxes. You install software, configure it, and maintain it yourself. Claude-OS inverts this relationship:

**You describe what you want. The OS figures out how to become capable of doing it.**

Need to process video? Claude-OS will search nixpkgs, install ffmpeg, generate a skill file documenting how to use it, register "video-processing" as a new capability in its genome, and then do the actual work. Next time you ask about video, it already knows.

This is not a chatbot bolted onto Linux. The entire system — from package management to service orchestration to memory — is designed around the AI as the primary operator. The master agent runs 24/7, watching the system, healing failures, coordinating multiple user sessions, and evolving the configuration.

### Core Principles

- **Evolve on demand, not speculatively.** The system installs only what it needs, when it needs it. No bloat.
- **Everything is tracked.** Every mutation to the system is logged. Every generation can be rolled back via NixOS.
- **Memory is organic.** Memories decay if unused, strengthen when accessed, and compress when they grow large. The system forgets what doesn't matter and remembers what does.
- **Self-healing by default.** Failed services restart. Disk pressure triggers cleanup. Runaway processes are killed. The system keeps itself alive.
- **Multi-agent coordination.** Multiple users can interact simultaneously. The master agent coordinates, locks resources, and prevents conflicts.

---

## Architecture

```
                        ┌──────────────────────────────────────┐
                        │           Claude-OS (NixOS)          │
                        │                                      │
                        │   ┌──────────────────────────────┐   │
                        │   │     Master Agent (daemon)     │   │
                        │   │  Always-on system orchestrator│   │
                        │   └──────┬───────┬───────┬───────┘   │
                        │          │       │       │           │
                        │   ┌──────▼──┐ ┌──▼───┐ ┌─▼────────┐ │
                        │   │Awareness│ │Memory│ │ Evolution │ │
                        │   │ Engine  │ │Graph │ │  Engine   │ │
                        │   └─────────┘ └──────┘ └──────────┘ │
                        │          │       │       │           │
                        │   ┌──────▼──┐ ┌──▼───┐ ┌─▼────────┐ │
                        │   │ Health  │ │Shell │ │Capability │ │
                        │   │Guardian │ │Agents│ │ Manager   │ │
                        │   └─────────┘ └──────┘ └──────────┘ │
                        │          │                │          │
                        │   ┌──────▼──┐      ┌─────▼────────┐ │
                        │   │  Ollama │      │  Goal Planner│ │
                        │   │  (LLM)  │      │              │ │
                        │   └─────────┘      └──────────────┘ │
                        └──────────────────────────────────────┘
```

### Layers

| Layer | What it does | Key component |
|-------|-------------|---------------|
| **Base OS** | NixOS with systemd, networking, SSH, auto-login | `modules/base/` |
| **Master Agent** | Always-on daemon that orchestrates everything | `claude-os-master.service` |
| **Shell Agents** | User-facing Claude Code sessions (one per login) | `claude-shell` login shell |
| **Evolution Engine** | Genome-based self-mutation with rollback | `claude-os-evolve` |
| **Capability Manager** | 3-tier package acquisition (ephemeral/session/persistent) | `claude-os-cap` |
| **Goal Planner** | Refines user inputs into executable step-by-step plans | `claude-os-plan` |
| **Memory Graph** | SQLite knowledge graph with FTS5, decay, context windows | `claude-os-memory` |
| **Awareness Engine** | Live system sensing every 5 seconds | `claude-os-awareness.service` |
| **Health Guardian** | Self-healing every 30 seconds | `claude-os-health.timer` |
| **Agent Coordinator** | Multi-agent locking, conflict detection, messaging | `claude-os-agents` |
| **Ollama** | On-device LLM inference (CUDA on NVIDIA, CPU fallback) | `ollama.service` |
| **MCP Servers** | Structured tool interfaces for agent-bus and memory-graph | `mcp-servers/` |

---

## The Genome

Every Claude-OS instance has a genome at `/var/lib/claude-os/genome/manifest.json`:

```json
{
  "generation": 3,
  "born": "2025-04-02T12:00:00Z",
  "packages": {
    "base": ["coreutils", "git", "jq", "sqlite", "nodejs_22", "..."],
    "user": ["ffmpeg", "python3", "imagemagick"]
  },
  "capabilities": [
    "shell", "networking", "version-control",
    "video-processing", "image-editing", "python-development"
  ],
  "skills": ["git", "nix", "systemd", "ollama", "ffmpeg", "python"],
  "fitness": {
    "tasks_completed": 47,
    "packages_installed": 12,
    "skills_learned": 8,
    "errors_recovered": 3
  }
}
```

Each mutation (package install, capability registration, skill learning) is logged. Each generation is snapshotted. You can always roll back:

```bash
claude-os-evolve rollback  # NixOS generation rollback
claude-os-evolve log       # See mutation history
```

---

## Memory Graph

The memory system is built on SQLite with FTS5 full-text search and recursive CTEs for graph traversal.

**Schema:**
- `entities` — nodes with type, content, tags, decay score, access count
- `relations` — directed edges with types and weights
- `summaries` — compressed versions of large entities
- `context_windows` — tracks what's loaded per session with token budgets
- `entities_fts` — FTS5 virtual table with porter stemming

**Context management prevents skew over long tasks:**
- **Relevance scoring**: `decay * log(access_count) * recency * connection_density`
- **Token budgeting**: greedy packing of highest-relevance entities into a fixed budget
- **Decay**: unaccessed memories fade (0.95x/day), accessed ones strengthen (+0.1 per access)
- **Summaries**: large entities get compressed versions at multiple levels
- **Focus queries**: bias the context window toward a specific topic

```bash
claude-os-memory remember fact "api-key-location" "API keys are in /home/claude/.env"
claude-os-memory recall "api key"
claude-os-memory neighbors 1 2          # 2-hop graph traversal
claude-os-memory context-load session1  # Load relevant context (4000 token budget)
claude-os-memory decay                  # Run memory decay pass
```

---

## Awareness & Self-Healing

The awareness engine senses the entire system every 5 seconds:

| Signal Source | Frequency | What it detects |
|--------------|-----------|-----------------|
| Resources | 5s | CPU load, memory pressure, disk usage, swap |
| Processes | 5s | Zombies, CPU hogs (>80%), runaway processes |
| Services | 10s | Failed systemd units, service state changes |
| Agents | 10s | Dead agents, resource conflicts, nix contention |
| Journal | 30s | Errors, warnings from system log |
| Network | 30s | Connectivity, DNS resolution |

The health guardian runs every 30 seconds and autonomously:
- Restarts failed critical services (master, awareness, SSH, NetworkManager)
- Drops page caches when memory exceeds 95%
- Runs `nix-collect-garbage` when disk exceeds 90%
- Kills processes using >80% CPU for over 5 minutes
- Reaps zombie processes
- Ensures state directory integrity

```bash
claude-os-sense brief     # CPU: 0.5 | MEM: 12% | DISK: 3% | Agents: 2 | Gen: 3 | Net: UP
claude-os-sense signals   # Recent system events
claude-os-health status   # Health report
claude-os-agents list     # Active shell agents with per-agent CPU/memory
claude-os-agents locks    # Resource locks
```

---

## Getting Started

### Prerequisites

- [Nix](https://install.determinate.systems/nix) package manager (with flakes enabled)
- For VM testing: QEMU or an environment that can run QEMU (e.g., Linux host, OrbStack on Mac)
- An [Anthropic API key](https://console.anthropic.com/) for Claude Code

### Build & Run a VM

```bash
# Clone the repository
git clone https://github.com/anthropics/claude-os.git
cd claude-os

# Build the VM image (aarch64 for arm64, x86_64 for Intel/AMD)
nix build .#packages.aarch64-linux.vm    # ARM64
nix build .#packages.x86_64-linux.vm     # x86_64 (includes NVIDIA/CUDA)

# Run the VM
./result/bin/run-claude-os-vm

# SSH in (from another terminal)
ssh -p 2222 claude@localhost
# Password: claude-os
```

On first login, Claude will prompt you to authenticate with `/login`. Enter your Anthropic API key.

### Build a Bootable ISO

```bash
nix build .#packages.x86_64-linux.iso     # x86_64 ISO
nix build .#packages.aarch64-linux.iso     # ARM64 ISO

# Write to USB
sudo dd if=result/iso/claude-os-*.iso of=/dev/sdX bs=4M status=progress
```

Boot from the USB. Run `claude-os-install` for guided disk partitioning and installation.

### Install on Bare Metal

```bash
# After booting the ISO or from an existing NixOS install:
nixos-install --flake github:anthropics/claude-os#claude-os-bare
```

### Run Inside OrbStack (macOS)

```bash
# Create an Ubuntu VM in OrbStack, then inside it:
curl --proto '=https' --tlsv1.2 -sSf -L https://install.determinate.systems/nix | sh -s -- install --no-confirm
source /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh

git clone https://github.com/anthropics/claude-os.git
cd claude-os
nix build .#packages.aarch64-linux.vm
./result/bin/run-claude-os-vm

# From macOS, SSH in:
ssh -p 2222 claude@ubuntu.orb
```

---

## Usage

Once logged in, you're talking to Claude. It has full control of the OS. Just describe what you want:

```
You: I need to analyze some CSV data with Python

Claude: Let me check what we have...
  > claude-os-evolve status → no python capability
  > claude-os-cap install python3 → adds to genome, generates skill
  > claude-os-cap install python3Packages.pandas → adds pandas
  > claude-os-evolve add-capability data-analysis
  > claude-os-evolve apply → rebuilds system (generation 1!)

Now writing the analysis script...
```

The next time anyone asks about data analysis, the system already has the capability.

### Key Commands

| Command | What it does |
|---------|-------------|
| `claude-os-evolve status` | View the system genome |
| `claude-os-evolve log` | Evolution history |
| `claude-os-evolve rollback` | Undo last system change |
| `claude-os-cap install <pkg>` | Install a package permanently |
| `claude-os-cap use <pkg>` | Try a package without installing |
| `claude-os-cap search <query>` | Search 100K+ nixpkgs packages |
| `claude-os-plan create <goal>` | Plan a complex task |
| `claude-os-memory recall <query>` | Search the knowledge graph |
| `claude-os-memory stats` | Memory graph statistics |
| `claude-os-sense brief` | One-line system dashboard |
| `claude-os-sense signals` | Recent system events |
| `claude-os-health status` | System health report |
| `claude-os-agents list` | Active agents and resource usage |
| `ollama pull <model>` | Download a local LLM |
| `ollama run <model>` | Chat with a local model |

---

## Project Structure

```
claude-os/
├── flake.nix                              # Build system: VM, ISO, bare-metal targets
├── modules/
│   ├── base/                              # NixOS base: boot, networking, users, nix config
│   ├── master-agent/                      # Master daemon + evolution + capabilities + planner
│   │   ├── default.nix                    # systemd service, main orchestration loop
│   │   ├── claude-md-master.nix           # Master agent system prompt
│   │   ├── evolve.sh                      # Evolution engine CLI
│   │   ├── capability-manager.sh          # Package acquisition CLI
│   │   └── goal-planner.sh               # Goal planning CLI
│   ├── shell-agent/                       # Login shell: Claude Code as the user interface
│   │   ├── default.nix                    # Login shell wrapper + Claude Code install
│   │   └── claude-md-shell.nix            # Shell agent system prompt
│   ├── memory/                            # SQLite knowledge graph
│   │   ├── schema.sql                     # Graph schema: entities, relations, FTS5, views
│   │   ├── memory-graph.sh               # Memory CLI with context management
│   │   └── default.nix                    # Init service, decay timer
│   ├── awareness/                         # System nervous system
│   │   ├── awareness-engine.sh            # Signal aggregator daemon
│   │   ├── health-guardian.sh             # Self-healing automation
│   │   ├── agent-coordinator.sh           # Multi-agent coordination + locking
│   │   ├── sense.sh                       # Live system query CLI
│   │   └── default.nix                    # Services and timers
│   ├── gpu/                               # GPU + local inference
│   │   ├── ollama.nix                     # Ollama service + skill file
│   │   └── nvidia.nix                     # NVIDIA/CUDA (conditional, x86_64 only)
│   ├── state/                             # Persistent state directory structure
│   ├── mcp-servers/                       # MCP server NixOS wiring
│   ├── iso/                               # Bootable ISO configuration
│   └── skills/builtins/                   # Pre-built skill files
├── mcp-servers/
│   ├── agent-bus/                         # Inter-agent communication MCP server
│   └── memory-graph/                      # Memory graph MCP server (better-sqlite3)
└── skills/
    └── _template.skill.md                 # Skill file format specification
```

---

## Persistent State

Everything that survives reboots lives under `/var/lib/claude-os/`:

```
/var/lib/claude-os/
├── genome/manifest.json          # System DNA
├── evolution/
│   ├── log.json                  # Every mutation ever
│   └── history/                  # Per-generation genome snapshots
├── memory/
│   ├── graph.sqlite              # Knowledge graph (SQLite + FTS5)
│   └── facts/                    # Markdown fact files
├── skills/                       # Skill files (*.skill.md)
├── awareness/
│   ├── system-status.json        # Latest system snapshot
│   ├── signal-stream.jsonl       # Signal history
│   └── health.json               # Health guardian status
├── agents/
│   ├── registry.json             # Active agent registry
│   ├── inbox/                    # Messages to master
│   ├── outbox/                   # Messages to sub-agents
│   └── locks/                    # Resource locks
├── goals/plans/                  # Structured task plans
└── state/
    ├── user-packages.nix         # Dynamic package list
    └── tool-usage.json           # Usage tracking
```

---

## Build Targets

| Target | Command | Description |
|--------|---------|-------------|
| Dev VM (arm64) | `nix build .#packages.aarch64-linux.vm` | Fast builds on Apple Silicon |
| Prod VM (x86_64) | `nix build .#packages.x86_64-linux.vm` | Full NVIDIA/CUDA support |
| ISO (x86_64) | `nix build .#packages.x86_64-linux.iso` | Bootable installer |
| ISO (arm64) | `nix build .#packages.aarch64-linux.iso` | Bootable installer |
| Bare metal | `nixos-install --flake .#claude-os-bare` | Direct install |

---

## Contributing

Claude-OS is in early development. Key areas for contribution:

- **Skill files**: Write `.skill.md` files for common packages (see `skills/_template.skill.md`)
- **MCP servers**: Add new MCP tools (os-control, awareness queries)
- **Awareness signals**: New signal sources (GPU monitoring, container tracking)
- **Memory improvements**: Better summarization, embedding-based retrieval
- **Testing**: NixOS VM integration tests
- **GPU support**: ROCm for AMD GPUs, Vulkan fallback improvements

---

## License

MIT

---

*Claude-OS is built with [Claude Code](https://claude.ai/code) and [NixOS](https://nixos.org).*
