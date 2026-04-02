#!/usr/bin/env node

import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";
import Database from "better-sqlite3";
import * as path from "path";

const STATE_DIR = process.env.CLAUDE_OS_STATE || "/var/lib/claude-os";
const DB_PATH = path.join(STATE_DIR, "memory", "graph.sqlite");

let db: Database.Database;
try {
  db = new Database(DB_PATH, { readonly: false });
  db.pragma("journal_mode = WAL");
  db.pragma("foreign_keys = ON");
} catch (e) {
  console.error(`Failed to open memory graph: ${e}`);
  process.exit(1);
}

// Helper: touch entity access
const touchEntity = db.prepare(
  `UPDATE entities SET last_accessed = datetime('now'), access_count = access_count + 1,
   decay_score = MIN(1.0, decay_score + 0.1) WHERE id = ?`
);

const server = new McpServer({
  name: "claude-os-memory-graph",
  version: "0.1.0",
});

// ============================================
// Tool: Remember — store a new memory
// ============================================
server.tool(
  "remember",
  "Store a new memory in the knowledge graph. Use this to persist facts, learnings, patterns, and preferences.",
  {
    type: z.enum(["fact", "user_pref", "tool_knowledge", "task_pattern", "skill", "episode", "goal"]),
    name: z.string().describe("Short identifier for this memory"),
    content: z.string().describe("Full content of the memory"),
    tags: z.string().optional().describe("Comma-separated tags"),
    related_to: z.array(z.number()).optional().describe("IDs of related entities to link"),
  },
  async ({ type, name, content, tags, related_to }) => {
    const stmt = db.prepare(
      `INSERT INTO entities (type, name, content, tags) VALUES (?, ?, ?, ?) RETURNING id`
    );
    const result = stmt.get(type, name, content, tags || "") as { id: number };

    // Create relations if specified
    if (related_to && related_to.length > 0) {
      const relStmt = db.prepare(
        `INSERT OR IGNORE INTO relations (src_id, dst_id, rel_type, weight) VALUES (?, ?, 'related_to', 1.0)`
      );
      for (const targetId of related_to) {
        relStmt.run(result.id, targetId);
      }
    }

    return {
      content: [{
        type: "text" as const,
        text: `Remembered: #${result.id} [${type}] "${name}" (${content.length} chars${related_to ? `, linked to ${related_to.length} entities` : ""})`,
      }],
    };
  }
);

// ============================================
// Tool: Recall — search memories
// ============================================
server.tool(
  "recall",
  "Search the memory graph using full-text search. Returns the most relevant memories matching the query.",
  {
    query: z.string().describe("Search query (supports FTS5 syntax: AND, OR, NOT, phrases)"),
    limit: z.number().optional().describe("Max results (default 10)"),
    type_filter: z.string().optional().describe("Filter by entity type"),
  },
  async ({ query, limit, type_filter }) => {
    const maxResults = limit || 10;
    let sql = `
      SELECT e.id, e.type, e.name, e.content, e.tags, e.access_count,
             round(e.decay_score, 3) as decay_score,
             round(rank, 4) as fts_rank
      FROM entities_fts fts
      JOIN entities e ON e.id = fts.rowid
      WHERE entities_fts MATCH ?
    `;
    const params: any[] = [query];

    if (type_filter) {
      sql += ` AND e.type = ?`;
      params.push(type_filter);
    }

    sql += ` ORDER BY (e.decay_score * -rank * (1 + ln(1 + e.access_count))) DESC LIMIT ?`;
    params.push(maxResults);

    const results = db.prepare(sql).all(...params) as any[];

    // Touch accessed entities
    for (const r of results) {
      touchEntity.run(r.id);
    }

    if (results.length === 0) {
      return { content: [{ type: "text" as const, text: `No memories found for: "${query}"` }] };
    }

    const formatted = results.map((r) =>
      `**#${r.id} [${r.type}] ${r.name}** (decay: ${r.decay_score}, accesses: ${r.access_count})\n${r.content}\n${r.tags ? `Tags: ${r.tags}` : ""}`
    ).join("\n\n---\n\n");

    return { content: [{ type: "text" as const, text: `Found ${results.length} memories:\n\n${formatted}` }] };
  }
);

