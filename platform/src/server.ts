#!/usr/bin/env node
/**
 * Claude-OS Managed Agents Platform
 * Powered by Supabase (Postgres + Auth + Realtime) + Neo4j (Graph Memory)
 *
 * Portal:  http://localhost:8420/
 * API:     http://localhost:8420/v1/...
 */

import * as http from "http";
import * as fs from "fs";
import * as path from "path";
import { execSync } from "child_process";
import { supabase, genId, ensureDefaultToken, validateToken, waitForDb } from "./db/index.ts";
import { graph, initNeo4j, closeNeo4j } from "./db/neo4j.ts";
import { executeMessage, subscribeSession } from "./engine/executor.ts";

const PORT = parseInt(process.env.PLATFORM_PORT || "8420");
const STATE_DIR = process.env.CLAUDE_OS_STATE || "/var/lib/claude-os";

// ============================================
// Request helpers
// ============================================
async function readBody(req: http.IncomingMessage): Promise<string> {
  return new Promise((resolve) => {
    let data = "";
    req.on("data", (chunk: any) => (data += chunk));
    req.on("end", () => resolve(data));
  });
}

function json(res: http.ServerResponse, status: number, data: any) {
  res.writeHead(status, { "Content-Type": "application/json", "Access-Control-Allow-Origin": "*" });
  res.end(JSON.stringify(data));
}

function err(res: http.ServerResponse, status: number, message: string) {
  json(res, status, { error: message });
}

// ============================================
// Agents
// ============================================
async function handleAgents(req: http.IncomingMessage, res: http.ServerResponse, parts: string[]) {
  const agentId = parts[3];

  if (req.method === "GET" && !agentId) {
    const { data } = await supabase.from("agents").select("*").order("created_at", { ascending: false });
    return json(res, 200, { agents: data || [] });

  } else if (req.method === "GET" && agentId) {
    const { data } = await supabase.from("agents").select("*").eq("id", agentId).single();
    if (!data) return err(res, 404, "Agent not found");
    return json(res, 200, data);

  } else if (req.method === "POST" && !agentId) {
    const body = JSON.parse(await readBody(req));
    const id = genId("agent");
    const agent = {
      id,
      name: body.name || "Untitled Agent",
      description: body.description || "",
      system_prompt: body.system_prompt || "You are a helpful assistant.",
      model_provider: body.model?.provider || "ollama",
      model_id: body.model?.id || "gemma4:31b-cloud",
      model_fallback: body.model?.fallback || "ollama",
      tools: body.tools || [],
      skills: body.skills || [],
      composition: body.composition || null,
      packages: body.packages || [],
      env_vars: body.env_vars || {},
      max_turns: body.max_turns || 50,
      max_tokens: body.max_tokens || 16384,
    };
    await supabase.from("agents").insert(agent);
    await supabase.from("agent_versions").insert({ agent_id: id, version: 1, snapshot: agent });
    return json(res, 201, agent);

  } else if (req.method === "DELETE" && agentId) {
    const { data: active } = await supabase.from("sessions").select("id").eq("agent_id", agentId).neq("status", "archived");
    if (active && active.length > 0) return err(res, 409, `Agent has ${active.length} active sessions`);
    await supabase.from("agents").delete().eq("id", agentId);
    return json(res, 200, { deleted: agentId });
  }
  err(res, 405, "Method not allowed");
}

