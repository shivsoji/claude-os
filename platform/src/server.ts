#!/usr/bin/env node
/**
 * Claude-OS Managed Agents Platform
 * System-native agents API on port 8420
 *
 * Endpoints:
 *   POST/GET     /v1/agents           Agent CRUD
 *   POST/GET     /v1/sessions         Session management
 *   POST         /v1/sessions/:id/messages  Send message
 *   GET          /v1/sessions/:id/events    Event stream (SSE) or history
 *   POST         /v1/sessions/:id/archive   Archive session
 *   GET          /v1/system/genome     System capabilities
 *   GET          /v1/system/awareness  Live signals
 *   POST         /v1/system/evolve     Request system mutation
 *   GET/POST     /v1/memory/search     Semantic memory search
 *   GET          /v1/health            Health check
 */

import * as http from "http";
import * as fs from "fs";
import * as path from "path";
import { execSync } from "child_process";
import { db, genId, ensureDefaultToken } from "./db/index.ts";
import { executeMessage, subscribeSession } from "./engine/executor.ts";

const PORT = parseInt(process.env.PLATFORM_PORT || "8420");
const STATE_DIR = process.env.CLAUDE_OS_STATE || "/var/lib/claude-os";

// Generate default API token on startup
const defaultToken = ensureDefaultToken();
console.log(`Platform API starting on port ${PORT}`);
console.log(`Default API token: ${defaultToken}`);
console.log(`Token file: ${STATE_DIR}/platform/api-token`);

// ============================================
// Auth middleware
// ============================================
function authenticate(req: http.IncomingMessage): boolean {
  try {
    const auth = req.headers.authorization;
    if (!auth?.startsWith("Bearer ")) return false;
    const token = auth.slice(7);
    const row = db.get("SELECT token FROM api_tokens WHERE token = ?", token);
    if (row) {
      db.run("UPDATE api_tokens SET last_used = datetime('now') WHERE token = ?", token);
    }
    return !!row;
  } catch (e) {
    console.error("Auth error:", e);
    return false;
  }
}

// ============================================
// Request helpers
// ============================================
async function readBody(req: http.IncomingMessage): Promise<string> {
  return new Promise((resolve) => {
    let data = "";
    req.on("data", (chunk) => (data += chunk));
    req.on("end", () => resolve(data));
  });
}

function json(res: http.ServerResponse, status: number, data: any) {
  res.writeHead(status, { "Content-Type": "application/json", "Access-Control-Allow-Origin": "*" });
  res.end(JSON.stringify(data));
}

function error(res: http.ServerResponse, status: number, message: string) {
  json(res, status, { error: message });
}

// ============================================
// Route handlers
// ============================================

// --- Agents ---
function handleAgents(req: http.IncomingMessage, res: http.ServerResponse, parts: string[]) {
  const method = req.method;
  const agentId = parts[3]; // /v1/agents/:id

  if (method === "GET" && !agentId) {
    // List agents
    const agents = db.query("SELECT * FROM agents ORDER BY created_at DESC", );
    json(res, 200, { agents });

  } else if (method === "GET" && agentId) {
    // Get agent
    const agent = db.get("SELECT * FROM agents WHERE id = ?", agentId);
    if (!agent) return error(res, 404, "Agent not found");
    json(res, 200, agent);

  } else if (method === "POST" && !agentId) {
    // Create agent
    readBody(req).then((body) => {
      const data = JSON.parse(body);
      const id = genId("agent");
      db.run(`
        INSERT INTO agents (id, name, description, system_prompt, model_provider, model_id, model_fallback, tools, skills, composition, packages, env_vars, max_turns, max_tokens)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      `, 
        id,
        data.name || "Untitled Agent",
        data.description || "",
        data.system_prompt || "You are a helpful assistant.",
        data.model?.provider || "ollama",
        data.model?.id || "gemma4:31b-cloud",
        data.model?.fallback || "ollama",
        JSON.stringify(data.tools || []),
        JSON.stringify(data.skills || []),
        data.composition || null,
        JSON.stringify(data.packages || []),
        JSON.stringify(data.env_vars || {}),
        data.max_turns || 50,
        data.max_tokens || 16384
      );
      // Save version snapshot
      const agent = db.get("SELECT * FROM agents WHERE id = ?", id);
      db.run("INSERT INTO agent_versions (agent_id, version, snapshot) VALUES (?, 1, ?)", id, JSON.stringify(agent));
      json(res, 201, agent);
    }).catch((e) => error(res, 400, e.message));

  } else if (method === "DELETE" && agentId) {
    // Delete agent (check no active sessions)
    const active = db.get("SELECT COUNT(*) as n FROM sessions WHERE agent_id = ? AND status != 'archived'", agentId) as any;
    if (active?.n > 0) return error(res, 409, `Agent has ${active.n} active sessions`);
    db.run("DELETE FROM agents WHERE id = ?", agentId);
    json(res, 200, { deleted: agentId });

  } else {
    error(res, 405, "Method not allowed");
  }
}