// ============================================
// Tool: Relate — create graph edges
// ============================================
server.tool(
  "relate",
  "Create a relationship between two memory entities in the graph.",
  {
    source_id: z.number().describe("Source entity ID"),
    target_id: z.number().describe("Target entity ID"),
    relation: z.enum(["related_to", "requires", "part_of", "supersedes", "triggers", "caused_by", "learned_from"]),
    weight: z.number().optional().describe("Edge weight 0-1 (default 1.0)"),
  },
  async ({ source_id, target_id, relation, weight }) => {
    db.prepare(
      `INSERT OR REPLACE INTO relations (src_id, dst_id, rel_type, weight) VALUES (?, ?, ?, ?)`
    ).run(source_id, target_id, relation, weight || 1.0);

    return {
      content: [{
        type: "text" as const,
        text: `Related: #${source_id} --[${relation}]--> #${target_id} (weight: ${weight || 1.0})`,
      }],
    };
  }
);

// ============================================
// Tool: Neighbors — graph traversal
// ============================================
server.tool(
  "neighbors",
  "Traverse the memory graph from a given entity. Returns connected entities up to N hops away.",
  {
    entity_id: z.number().describe("Starting entity ID"),
    hops: z.number().optional().describe("How many hops to traverse (default 1, max 3)"),
  },
  async ({ entity_id, hops }) => {
    const maxHops = Math.min(hops || 1, 3);

    const results = db.prepare(`
      WITH RECURSIVE traverse(entity_id, depth, path) AS (
        SELECT ?, 0, CAST(? AS TEXT)
        UNION ALL
        SELECT
          CASE WHEN r.src_id = t.entity_id THEN r.dst_id ELSE r.src_id END,
          t.depth + 1,
          t.path || ',' || CASE WHEN r.src_id = t.entity_id THEN r.dst_id ELSE r.src_id END
        FROM traverse t
        JOIN relations r ON (r.src_id = t.entity_id OR r.dst_id = t.entity_id)
        WHERE t.depth < ?
          AND INSTR(t.path, CAST(CASE WHEN r.src_id = t.entity_id THEN r.dst_id ELSE r.src_id END AS TEXT)) = 0
      )
      SELECT DISTINCT e.id, e.type, e.name, substr(e.content, 1, 200) as preview,
             t.depth as hops, round(e.decay_score, 2) as decay
      FROM traverse t
      JOIN entities e ON e.id = t.entity_id
      WHERE e.id != ?
      ORDER BY t.depth, e.decay_score DESC
    `).all(entity_id, entity_id, maxHops, entity_id) as any[];

    if (results.length === 0) {
      return { content: [{ type: "text" as const, text: `No neighbors found for entity #${entity_id}` }] };
    }

    const formatted = results.map((r) =>
      `[${r.hops} hop] #${r.id} [${r.type}] ${r.name}: ${r.preview}`
    ).join("\n");

    return { content: [{ type: "text" as const, text: `Neighbors of #${entity_id} (${results.length} found, up to ${maxHops} hops):\n\n${formatted}` }] };
  }
);