// ============================================
// Sessions
// ============================================
async function handleSessions(req: http.IncomingMessage, res: http.ServerResponse, parts: string[]) {
  const sessionId = parts[3];
  const sub = parts[4];

  if (req.method === "GET" && !sessionId) {
    const { data } = await supabase.from("sessions").select("*").neq("status", "archived").order("created_at", { ascending: false }).limit(50);
    return json(res, 200, { sessions: data || [] });

  } else if (req.method === "GET" && sessionId && !sub) {
    const { data } = await supabase.from("sessions").select("*").eq("id", sessionId).single();
    if (!data) return err(res, 404, "Session not found");
    return json(res, 200, data);

  } else if (req.method === "POST" && !sessionId) {
    const body = JSON.parse(await readBody(req));
    const { data: agent } = await supabase.from("agents").select("*").eq("id", body.agent_id).single();
    if (!agent) return err(res, 404, "Agent not found");

    const { data: limits } = await supabase.from("session_limits").select("value").eq("key", "max_concurrent").single();
    const maxConcurrent = parseInt(limits?.value || "10");
    const { count } = await supabase.from("sessions").select("id", { count: "exact", head: true }).neq("status", "archived");
    if ((count || 0) >= maxConcurrent) return err(res, 429, `Max concurrent sessions (${maxConcurrent}) reached`);

    const id = genId("sess");
    const session = {
      id,
      agent_id: agent.id,
      agent_version: agent.version,
      agent_snapshot: agent,
      title: body.title || "Untitled Session",
      status: "idle",
      metadata: body.metadata || {},
      resources: body.resources || [],
    };
    await supabase.from("sessions").insert(session);
    return json(res, 201, session);

  } else if (req.method === "POST" && sessionId && sub === "messages") {
    const body = JSON.parse(await readBody(req));
    const message = body.content || body.message || body.text;
    if (!message) return err(res, 400, "Missing message content");
    try {
      await executeMessage(sessionId, message);
      const { data: events } = await supabase.from("events").select("*").eq("session_id", sessionId).order("processed_at", { ascending: false }).limit(10);
      return json(res, 200, { events: (events || []).reverse() });
    } catch (e: any) {
      return err(res, 500, e.message);
    }

  } else if (req.method === "GET" && sessionId && sub === "events") {
    if (req.headers.accept?.includes("text/event-stream")) {
      res.writeHead(200, {
        "Content-Type": "text/event-stream",
        "Cache-Control": "no-cache",
        "Connection": "keep-alive",
        "Access-Control-Allow-Origin": "*",
      });
      const { data: existing } = await supabase.from("events").select("*").eq("session_id", sessionId).order("processed_at");
      for (const e of existing || []) res.write(`data: ${JSON.stringify(e)}\n\n`);

      // Subscribe to new events via Supabase Realtime
      const channel = supabase.channel(`session-${sessionId}`).on(
        "postgres_changes",
        { event: "INSERT", schema: "public", table: "events", filter: `session_id=eq.${sessionId}` },
        (payload: any) => { res.write(`data: ${JSON.stringify(payload.new)}\n\n`); }
      ).subscribe();

      // Also subscribe to in-process events
      const unsub = subscribeSession(sessionId, (event: any) => {
        res.write(`data: ${JSON.stringify(event)}\n\n`);
      });

      req.on("close", () => { channel.unsubscribe(); unsub(); });
    } else {
      const { data } = await supabase.from("events").select("*").eq("session_id", sessionId).order("processed_at");
      return json(res, 200, { events: data || [] });
    }

  } else if (req.method === "POST" && sessionId && sub === "archive") {
    await supabase.from("sessions").update({ status: "archived", archived_at: new Date().toISOString() }).eq("id", sessionId);
    return json(res, 200, { archived: sessionId });

  } else if (req.method === "DELETE" && sessionId) {
    await supabase.from("sessions").delete().eq("id", sessionId);
    return json(res, 200, { deleted: sessionId });
  }
  err(res, 405, "Method not allowed");
}

// ============================================
// System (Claude-OS unique endpoints)
// ============================================
async function handleSystem(req: http.IncomingMessage, res: http.ServerResponse, parts: string[]) {
  const sub = parts[3];

  if (sub === "genome" && req.method === "GET") {
    const genomePath = path.join(STATE_DIR, "genome", "manifest.json");
    if (fs.existsSync(genomePath)) return json(res, 200, JSON.parse(fs.readFileSync(genomePath, "utf-8")));
    // Try from Supabase
    const { data } = await supabase.from("system_state").select("value").eq("key", "genome").single();
    if (data) return json(res, 200, data.value);
    return err(res, 404, "Genome not initialized");

  } else if (sub === "awareness" && req.method === "GET") {
    const statusPath = path.join(STATE_DIR, "awareness", "system-status.json");
    const healthPath = path.join(STATE_DIR, "awareness", "health.json");
    const result: any = {};
    if (fs.existsSync(statusPath)) result.status = JSON.parse(fs.readFileSync(statusPath, "utf-8"));
    if (fs.existsSync(healthPath)) result.health = JSON.parse(fs.readFileSync(healthPath, "utf-8"));
    const streamPath = path.join(STATE_DIR, "awareness", "signal-stream.jsonl");
    if (fs.existsSync(streamPath)) {
      result.recent_signals = fs.readFileSync(streamPath, "utf-8").trim().split("\n").slice(-20)
        .map((l: string) => { try { return JSON.parse(l); } catch { return null; } }).filter(Boolean);
    }
    return json(res, 200, result);

  } else if (sub === "evolve" && req.method === "POST") {
    const body = JSON.parse(await readBody(req));
    if (!body.action || !body.target) return err(res, 400, "Missing action or target");
    try {
      const result = execSync(`claude-os-evolve ${body.action} ${body.target}`, {
        encoding: "utf-8", timeout: 30000, env: { ...process.env, CLAUDE_OS_STATE: STATE_DIR },
      });
      return json(res, 200, { action: body.action, target: body.target, result: result.trim() });
    } catch (e: any) {
      return err(res, 500, e.message);
    }

  } else if (sub === "evolution" && req.method === "GET") {
    const logPath = path.join(STATE_DIR, "evolution", "log.json");
    if (fs.existsSync(logPath)) return json(res, 200, JSON.parse(fs.readFileSync(logPath, "utf-8")));
    return err(res, 404, "Evolution log not found");
  }
  err(res, 404, "Unknown system endpoint");
}