// --- Sessions ---
function handleSessions(req: http.IncomingMessage, res: http.ServerResponse, parts: string[]) {
  const method = req.method;
  const sessionId = parts[3];
  const subResource = parts[4]; // messages, events, archive

  if (method === "GET" && !sessionId) {
    // List sessions
    const sessions = db.query("SELECT * FROM sessions WHERE status != 'archived' ORDER BY created_at DESC LIMIT 50", );
    json(res, 200, { sessions });

  } else if (method === "GET" && sessionId && !subResource) {
    // Get session
    const session = db.get("SELECT * FROM sessions WHERE id = ?", sessionId);
    if (!session) return error(res, 404, "Session not found");
    json(res, 200, session);

  } else if (method === "POST" && !sessionId) {
    // Create session
    readBody(req).then((body) => {
      const data = JSON.parse(body);
      const agent = db.get("SELECT * FROM agents WHERE id = ?", data.agent_id) as any;
      if (!agent) return error(res, 404, "Agent not found");

      // Check concurrent session limit
      const limit = (db.get("SELECT value FROM session_limits WHERE key = 'max_concurrent'", ) as any)?.value || "10";
      const active = (db.get("SELECT COUNT(*) as n FROM sessions WHERE status != 'archived'", ) as any)?.n || 0;
      if (active >= parseInt(limit)) return error(res, 429, `Max concurrent sessions (${limit}) reached`);

      const id = genId("sess");
      db.run(`
        INSERT INTO sessions (id, agent_id, agent_version, agent_snapshot, title, status, metadata, resources)
        VALUES (?, ?, ?, ?, ?, 'idle', ?, ?)
      `, 
        id, agent.id, agent.version, JSON.stringify(agent),
        data.title || "Untitled Session",
        JSON.stringify(data.metadata || {}),
        JSON.stringify(data.resources || [])
      );

      const session = db.get("SELECT * FROM sessions WHERE id = ?", id);
      json(res, 201, session);
    }).catch((e) => error(res, 400, e.message));

  } else if (method === "POST" && sessionId && subResource === "messages") {
    // Send message to session
    readBody(req).then(async (body) => {
      const data = JSON.parse(body);
      const message = data.content || data.message || data.text;
      if (!message) return error(res, 400, "Missing message content");

      try {
        await executeMessage(sessionId, message);
        // Return latest events
        const events = db.query(
          "SELECT * FROM events WHERE session_id = ? ORDER BY processed_at DESC LIMIT 10", sessionId
        );
        json(res, 200, { events: events.reverse() });
      } catch (e: any) {
        error(res, 500, e.message);
      }
    }).catch((e) => error(res, 400, e.message));

  } else if (method === "GET" && sessionId && subResource === "events") {
    // Check for SSE request
    if (req.headers.accept?.includes("text/event-stream")) {
      // SSE stream
      res.writeHead(200, {
        "Content-Type": "text/event-stream",
        "Cache-Control": "no-cache",
        "Connection": "keep-alive",
        "Access-Control-Allow-Origin": "*",
      });

      // Send existing events
      const existing = db.query("SELECT * FROM events WHERE session_id = ? ORDER BY processed_at", sessionId) as any[];
      for (const e of existing) {
        res.write(`data: ${JSON.stringify(e)}\n\n`);
      }

      // Subscribe to new events
      const unsub = subscribeSession(sessionId, (event) => {
        res.write(`data: ${JSON.stringify(event)}\n\n`);
      });

      req.on("close", unsub);
    } else {
      // Regular JSON event list
      const events = db.query("SELECT * FROM events WHERE session_id = ? ORDER BY processed_at", sessionId);
      json(res, 200, { events });
    }

  } else if (method === "POST" && sessionId && subResource === "archive") {
    db.run("UPDATE sessions SET status = 'archived', archived_at = datetime('now') WHERE id = ?", sessionId);
    json(res, 200, { archived: sessionId });

  } else if (method === "DELETE" && sessionId) {
    db.run("DELETE FROM sessions WHERE id = ?", sessionId);
    json(res, 200, { deleted: sessionId });

  } else {
    error(res, 405, "Method not allowed");
  }
}

