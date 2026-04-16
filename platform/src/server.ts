#!/usr/bin/env node
/**
 * Claude-OS Managed Agents Platform
 * Postgres + Neo4j + Ollama
 *
 * Portal:  http://localhost:8420/
 * API:     http://localhost:8420/v1/...
 */

import * as http from "http";
import * as fs from "fs";
import * as path from "path";
import { execSync } from "child_process";
import { initDb, query, queryOne, exec, genId, ensureDefaultToken, validateToken, closeDb } from "./db/index.ts";
import { graph, initNeo4j, closeNeo4j } from "./db/neo4j.ts";
import { executeMessage, subscribeSession } from "./engine/executor.ts";

const PORT = parseInt(process.env.PLATFORM_PORT || "8420");
const STATE_DIR = process.env.CLAUDE_OS_STATE || "/var/lib/claude-os";

let hasDb = false, hasNeo4j = false;

// ═══ Helpers ═══
async function readBody(req: http.IncomingMessage): Promise<string> {
  return new Promise(r => { let d = ""; req.on("data", c => d += c); req.on("end", () => r(d)); });
}
function json(res: http.ServerResponse, status: number, data: any) {
  res.writeHead(status, { "Content-Type": "application/json", "Access-Control-Allow-Origin": "*" });
  res.end(JSON.stringify(data));
}
function err(res: http.ServerResponse, status: number, msg: string) { json(res, status, { error: msg }); }
function esc(s: string) { return s.replace(/</g, "&lt;"); }

// ═══ Agents ═══
async function handleAgents(req: http.IncomingMessage, res: http.ServerResponse, parts: string[]) {
  const id = parts[3];
  if (req.method === "GET" && !id) {
    return json(res, 200, { agents: hasDb ? await query("SELECT * FROM agents ORDER BY created_at DESC") : [] });
  }
  if (req.method === "GET" && id) {
    const a = hasDb ? await queryOne("SELECT * FROM agents WHERE id = $1", [id]) : null;
    return a ? json(res, 200, a) : err(res, 404, "Agent not found");
  }
  if (req.method === "POST" && !id) {
    if (!hasDb) return err(res, 503, "Database not available");
    const b = JSON.parse(await readBody(req));
    const aid = genId("agent");
    await exec(`INSERT INTO agents (id,name,description,system_prompt,model_provider,model_id,model_fallback,tools,skills,composition,packages,env_vars,max_turns,max_tokens)
      VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14)`,
      [aid, b.name||"Untitled", b.description||"", b.system_prompt||"You are a helpful assistant.",
       b.model?.provider||"ollama", b.model?.id||"gemma4:31b-cloud", b.model?.fallback||"ollama",
       JSON.stringify(b.tools||[]), JSON.stringify(b.skills||[]), b.composition||null,
       JSON.stringify(b.packages||[]), JSON.stringify(b.env_vars||{}), b.max_turns||50, b.max_tokens||16384]);
    const agent = await queryOne("SELECT * FROM agents WHERE id = $1", [aid]);
    await exec("INSERT INTO agent_versions (agent_id,version,snapshot) VALUES ($1,1,$2)", [aid, JSON.stringify(agent)]);
    return json(res, 201, agent);
  }
  if (req.method === "DELETE" && id) {
    if (!hasDb) return err(res, 503, "Database not available");
    const active = await query("SELECT id FROM sessions WHERE agent_id=$1 AND status!='archived'", [id]);
    if (active.length > 0) return err(res, 409, `Agent has ${active.length} active sessions`);
    await exec("DELETE FROM agents WHERE id=$1", [id]);
    return json(res, 200, { deleted: id });
  }
  err(res, 405, "Method not allowed");
}

