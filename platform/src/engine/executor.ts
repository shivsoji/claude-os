import { execSync } from "child_process";
import * as fs from "fs";
import * as path from "path";
import { query, queryOne, exec as dbExec, genId } from "../db/index.ts";

const STATE_DIR = process.env.CLAUDE_OS_STATE || "/var/lib/claude-os";
const OLLAMA_URL = process.env.OLLAMA_URL || "http://127.0.0.1:11434";

interface AgentConfig {
  system_prompt: string;
  model_provider: string;
  model_id: string;
  model_fallback: string;
  tools: any[];
  skills: string[];
  packages: string[];
  env_vars: Record<string, string>;
  max_turns: number;
  max_tokens: number;
}

interface ToolCall {
  name: string;
  input: Record<string, any>;
}

// Event emitter for SSE
type EventCallback = (event: any) => void;
const sessionListeners = new Map<string, Set<EventCallback>>();

export function subscribeSession(sessionId: string, cb: EventCallback) {
  if (!sessionListeners.has(sessionId)) sessionListeners.set(sessionId, new Set());
  sessionListeners.get(sessionId)!.add(cb);
  return () => sessionListeners.get(sessionId)?.delete(cb);
}

async function emitEvent(sessionId: string, event: any) {
  // Store in Supabase
  await dbExec(
    "INSERT INTO events (id,session_id,type,role,content) VALUES ($1,$2,$3,$4,$5)",
    [event.id, sessionId, event.type, event.role, JSON.stringify(event)]
  );

  // Notify in-process listeners
  sessionListeners.get(sessionId)?.forEach((cb) => cb(event));
}

// Load skill content for injection
function loadSkills(skills: string[]): string {
  return skills
    .map((s) => {
      const p = path.join(STATE_DIR, "skills", `${s}.skill.md`);
      return fs.existsSync(p) ? fs.readFileSync(p, "utf-8") : "";
    })
    .filter(Boolean)
    .join("\n\n---\n\n");
}

// Build system prompt with skills and system context
function buildSystemPrompt(agent: AgentConfig): string {
  const parts = [agent.system_prompt];

  // Inject skills
  const skillContent = loadSkills(agent.skills);
  if (skillContent) {
    parts.push(`\n\n## Available Skills\n\n${skillContent}`);
  }

  // Inject system context
  const statusFile = path.join(STATE_DIR, "awareness", "system-status.json");
  if (fs.existsSync(statusFile)) {
    try {
      const status = JSON.parse(fs.readFileSync(statusFile, "utf-8"));
      parts.push(`\n\n## System Status\nCPU: ${status.resources?.cpu?.load_1m ?? "?"} | MEM: ${status.resources?.memory?.used_pct ?? "?"}% | Gen: ${status.genome?.generation ?? 0}`);
    } catch {}
  }

  return parts.join("\n");
}

// Execute a tool call (bash, read, etc.)
function executeTool(tool: ToolCall, sessionId: string): string {
  const allowed = ["bash", "read", "write", "glob", "grep"];
  if (!allowed.includes(tool.name)) {
    return JSON.stringify({ error: `Tool '${tool.name}' not available` });
  }

  try {
    switch (tool.name) {
      case "bash": {
        const cmd = tool.input.command || tool.input.cmd || "";
        const result = execSync(cmd, {
          timeout: 30000,
          maxBuffer: 1024 * 1024,
          encoding: "utf-8",
          env: { ...process.env, CLAUDE_OS_STATE: STATE_DIR },
        });
        return result.slice(0, 10000);
      }
      case "read": {
        const filePath = tool.input.path || tool.input.file_path || "";
        return fs.readFileSync(filePath, "utf-8").slice(0, 10000);
      }
      default:
        return JSON.stringify({ error: `Tool '${tool.name}' not implemented yet` });
    }
  } catch (e: any) {
    return `Error: ${e.message?.slice(0, 500)}`;
  }
}

// Call Ollama HTTP API
async function callOllama(
  model: string,
  messages: Array<{ role: string; content: string }>,
  tools?: any[]
): Promise<{ content: string; tool_calls?: ToolCall[] }> {
  const body: any = { model, messages, stream: false };

  // Ollama supports tool calling for compatible models
  if (tools && tools.length > 0) {
    body.tools = tools.map((t: any) => ({
      type: "function",
      function: {
        name: t.name,
        description: t.description || t.name,
        parameters: t.input_schema || { type: "object", properties: {} },
      },
    }));
  }

  const resp = await fetch(`${OLLAMA_URL}/api/chat`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });

  if (!resp.ok) throw new Error(`Ollama error: ${resp.status}`);
  const data = await resp.json();

  const toolCalls = data.message?.tool_calls?.map((tc: any) => ({
    name: tc.function?.name,
    input: tc.function?.arguments || {},
  }));

  return {
    content: data.message?.content || "",
    tool_calls: toolCalls,
  };
}