// --- System endpoints (Claude-OS unique) ---
function handleSystem(req: http.IncomingMessage, res: http.ServerResponse, parts: string[]) {
  const subpath = parts[3]; // genome, awareness, evolve

  if (subpath === "genome" && req.method === "GET") {
    const genomePath = path.join(STATE_DIR, "genome", "manifest.json");
    if (fs.existsSync(genomePath)) {
      json(res, 200, JSON.parse(fs.readFileSync(genomePath, "utf-8")));
    } else {
      error(res, 404, "Genome not initialized");
    }

  } else if (subpath === "awareness" && req.method === "GET") {
    const statusPath = path.join(STATE_DIR, "awareness", "system-status.json");
    const healthPath = path.join(STATE_DIR, "awareness", "health.json");
    const data: any = {};
    if (fs.existsSync(statusPath)) data.status = JSON.parse(fs.readFileSync(statusPath, "utf-8"));
    if (fs.existsSync(healthPath)) data.health = JSON.parse(fs.readFileSync(healthPath, "utf-8"));

    // Recent signals
    const streamPath = path.join(STATE_DIR, "awareness", "signal-stream.jsonl");
    if (fs.existsSync(streamPath)) {
      const lines = fs.readFileSync(streamPath, "utf-8").trim().split("\n").slice(-20);
      data.recent_signals = lines.map((l) => { try { return JSON.parse(l); } catch { return null; } }).filter(Boolean);
    }
    json(res, 200, data);

  } else if (subpath === "evolve" && req.method === "POST") {
    readBody(req).then((body) => {
      const data = JSON.parse(body);
      const action = data.action; // add-package, add-capability, add-skill, apply
      const target = data.target;
      if (!action || !target) return error(res, 400, "Missing action or target");

      try {
        const result = execSync(
          `claude-os-evolve ${action} ${target}`,
          { encoding: "utf-8", timeout: 30000, env: { ...process.env, CLAUDE_OS_STATE: STATE_DIR } }
        );
        json(res, 200, { action, target, result: result.trim() });
      } catch (e: any) {
        error(res, 500, e.message);
      }
    }).catch((e) => error(res, 400, e.message));

  } else if (subpath === "evolution" && req.method === "GET") {
    const logPath = path.join(STATE_DIR, "evolution", "log.json");
    if (fs.existsSync(logPath)) {
      json(res, 200, JSON.parse(fs.readFileSync(logPath, "utf-8")));
    } else {
      error(res, 404, "Evolution log not found");
    }

  } else {
    error(res, 404, "Unknown system endpoint");
  }
}

// --- Memory endpoints ---
function handleMemory(req: http.IncomingMessage, res: http.ServerResponse, parts: string[]) {
  const subpath = parts[3]; // search, stats

  if (subpath === "search") {
    const handler = (query: string) => {
      try {
        const result = execSync(
          `claude-os-memory recall "${query.replace(/"/g, '\\"')}"`,
          { encoding: "utf-8", timeout: 10000, env: { ...process.env, CLAUDE_OS_STATE: STATE_DIR } }
        );
        try {
          json(res, 200, { results: JSON.parse(result) });
        } catch {
          json(res, 200, { results: result.trim() });
        }
      } catch (e: any) {
        error(res, 500, e.message);
      }
    };

    if (req.method === "GET") {
      const url = new URL(req.url!, `http://localhost`);
      const query = url.searchParams.get("q") || "";
      if (!query) return error(res, 400, "Missing ?q= parameter");
      handler(query);
    } else if (req.method === "POST") {
      readBody(req).then((body) => {
        const data = JSON.parse(body);
        handler(data.query || data.q || "");
      }).catch((e) => error(res, 400, e.message));
    }

  } else if (subpath === "stats" && req.method === "GET") {
    try {
      const result = execSync(
        "claude-os-memory stats",
        { encoding: "utf-8", timeout: 5000, env: { ...process.env, CLAUDE_OS_STATE: STATE_DIR } }
      );
      json(res, 200, { stats: result.trim() });
    } catch (e: any) {
      error(res, 500, e.message);
    }

  } else {
    error(res, 404, "Unknown memory endpoint");
  }
}

// ============================================
// HTTP Server
// ============================================
const server = http.createServer(async (req, res) => {
  // CORS preflight
  if (req.method === "OPTIONS") {
    res.writeHead(204, {
      "Access-Control-Allow-Origin": "*",
      "Access-Control-Allow-Methods": "GET, POST, PATCH, DELETE, OPTIONS",
      "Access-Control-Allow-Headers": "Content-Type, Authorization",
    });
    return res.end();
  }

  const url = new URL(req.url!, `http://localhost:${PORT}`);
  const parts = url.pathname.split("/").filter(Boolean); // ["v1", "agents", ...]

  // Health check (no auth)
  if (parts[0] === "v1" && parts[1] === "health") {
    return json(res, 200, { status: "ok", version: "0.1.0" });
  }

  // Auth required for all other endpoints
  if (!authenticate(req)) {
    return error(res, 401, "Unauthorized. Set Authorization: Bearer <token>");
  }

  try {
    if (parts[0] === "v1") {
      switch (parts[1]) {
        case "agents": return handleAgents(req, res, parts);
        case "sessions": return handleSessions(req, res, parts);
        case "system": return handleSystem(req, res, parts);
        case "memory": return handleMemory(req, res, parts);
        default: return error(res, 404, "Not found");
      }
    }
    error(res, 404, "Not found");
  } catch (e: any) {
    error(res, 500, e.message);
  }
});

server.listen(PORT, "0.0.0.0", () => {
  console.log(`Claude-OS Platform API running on http://0.0.0.0:${PORT}`);
  console.log(`Endpoints:`);
  console.log(`  GET/POST  /v1/agents`);
  console.log(`  GET/POST  /v1/sessions`);
  console.log(`  POST      /v1/sessions/:id/messages`);
  console.log(`  GET       /v1/sessions/:id/events (SSE)`);
  console.log(`  GET       /v1/system/genome`);
  console.log(`  GET       /v1/system/awareness`);
  console.log(`  POST      /v1/system/evolve`);
  console.log(`  GET/POST  /v1/memory/search`);
  console.log(`  GET       /v1/health`);
});