// ═══ Sessions ═══
async function handleSessions(req: http.IncomingMessage, res: http.ServerResponse, parts: string[]) {
  const sid = parts[3], sub = parts[4];
  if (req.method === "GET" && !sid) {
    return json(res, 200, { sessions: hasDb ? await query("SELECT * FROM sessions WHERE status!='archived' ORDER BY created_at DESC LIMIT 50") : [] });
  }
  if (req.method === "GET" && sid && !sub) {
    const s = hasDb ? await queryOne("SELECT * FROM sessions WHERE id=$1", [sid]) : null;
    return s ? json(res, 200, s) : err(res, 404, "Session not found");
  }
  if (req.method === "POST" && !sid) {
    if (!hasDb) return err(res, 503, "Database not available");
    const b = JSON.parse(await readBody(req));
    const agent = await queryOne("SELECT * FROM agents WHERE id=$1", [b.agent_id]);
    if (!agent) return err(res, 404, "Agent not found");
    const limit = (await queryOne("SELECT value FROM session_limits WHERE key='max_concurrent'"))?.value || "10";
    const count = (await queryOne("SELECT count(*) as n FROM sessions WHERE status!='archived'"))?.n || 0;
    if (parseInt(count) >= parseInt(limit)) return err(res, 429, `Max sessions (${limit}) reached`);
    const id = genId("sess");
    await exec(`INSERT INTO sessions (id,agent_id,agent_version,agent_snapshot,title,status,metadata,resources)
      VALUES ($1,$2,$3,$4,$5,'idle',$6,$7)`,
      [id, agent.id, agent.version, JSON.stringify(agent), b.title||"Untitled", JSON.stringify(b.metadata||{}), JSON.stringify(b.resources||[])]);
    return json(res, 201, await queryOne("SELECT * FROM sessions WHERE id=$1", [id]));
  }
  if (req.method === "POST" && sid && sub === "messages") {
    const b = JSON.parse(await readBody(req));
    const msg = b.content || b.message || b.text;
    if (!msg) return err(res, 400, "Missing content");
    try {
      await executeMessage(sid, msg);
      const events = hasDb ? await query("SELECT * FROM events WHERE session_id=$1 ORDER BY processed_at DESC LIMIT 10", [sid]) : [];
      return json(res, 200, { events: events.reverse() });
    } catch (e: any) { return err(res, 500, e.message); }
  }
  if (req.method === "GET" && sid && sub === "events") {
    if (req.headers.accept?.includes("text/event-stream")) {
      res.writeHead(200, { "Content-Type": "text/event-stream", "Cache-Control": "no-cache", "Connection": "keep-alive", "Access-Control-Allow-Origin": "*" });
      if (hasDb) {
        const existing = await query("SELECT * FROM events WHERE session_id=$1 ORDER BY processed_at", [sid]);
        for (const e of existing) res.write(`data: ${JSON.stringify(e)}\n\n`);
      }
      const unsub = subscribeSession(sid, (event: any) => { res.write(`data: ${JSON.stringify(event)}\n\n`); });
      req.on("close", unsub);
      return;
    }
    return json(res, 200, { events: hasDb ? await query("SELECT * FROM events WHERE session_id=$1 ORDER BY processed_at", [sid]) : [] });
  }
  if (req.method === "POST" && sid && sub === "archive") {
    if (hasDb) await exec("UPDATE sessions SET status='archived', archived_at=NOW() WHERE id=$1", [sid]);
    return json(res, 200, { archived: sid });
  }
  if (req.method === "DELETE" && sid) {
    if (hasDb) await exec("DELETE FROM sessions WHERE id=$1", [sid]);
    return json(res, 200, { deleted: sid });
  }
  err(res, 405, "Method not allowed");
}

// ═══ System ═══
async function handleSystem(req: http.IncomingMessage, res: http.ServerResponse, parts: string[]) {
  const sub = parts[3];
  if (sub === "genome" && req.method === "GET") {
    const p = path.join(STATE_DIR, "genome", "manifest.json");
    return fs.existsSync(p) ? json(res, 200, JSON.parse(fs.readFileSync(p, "utf-8"))) : err(res, 404, "Genome not initialized");
  }
  if (sub === "awareness" && req.method === "GET") {
    const r: any = {};
    const sp = path.join(STATE_DIR, "awareness", "system-status.json");
    const hp = path.join(STATE_DIR, "awareness", "health.json");
    if (fs.existsSync(sp)) r.status = JSON.parse(fs.readFileSync(sp, "utf-8"));
    if (fs.existsSync(hp)) r.health = JSON.parse(fs.readFileSync(hp, "utf-8"));
    const sl = path.join(STATE_DIR, "awareness", "signal-stream.jsonl");
    if (fs.existsSync(sl)) r.recent_signals = fs.readFileSync(sl,"utf-8").trim().split("\n").slice(-20).map(l=>{try{return JSON.parse(l)}catch{return null}}).filter(Boolean);
    return json(res, 200, r);
  }
  if (sub === "evolve" && req.method === "POST") {
    const b = JSON.parse(await readBody(req));
    if (!b.action||!b.target) return err(res, 400, "Missing action/target");
    try { return json(res, 200, { result: execSync(`claude-os-evolve ${b.action} ${b.target}`, { encoding:"utf-8", timeout:30000, env:{...process.env, CLAUDE_OS_STATE:STATE_DIR} }).trim() }); }
    catch (e: any) { return err(res, 500, e.message); }
  }
  if (sub === "evolution" && req.method === "GET") {
    const p = path.join(STATE_DIR, "evolution", "log.json");
    return fs.existsSync(p) ? json(res, 200, JSON.parse(fs.readFileSync(p, "utf-8"))) : err(res, 404, "Not found");
  }
  err(res, 404, "Unknown endpoint");
}

