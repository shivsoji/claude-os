#!/usr/bin/env node

import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";
import * as fs from "fs";
import * as path from "path";

const STATE_DIR = process.env.CLAUDE_OS_STATE || "/var/lib/claude-os";
const AGENTS_DIR = path.join(STATE_DIR, "agents");
const INBOX = path.join(AGENTS_DIR, "inbox");
const OUTBOX = path.join(AGENTS_DIR, "outbox");
const REGISTRY = path.join(AGENTS_DIR, "registry.json");

// Ensure directories exist
for (const dir of [AGENTS_DIR, INBOX, OUTBOX]) {
  fs.mkdirSync(dir, { recursive: true });
}

interface Agent {
  type: string;
  pid: number;
  user: string;
  started: string;
  status: string;
}

interface Registry {
  agents: Agent[];
  version: number;
}

function readRegistry(): Registry {
  try {
    return JSON.parse(fs.readFileSync(REGISTRY, "utf-8"));
  } catch {
    return { agents: [], version: 1 };
  }
}

function writeRegistry(registry: Registry): void {
  fs.writeFileSync(REGISTRY, JSON.stringify(registry, null, 2));
}

function generateMessageId(): string {
  return `${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
}

const server = new McpServer({
  name: "claude-os-agent-bus",
  version: "0.1.0",
});

// Tool: Send a message to the master agent
server.tool(
  "send_to_master",
  "Send a message to the master agent for processing",
  {
    type: z.string().describe("Message type (e.g., capability-request, memory-update, health-alert)"),
    payload: z.string().describe("JSON payload for the message"),
    from_pid: z.number().optional().describe("PID of the sending agent"),
  },
  async ({ type, payload, from_pid }) => {
    const msgId = generateMessageId();
    const message = {
      id: msgId,
      type,
      from_pid: from_pid || process.pid,
      timestamp: new Date().toISOString(),
      ...JSON.parse(payload),
    };

    const msgPath = path.join(INBOX, `${msgId}.json`);
    fs.writeFileSync(msgPath, JSON.stringify(message, null, 2));

    return {
      content: [
        {
          type: "text" as const,
          text: `Message sent to master agent: ${msgId} (type: ${type})`,
        },
      ],
    };
  }
);

// Tool: Send a message to a specific sub-agent
server.tool(
  "send_to_agent",
  "Send a message to a specific sub-agent via its outbox",
  {
    agent_id: z.string().describe("Agent identifier (e.g., shell-1234)"),
    type: z.string().describe("Message type"),
    payload: z.string().describe("JSON payload"),
  },
  async ({ agent_id, type, payload }) => {
    const agentOutbox = path.join(OUTBOX, agent_id);
    fs.mkdirSync(agentOutbox, { recursive: true });

    const msgId = generateMessageId();
    const message = {
      id: msgId,
      type,
      from: "master",
      timestamp: new Date().toISOString(),
      ...JSON.parse(payload),
    };

    const msgPath = path.join(agentOutbox, `${msgId}.json`);
    fs.writeFileSync(msgPath, JSON.stringify(message, null, 2));

    return {
      content: [
        {
          type: "text" as const,
          text: `Message sent to agent ${agent_id}: ${msgId}`,
        },
      ],
    };
  }
);

// Tool: List all active agents
server.tool(
  "list_agents",
  "List all currently registered agents and their status",
  {},
  async () => {
    const registry = readRegistry();

    // Check which agents are still alive (by PID)
    const liveAgents = registry.agents.filter((agent) => {
      try {
        process.kill(agent.pid, 0); // Signal 0 = check if process exists
        return true;
      } catch {
        return false;
      }
    });

    // Update registry if dead agents were found
    if (liveAgents.length !== registry.agents.length) {
      registry.agents = liveAgents;
      writeRegistry(registry);
    }

    const summary = liveAgents.map(
      (a) => `- ${a.type} (PID ${a.pid}) user=${a.user} since ${a.started} [${a.status}]`
    );

    return {
      content: [
        {
          type: "text" as const,
          text:
            liveAgents.length > 0
              ? `Active agents (${liveAgents.length}):\n${summary.join("\n")}`
              : "No active agents registered.",
        },
      ],
    };
  }
);

// Tool: Read messages from an agent's outbox
server.tool(
  "read_messages",
  "Read pending messages for a specific agent from its outbox",
  {
    agent_id: z.string().describe("Agent identifier (e.g., shell-1234)"),
  },
  async ({ agent_id }) => {
    const agentOutbox = path.join(OUTBOX, agent_id);

    if (!fs.existsSync(agentOutbox)) {
      return {
        content: [{ type: "text" as const, text: "No outbox found for this agent." }],
      };
    }

    const files = fs.readdirSync(agentOutbox).filter((f) => f.endsWith(".json"));
    if (files.length === 0) {
      return {
        content: [{ type: "text" as const, text: "No pending messages." }],
      };
    }

    const messages = files.map((f) => {
      const content = fs.readFileSync(path.join(agentOutbox, f), "utf-8");
      // Remove after reading
      fs.unlinkSync(path.join(agentOutbox, f));
      return JSON.parse(content);
    });

    return {
      content: [
        {
          type: "text" as const,
          text: JSON.stringify(messages, null, 2),
        },
      ],
    };
  }
);

// Tool: Get system status from awareness layer
server.tool(
  "system_status",
  "Get current system status from the awareness layer",
  {},
  async () => {
    const statusPath = path.join(STATE_DIR, "awareness", "system-status.json");

    if (!fs.existsSync(statusPath)) {
      return {
        content: [{ type: "text" as const, text: "No system status available yet." }],
      };
    }

    const status = fs.readFileSync(statusPath, "utf-8");
    return {
      content: [{ type: "text" as const, text: status }],
    };
  }
);

// Tool: Register a new agent
server.tool(
  "register_agent",
  "Register a new sub-agent in the agent registry",
  {
    type: z.string().describe("Agent type (shell, cron, watch, task)"),
    pid: z.number().describe("Process ID of the agent"),
    user: z.string().optional().describe("User who owns this agent"),
  },
  async ({ type, pid, user }) => {
    const registry = readRegistry();
    const agent: Agent = {
      type,
      pid,
      user: user || "claude",
      started: new Date().toISOString(),
      status: "active",
    };

    registry.agents.push(agent);
    writeRegistry(registry);

    // Create outbox
    fs.mkdirSync(path.join(OUTBOX, `${type}-${pid}`), { recursive: true });

    return {
      content: [
        {
          type: "text" as const,
          text: `Agent registered: ${type}-${pid}`,
        },
      ],
    };
  }
);

// Start the server
async function main() {
  const transport = new StdioServerTransport();
  await server.connect(transport);
}

main().catch(console.error);
