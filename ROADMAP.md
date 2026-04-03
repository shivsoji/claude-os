# Claude-OS Roadmap

## Milestone 1: Core Stabilization

Get the foundation rock-solid for daily use.

| # | Issue | Priority | Status |
|---|-------|----------|--------|
| 1 | [Stabilize first-boot experience and API key setup](https://github.com/shivsoji/claude-os/issues/1) | High | Open |
| 2 | [Fix evolution engine mutation logging](https://github.com/shivsoji/claude-os/issues/2) | High | Open |
| 3 | [Implement NixOS rebuild integration for persistent evolution](https://github.com/shivsoji/claude-os/issues/3) | High | Open |
| 16 | [NixOS integration tests](https://github.com/shivsoji/claude-os/issues/16) | High | Open |

**Goal**: A user can boot Claude-OS, authenticate, install packages that persist across reboots, and have a reliable first-run experience.

---

## Milestone 2: Intelligence Layer

Make the system genuinely smart — not just scripted.

| # | Issue | Priority | Status |
|---|-------|----------|--------|
| 4 | [Auto-summarization of memories using Ollama](https://github.com/shivsoji/claude-os/issues/4) | Medium | Open |
| 5 | [Embedding-based semantic search for memory graph](https://github.com/shivsoji/claude-os/issues/5) | Medium | Open |
| 6 | [Master agent as persistent Claude session](https://github.com/shivsoji/claude-os/issues/6) | High | Open |
| 7 | [Skill auto-refinement from observed usage](https://github.com/shivsoji/claude-os/issues/7) | Medium | Open |

**Goal**: The system learns from its own usage, summarizes knowledge intelligently, and the master agent can reason about system state rather than just react to thresholds.

---

## Milestone 3: Multi-Agent & Networking

Multiple users, distributed systems, visual monitoring.

| # | Issue | Priority | Status |
|---|-------|----------|--------|
| 8 | [Agent-to-agent context sharing and task handoff](https://github.com/shivsoji/claude-os/issues/8) | Medium | Open |
| 9 | [Remote agent spawning and distributed Claude-OS](https://github.com/shivsoji/claude-os/issues/9) | Low | Open |
| 10 | [Web UI dashboard for system monitoring](https://github.com/shivsoji/claude-os/issues/10) | Medium | Open |

**Goal**: Multiple concurrent users can work without conflicts, tasks can span machines, and there's a visual way to understand system state.

---

## Milestone 4: Hardware & Platform

Run everywhere — from Raspberry Pi to GPU clusters.

| # | Issue | Priority | Status |
|---|-------|----------|--------|
| 11 | [AMD ROCm GPU support](https://github.com/shivsoji/claude-os/issues/11) | Medium | Open |
| 12 | [Raspberry Pi / ARM SBC support](https://github.com/shivsoji/claude-os/issues/12) | Low | Open |
| 13 | [Container image output (Docker/OCI)](https://github.com/shivsoji/claude-os/issues/13) | Medium | Open |

**Goal**: Claude-OS runs on any hardware — NVIDIA, AMD, ARM, x86 — and can be deployed as a VM, ISO, container, or bare-metal install.

---

## Milestone 5: Ecosystem

From a single OS to a community platform.

| # | Issue | Priority | Status |
|---|-------|----------|--------|
| 14 | [Skill file marketplace / community skills](https://github.com/shivsoji/claude-os/issues/14) | Low | Open |
| 15 | [Genome sharing and instance cloning](https://github.com/shivsoji/claude-os/issues/15) | Low | Open |

**Goal**: Users can share their evolved genomes and skill files, bootstrapping new instances with community knowledge.

---

## What's Already Built

| Component | Status | Description |
|-----------|--------|-------------|
| Base OS (NixOS) | **Done** | Boot, networking, SSH, auto-login, dual-arch |
| Master Agent | **Done** | systemd daemon, orchestration loop, agent registry |
| Shell Agent | **Done** | Claude Code as login shell, MCP integration |
| Evolution Engine | **Done** | Genome, mutations, generations, rollback |
| Capability Manager | **Done** | 3-tier acquisition, skill generation, usage tracking |
| Goal Planner | **Done** | Goal → plan → steps → completion |
| Memory Graph | **Done** | SQLite + FTS5, decay, context windows, graph traversal |
| Awareness Engine | **Done** | 6 signal sources, 5s sensing, unified snapshot |
| Health Guardian | **Done** | Self-healing every 30s, auto-restart, disk cleanup |
| Agent Coordinator | **Done** | Locking, conflict detection, messaging, broadcast |
| Ollama Integration | **Done** | Local LLM, CUDA on x86_64, skill file |
| ISO Generation | **Done** | Bootable installer for x86_64 and aarch64 |
| MCP Servers | **Done** | Agent-bus and memory-graph |

---

## Contributing

Pick an issue, fork the repo, and submit a PR. Skill files (`.skill.md`) are the easiest way to contribute — no Nix knowledge needed. See `skills/_template.skill.md` for the format.

For architecture discussions, open a GitHub Discussion or comment on the relevant issue.