// ═══ Memory (Neo4j) ═══
async function handleMemory(req: http.IncomingMessage, res: http.ServerResponse, parts: string[]) {
  const sub = parts[3];
  if (!hasNeo4j) return err(res, 503, "Neo4j not available");
  if (sub === "search") {
    const url = new URL(req.url!, "http://localhost");
    let q = url.searchParams.get("q") || "";
    if (req.method === "POST") { const b = JSON.parse(await readBody(req)); q = b.query || b.q || ""; }
    return q ? json(res, 200, { results: await graph.recall(q) }) : err(res, 400, "Missing query");
  }
  if (sub === "remember" && req.method === "POST") {
    const b = JSON.parse(await readBody(req));
    return json(res, 201, { id: await graph.remember(b.type||"fact", b.name, b.content, b.tags||"") });
  }
  if (sub === "relate" && req.method === "POST") {
    const b = JSON.parse(await readBody(req));
    await graph.relate(b.source_id, b.target_id, b.relation||"RELATED_TO", b.weight||1.0);
    return json(res, 200, { ok: true });
  }
  if (sub === "neighbors") {
    const url = new URL(req.url!, "http://localhost");
    const id = url.searchParams.get("id") || parts[4];
    return id ? json(res, 200, { neighbors: await graph.neighbors(id, parseInt(url.searchParams.get("hops")||"1")) }) : err(res, 400, "Missing id");
  }
  if (sub === "context") {
    const url = new URL(req.url!, "http://localhost");
    return json(res, 200, await graph.contextLoad(parseInt(url.searchParams.get("budget")||"4000"), url.searchParams.get("focus")||undefined));
  }
  if (sub === "stats") { return json(res, 200, await graph.stats()); }
  if (sub === "forget" && req.method === "POST") {
    const b = JSON.parse(await readBody(req)); await graph.forget(b.id); return json(res, 200, { ok: true });
  }
  err(res, 404, "Unknown endpoint");
}

// ═══ Main ═══
async function main() {
  console.log("Initializing Claude-OS Platform...");

  try { await initDb(); hasDb = true; } catch (e: any) { console.log("Postgres: not available —", e.message?.slice(0, 60)); }
  try { await initNeo4j(); hasNeo4j = true; } catch (e: any) { console.log("Neo4j: not available —", e.message?.slice(0, 60)); }

  let token = "";
  if (hasDb) { token = await ensureDefaultToken(); }
  else {
    const tf = path.join(STATE_DIR, "platform", "api-token");
    if (fs.existsSync(tf)) { token = fs.readFileSync(tf, "utf-8").trim(); }
    else {
      const crypto = await import("crypto");
      token = `cos_${crypto.randomBytes(24).toString("hex")}`;
      fs.mkdirSync(path.dirname(tf), { recursive: true });
      fs.writeFileSync(tf, token, { mode: 0o600 });
    }
  }

  const server = http.createServer(async (req, res) => {
    if (req.method === "OPTIONS") {
      res.writeHead(204, { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Methods": "GET,POST,PATCH,DELETE,OPTIONS", "Access-Control-Allow-Headers": "Content-Type,Authorization" });
      return res.end();
    }
    const url = new URL(req.url!, `http://localhost:${PORT}`);
    const parts = url.pathname.split("/").filter(Boolean);

    if (parts[0] === "v1" && parts[1] === "health") return json(res, 200, { status: "ok", version: "0.4.0", backends: { postgres: hasDb, neo4j: hasNeo4j } });

    if (url.pathname === "/" || url.pathname.startsWith("/portal")) {
      for (const p of [path.join(import.meta.dirname,"..","portal","index.html"), path.join(STATE_DIR,"platform","portal","index.html"), "/opt/claude-os/portal/index.html"]) {
        if (fs.existsSync(p)) { res.writeHead(200, {"Content-Type":"text/html","Access-Control-Allow-Origin":"*"}); return res.end(fs.readFileSync(p,"utf-8")); }
      }
      return err(res, 404, "Portal not found");
    }

    const bearer = req.headers.authorization?.startsWith("Bearer ") ? req.headers.authorization.slice(7) : "";
    let authed = false;
    if (hasDb) { authed = bearer ? await validateToken(bearer) : false; }
    else { const tf = path.join(STATE_DIR,"platform","api-token"); authed = bearer === (fs.existsSync(tf)?fs.readFileSync(tf,"utf-8").trim():""); }
    if (!authed) return err(res, 401, "Unauthorized");

    try {
      if (parts[0]==="v1") switch(parts[1]) {
        case "agents": return await handleAgents(req,res,parts);
        case "sessions": return await handleSessions(req,res,parts);
        case "system": return await handleSystem(req,res,parts);
        case "memory": return await handleMemory(req,res,parts);
      }
      err(res, 404, "Not found");
    } catch (e: any) { console.error("Error:", e.message); err(res, 500, e.message); }
  });

  server.listen(PORT, "0.0.0.0", () => {
    console.log(`\nClaude-OS Platform on http://0.0.0.0:${PORT}`);
    console.log(`  Portal:   http://localhost:${PORT}/`);
    console.log(`  Postgres: ${hasDb ? 'connected' : 'standalone mode'}`);
    console.log(`  Neo4j:    ${hasNeo4j ? 'connected' : 'standalone mode'}`);
    console.log(`  Token:    ${token.slice(0,20)}...`);
  });

  process.on("SIGTERM", async () => { await closeDb(); await closeNeo4j(); process.exit(0); });
}

main().catch(e => { console.error("Fatal:", e); process.exit(1); });