// ============================================
// Memory (Neo4j graph)
// ============================================
async function handleMemory(req: http.IncomingMessage, res: http.ServerResponse, parts: string[]) {
  const sub = parts[3];

  if (sub === "search") {
    const url = new URL(req.url!, `http://localhost`);
    let query = url.searchParams.get("q") || "";
    if (req.method === "POST") {
      const body = JSON.parse(await readBody(req));
      query = body.query || body.q || "";
    }
    if (!query) return err(res, 400, "Missing query");
    const results = await graph.recall(query);
    return json(res, 200, { results });

  } else if (sub === "remember" && req.method === "POST") {
    const body = JSON.parse(await readBody(req));
    const id = await graph.remember(body.type || "fact", body.name, body.content, body.tags || "");
    return json(res, 201, { id, name: body.name });

  } else if (sub === "relate" && req.method === "POST") {
    const body = JSON.parse(await readBody(req));
    await graph.relate(body.source_id, body.target_id, body.relation || "RELATED_TO", body.weight || 1.0);
    return json(res, 200, { related: true });

  } else if (sub === "neighbors") {
    const url = new URL(req.url!, `http://localhost`);
    const entityId = url.searchParams.get("id") || parts[4];
    const hops = parseInt(url.searchParams.get("hops") || "1");
    if (!entityId) return err(res, 400, "Missing entity id");
    const results = await graph.neighbors(entityId, hops);
    return json(res, 200, { neighbors: results });

  } else if (sub === "context") {
    const url = new URL(req.url!, `http://localhost`);
    const budget = parseInt(url.searchParams.get("budget") || "4000");
    const focus = url.searchParams.get("focus") || undefined;
    const result = await graph.contextLoad(budget, focus);
    return json(res, 200, result);

  } else if (sub === "stats") {
    const stats = await graph.stats();
    return json(res, 200, stats);

  } else if (sub === "forget" && req.method === "POST") {
    const body = JSON.parse(await readBody(req));
    await graph.forget(body.id);
    return json(res, 200, { forgotten: body.id });
  }
  err(res, 404, "Unknown memory endpoint");
}

// ============================================
// HTTP Server
// ============================================
async function main() {
  console.log("Initializing Claude-OS Platform...");

  // Connect to backends
  await waitForDb();
  await initNeo4j();

  const defaultToken = await ensureDefaultToken();
  console.log(`Default API token: ${defaultToken}`);

  const server = http.createServer(async (req, res) => {
    if (req.method === "OPTIONS") {
      res.writeHead(204, {
        "Access-Control-Allow-Origin": "*",
        "Access-Control-Allow-Methods": "GET, POST, PATCH, DELETE, OPTIONS",
        "Access-Control-Allow-Headers": "Content-Type, Authorization",
      });
      return res.end();
    }

    const url = new URL(req.url!, `http://localhost:${PORT}`);
    const parts = url.pathname.split("/").filter(Boolean);

    // Health (no auth)
    if (parts[0] === "v1" && parts[1] === "health") {
      return json(res, 200, { status: "ok", version: "0.4.0", backends: { supabase: true, neo4j: true } });
    }

    // Portal (no auth for the page itself)
    if (url.pathname === "/" || url.pathname === "/portal" || url.pathname === "/portal/") {
      const portalPaths = [
        path.join(import.meta.dirname, "..", "portal", "index.html"),
        path.join(STATE_DIR, "platform", "portal", "index.html"),
        "/opt/claude-os/portal/index.html",
      ];
      for (const p of portalPaths) {
        if (fs.existsSync(p)) {
          res.writeHead(200, { "Content-Type": "text/html", "Access-Control-Allow-Origin": "*" });
          return res.end(fs.readFileSync(p, "utf-8"));
        }
      }
      return err(res, 404, "Portal not found");
    }

    // Auth for all API endpoints
    const authHeader = req.headers.authorization;
    if (!authHeader?.startsWith("Bearer ") || !(await validateToken(authHeader.slice(7)))) {
      return err(res, 401, "Unauthorized. Set Authorization: Bearer <token>");
    }

    try {
      if (parts[0] === "v1") {
        switch (parts[1]) {
          case "agents": return await handleAgents(req, res, parts);
          case "sessions": return await handleSessions(req, res, parts);
          case "system": return await handleSystem(req, res, parts);
          case "memory": return await handleMemory(req, res, parts);
        }
      }
      err(res, 404, "Not found");
    } catch (e: any) {
      console.error("Request error:", e.message);
      err(res, 500, e.message);
    }
  });

  server.listen(PORT, "0.0.0.0", () => {
    console.log(`\nClaude-OS Platform running on http://0.0.0.0:${PORT}`);
    console.log(`  Portal:     http://localhost:${PORT}/`);
    console.log(`  API:        http://localhost:${PORT}/v1/...`);
    console.log(`  Neo4j UI:   http://localhost:7474/`);
    console.log(`  Supabase:   http://localhost:54321/`);
  });

  process.on("SIGTERM", async () => { await closeNeo4j(); process.exit(0); });
}

main().catch((e) => { console.error("Fatal:", e); process.exit(1); });