// ============================================
// Tool: Context Load — smart context window
// ============================================
server.tool(
  "context_load",
  "Load the most relevant memories into the current context window, respecting a token budget. Use this at the start of complex tasks to prime your context with relevant past knowledge.",
  {
    session_id: z.string().describe("Current session identifier"),
    token_budget: z.number().optional().describe("Max tokens to use for context (default 4000)"),
    focus_query: z.string().optional().describe("Optional query to bias context toward"),
  },
  async ({ session_id, token_budget, focus_query }) => {
    const budget = token_budget || 4000;

    // Get relevance-scored entities
    let entities: any[];
    if (focus_query) {
      // If focus query provided, combine FTS results with general relevance
      entities = db.prepare(`
        SELECT e.id, e.type, e.name, e.content, e.tags, e.decay_score, e.access_count,
               length(e.content) / 4 as est_tokens,
               COALESCE(-fts.rank, 0) * 2 + (
                 e.decay_score *
                 (1.0 + ln(1 + e.access_count)) *
                 (1.0 / (1.0 + (julianday('now') - julianday(e.last_accessed))))
               ) as relevance
        FROM entities e
        LEFT JOIN entities_fts fts ON fts.rowid = e.id AND entities_fts MATCH ?
        WHERE e.decay_score > 0.05
        ORDER BY relevance DESC
      `).all(focus_query) as any[];
    } else {
      entities = db.prepare(`
        SELECT id, type, name, content, tags, decay_score, access_count,
               length(content) / 4 as est_tokens,
               (decay_score *
                (1.0 + ln(1 + access_count)) *
                (1.0 / (1.0 + (julianday('now') - julianday(last_accessed)))) *
                (1.0 + (SELECT COUNT(*) FROM relations WHERE src_id = entities.id OR dst_id = entities.id) * 0.1)
               ) as relevance
        FROM entities
        WHERE decay_score > 0.05
        ORDER BY relevance DESC
      `).all() as any[];
    }

    // Greedily pack into budget
    let totalTokens = 0;
    const loaded: any[] = [];
    const clearStmt = db.prepare(`DELETE FROM context_windows WHERE session_id = ?`);
    const insertStmt = db.prepare(
      `INSERT INTO context_windows (session_id, entity_id, relevance, token_cost) VALUES (?, ?, ?, ?)`
    );

    clearStmt.run(session_id);

    for (const entity of entities) {
      if (totalTokens + entity.est_tokens > budget) continue;
      totalTokens += entity.est_tokens;
      loaded.push(entity);
      insertStmt.run(session_id, entity.id, entity.relevance, entity.est_tokens);
      touchEntity.run(entity.id);
    }

    // Format as structured context
    const contextText = loaded.map((e) =>
      `## [${e.type}] ${e.name}\n${e.content}${e.tags ? `\n_Tags: ${e.tags}_` : ""}`
    ).join("\n\n");

    return {
      content: [{
        type: "text" as const,
        text: `# Memory Context (${loaded.length} entities, ~${totalTokens} tokens)\n\n${contextText}\n\n---\n_Context loaded for session ${session_id}. Budget: ${totalTokens}/${budget} tokens used._`,
      }],
    };
  }
);

// ============================================
// Tool: Forget — remove a memory
// ============================================
server.tool(
  "forget",
  "Remove a memory entity and all its relations from the graph.",
  {
    entity_id: z.number().describe("Entity ID to remove"),
  },
  async ({ entity_id }) => {
    const entity = db.prepare(`SELECT name, type FROM entities WHERE id = ?`).get(entity_id) as any;
    if (!entity) {
      return { content: [{ type: "text" as const, text: `Entity #${entity_id} not found` }] };
    }
    db.prepare(`DELETE FROM entities WHERE id = ?`).run(entity_id);
    return {
      content: [{ type: "text" as const, text: `Forgotten: #${entity_id} [${entity.type}] "${entity.name}"` }],
    };
  }
);

// ============================================
// Tool: Memory Stats
// ============================================
server.tool(
  "memory_stats",
  "Get statistics about the memory graph — entity counts, relation counts, decay distribution.",
  {},
  async () => {
    const stats = {
      entities: (db.prepare(`SELECT COUNT(*) as n FROM entities`).get() as any).n,
      relations: (db.prepare(`SELECT COUNT(*) as n FROM relations`).get() as any).n,
      summaries: (db.prepare(`SELECT COUNT(*) as n FROM summaries`).get() as any).n,
      avg_decay: (db.prepare(`SELECT round(avg(decay_score), 3) as v FROM entities`).get() as any).v,
      total_accesses: (db.prepare(`SELECT SUM(access_count) as v FROM entities`).get() as any).v,
      by_type: db.prepare(`SELECT type, COUNT(*) as count FROM entities GROUP BY type ORDER BY count DESC`).all(),
      by_relation: db.prepare(`SELECT rel_type, COUNT(*) as count FROM relations GROUP BY rel_type ORDER BY count DESC`).all(),
    };

    return {
      content: [{
        type: "text" as const,
        text: JSON.stringify(stats, null, 2),
      }],
    };
  }
);

async function main() {
  const transport = new StdioServerTransport();
  await server.connect(transport);
}

main().catch(console.error);