// Call Anthropic API directly
async function callClaude(
  model: string,
  systemPrompt: string,
  messages: Array<{ role: string; content: string }>,
  tools?: any[]
): Promise<{ content: string; tool_calls?: ToolCall[] }> {
  const apiKey = process.env.ANTHROPIC_API_KEY;
  if (!apiKey) throw new Error("ANTHROPIC_API_KEY not set");

  const body: any = {
    model,
    max_tokens: 8192,
    system: systemPrompt,
    messages,
  };

  if (tools && tools.length > 0) {
    body.tools = tools.map((t: any) => ({
      name: t.name,
      description: t.description || t.name,
      input_schema: t.input_schema || { type: "object", properties: {} },
    }));
  }

  const resp = await fetch("https://api.anthropic.com/v1/messages", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "x-api-key": apiKey,
      "anthropic-version": "2023-06-01",
    },
    body: JSON.stringify(body),
  });

  if (!resp.ok) throw new Error(`Claude API error: ${resp.status}`);
  const data = await resp.json();

  const content = data.content
    ?.filter((c: any) => c.type === "text")
    .map((c: any) => c.text)
    .join("\n") || "";

  const toolCalls = data.content
    ?.filter((c: any) => c.type === "tool_use")
    .map((c: any) => ({ name: c.name, input: c.input }));

  return { content, tool_calls: toolCalls?.length ? toolCalls : undefined };
}

// Main execution loop for a session message
export async function executeMessage(
  sessionId: string,
  userMessage: string
): Promise<void> {
  const session = await queryOne("SELECT * FROM sessions WHERE id=$1", [sessionId]);
  if (!session) throw new Error("Session not found");
  if (session.status === "archived") throw new Error("Session is archived");

  const agent: AgentConfig = typeof session.agent_snapshot === "string"
    ? JSON.parse(session.agent_snapshot) : session.agent_snapshot;
  const systemPrompt = buildSystemPrompt(agent);

  // Update status
  await dbExec("UPDATE sessions SET status='running' WHERE id=$1", [sessionId]);

  // Emit user message event
    await emitEvent(sessionId, {
    id: genId("evt"),
    type: "message",
    role: "user",
    content: userMessage,
  });

  // Build conversation history from events
  const history = await query("SELECT type,role,content FROM events WHERE session_id=$1 AND type='message' ORDER BY processed_at", [sessionId]);

  const messages = (history || []).map((e: any) => {
    const parsed = typeof e.content === "string" ? JSON.parse(e.content) : e.content;
    return { role: e.role === "agent" ? "assistant" : "user", content: parsed.content || parsed.text || "" };
  });

  // Build tool definitions from agent config
  const toolDefs = JSON.parse(JSON.stringify(agent.tools || [])).filter(
    (t: any) => t.type === "builtin" || t.type === "custom"
  );

  // Execute with tool loop (max turns)
  let turns = 0;
  while (turns < agent.max_turns) {
    turns++;

    let result;
    try {
      if (agent.model_provider === "claude" && process.env.ANTHROPIC_API_KEY) {
        result = await callClaude(agent.model_id, systemPrompt, messages, toolDefs);
        await dbExec("UPDATE sessions SET usage_claude_calls=usage_claude_calls+1 WHERE id=$1", [sessionId]);
      } else {
        // Ollama (default / fallback)
        const ollamaMessages = [{ role: "system", content: systemPrompt }, ...messages];
        result = await callOllama(agent.model_id || "gemma4:31b-cloud", ollamaMessages, toolDefs);
        await dbExec("UPDATE sessions SET usage_ollama_calls=usage_ollama_calls+1 WHERE id=$1", [sessionId]);
      }
    } catch (e: any) {
      // Try fallback
      if (agent.model_fallback === "ollama") {
        const ollamaMessages = [{ role: "system", content: systemPrompt }, ...messages];
        result = await callOllama("gemma4:31b-cloud", ollamaMessages, toolDefs);
        await dbExec("UPDATE sessions SET usage_ollama_calls=usage_ollama_calls+1 WHERE id=$1", [sessionId]);
      } else {
        throw e;
      }
    }

    // Emit agent message
    if (result.content) {
    await emitEvent(sessionId, {
        id: genId("evt"),
        type: "message",
        role: "agent",
        content: result.content,
      });
      messages.push({ role: "assistant", content: result.content });
    }

    // Handle tool calls
    if (result.tool_calls && result.tool_calls.length > 0) {
      for (const tc of result.tool_calls) {
    await emitEvent(sessionId, {
          id: genId("evt"),
          type: "tool_call",
          role: "agent",
          content: JSON.stringify(tc),
        });

        // Execute tool
        const toolResult = executeTool(tc, sessionId);

    await emitEvent(sessionId, {
          id: genId("evt"),
          type: "tool_result",
          role: "system",
          content: toolResult,
        });

        messages.push({ role: "user", content: `Tool result for ${tc.name}: ${toolResult}` });
        await dbExec("UPDATE sessions SET tools_used=tools_used+1 WHERE id=$1", [sessionId]);
      }
      // Continue loop for next agent turn after tool results
      continue;
    }

    // No tool calls — agent is done
    break;
  }

  // Update session stats
  await dbExec("UPDATE sessions SET status='idle', turns=turns+$1 WHERE id=$2", [turns, sessionId]);

    await emitEvent(sessionId, {
    id: genId("evt"),
    type: "status",
    role: "system",
    content: JSON.stringify({ status: "idle", stop_reason: "end_turn" }),
  });
}
