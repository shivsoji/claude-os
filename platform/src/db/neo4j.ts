import neo4j, { type Driver, type Session } from "neo4j-driver";

const NEO4J_URI = process.env.NEO4J_URI || "bolt://neo4j:7687";
const NEO4J_USER = process.env.NEO4J_USER || "neo4j";
const NEO4J_PASSWORD = process.env.NEO4J_PASSWORD || "claude-os-graph";

let driver: Driver;

export async function initNeo4j(): Promise<void> {
  driver = neo4j.driver(NEO4J_URI, neo4j.auth.basic(NEO4J_USER, NEO4J_PASSWORD));

  // Wait for connection (5 retries in standalone, fast fail)
  for (let i = 0; i < 5; i++) {
    try {
      await driver.verifyConnectivity();
      console.log("Neo4j connected");
      break;
    } catch (e) {
      console.log(`Waiting for Neo4j... (${i + 1}/30)`);
      await new Promise((r) => setTimeout(r, 2000));
    }
  }

  // Initialize schema constraints and indexes
  const session = driver.session();
  try {
    await session.run(`CREATE CONSTRAINT entity_id IF NOT EXISTS FOR (e:Entity) REQUIRE e.id IS UNIQUE`);
    await session.run(`CREATE INDEX entity_type IF NOT EXISTS FOR (e:Entity) ON (e.type)`);
    await session.run(`CREATE INDEX entity_decay IF NOT EXISTS FOR (e:Entity) ON (e.decay_score)`);
    await session.run(`CREATE FULLTEXT INDEX entity_search IF NOT EXISTS FOR (e:Entity) ON EACH [e.name, e.content, e.tags]`);

    // Seed system identity if empty
    const result = await session.run(`MATCH (e:Entity {type: 'system'}) RETURN count(e) as n`);
    if (result.records[0].get("n").toNumber() === 0) {
      await session.run(`
        CREATE (id:Entity {id: 'sys_identity', type: 'system', name: 'identity',
          content: 'I am Claude-OS, a self-evolving AI operating system.',
          tags: 'core,identity', decay_score: 1.0, access_count: 0,
          created_at: datetime(), last_accessed: datetime()})
        CREATE (arch:Entity {id: 'sys_architecture', type: 'system', name: 'architecture',
          content: 'NixOS base, Neo4j graph memory, Supabase platform, Ollama local LLM.',
          tags: 'core,architecture', decay_score: 1.0, access_count: 0,
          created_at: datetime(), last_accessed: datetime()})
        CREATE (caps:Entity {id: 'sys_capabilities', type: 'system', name: 'capabilities',
          content: 'Shell, networking, SSH, file management, version control, managed agents platform.',
          tags: 'core,capabilities', decay_score: 1.0, access_count: 0,
          created_at: datetime(), last_accessed: datetime()})
        CREATE (id)-[:HAS]->(arch)
        CREATE (id)-[:HAS]->(caps)
        CREATE (arch)-[:ENABLES]->(caps)
      `);
      console.log("Neo4j seeded with system identity");
    }
  } finally {
    await session.close();
  }
}

function getSession(): Session {
  return driver.session();
}

// ============================================
// Memory Graph API
// ============================================

export const graph = {
  async remember(type: string, name: string, content: string, tags: string = ""): Promise<string> {
    const id = `mem_${Date.now()}_${Math.random().toString(36).slice(2, 8)}`;
    const session = getSession();
    try {
      await session.run(
        `CREATE (e:Entity {id: $id, type: $type, name: $name, content: $content, tags: $tags,
          decay_score: 1.0, access_count: 0, created_at: datetime(), last_accessed: datetime()})`,
        { id, type, name, content, tags }
      );
      return id;
    } finally {
      await session.close();
    }
  },

  async recall(query: string, limit: number = 10): Promise<any[]> {
    const session = getSession();
    try {
      const result = await session.run(
        `CALL db.index.fulltext.queryNodes('entity_search', $query) YIELD node, score
         RETURN node.id as id, node.type as type, node.name as name,
                substring(node.content, 0, 200) as preview, node.tags as tags,
                node.decay_score as decay, node.access_count as accesses, score
         ORDER BY score * node.decay_score * (1 + log(1 + node.access_count)) DESC
         LIMIT $limit`,
        { query, limit: neo4j.int(limit) }
      );
      // Touch accessed entities
      for (const rec of result.records) {
        await session.run(
          `MATCH (e:Entity {id: $id}) SET e.last_accessed = datetime(), e.access_count = e.access_count + 1, e.decay_score = CASE WHEN e.decay_score + 0.1 > 1.0 THEN 1.0 ELSE e.decay_score + 0.1 END`,
          { id: rec.get("id") }
        );
      }
      return result.records.map((r) => ({
        id: r.get("id"),
        type: r.get("type"),
        name: r.get("name"),
        preview: r.get("preview"),
        tags: r.get("tags"),
        decay: r.get("decay"),
        accesses: typeof r.get("accesses") === "object" ? r.get("accesses").toNumber() : r.get("accesses"),
        score: r.get("score"),
      }));
    } finally {
      await session.close();
    }
  },

  async relate(sourceId: string, targetId: string, relType: string, weight: number = 1.0): Promise<void> {
    const session = getSession();
    try {
      await session.run(
        `MATCH (a:Entity {id: $src}), (b:Entity {id: $dst})
         MERGE (a)-[r:${relType.toUpperCase().replace(/[^A-Z_]/g, "_")}]->(b)
         SET r.weight = $weight, r.created_at = datetime()`,
        { src: sourceId, dst: targetId, weight }
      );
    } finally {
      await session.close();
    }
  },

  async neighbors(entityId: string, hops: number = 1): Promise<any[]> {
    const session = getSession();
    try {
      const result = await session.run(
        `MATCH (start:Entity {id: $id})-[r*1..${Math.min(hops, 3)}]-(neighbor:Entity)
         WHERE neighbor.id <> $id
         RETURN DISTINCT neighbor.id as id, neighbor.type as type, neighbor.name as name,
                substring(neighbor.content, 0, 150) as preview,
                neighbor.decay_score as decay,
                length(shortestPath((start)-[*]-(neighbor))) as distance
         ORDER BY distance, neighbor.decay_score DESC
         LIMIT 20`,
        { id: entityId }
      );
      return result.records.map((r) => ({
        id: r.get("id"),
        type: r.get("type"),
        name: r.get("name"),
        preview: r.get("preview"),
        decay: r.get("decay"),
        distance: typeof r.get("distance") === "object" ? r.get("distance").toNumber() : r.get("distance"),
      }));
    } finally {
      await session.close();
    }
  },

  async contextLoad(budget: number = 4000, focusQuery?: string): Promise<{ entities: any[]; tokens: number }> {
    const session = getSession();
    try {
      let cypher: string;
      let params: any = {};

      if (focusQuery) {
        cypher = `
          CALL db.index.fulltext.queryNodes('entity_search', $query) YIELD node, score
          WITH node, score * node.decay_score * (1 + log(1 + node.access_count)) as relevance
          WHERE node.decay_score > 0.05
          RETURN node.id as id, node.type as type, node.name as name, node.content as content,
                 node.tags as tags, relevance, size(node.content) / 4 as est_tokens
          ORDER BY relevance DESC LIMIT 50`;
        params = { query: focusQuery };
      } else {
        cypher = `
          MATCH (e:Entity)
          WHERE e.decay_score > 0.05
          WITH e, e.decay_score * (1 + log(1 + e.access_count)) *
               (1.0 / (1.0 + duration.between(e.last_accessed, datetime()).seconds / 86400.0)) as relevance
          RETURN e.id as id, e.type as type, e.name as name, e.content as content,
                 e.tags as tags, relevance, size(e.content) / 4 as est_tokens
          ORDER BY relevance DESC LIMIT 50`;
      }

      const result = await session.run(cypher, params);
      const entities: any[] = [];
      let totalTokens = 0;

      for (const rec of result.records) {
        const tokens = typeof rec.get("est_tokens") === "object" ? rec.get("est_tokens").toNumber() : rec.get("est_tokens");
        if (totalTokens + tokens > budget) continue;
        totalTokens += tokens;
        entities.push({
          id: rec.get("id"),
          type: rec.get("type"),
          name: rec.get("name"),
          content: rec.get("content"),
          tags: rec.get("tags"),
        });
      }

      return { entities, tokens: totalTokens };
    } finally {
      await session.close();
    }
  },

  async forget(entityId: string): Promise<void> {
    const session = getSession();
    try {
      await session.run(`MATCH (e:Entity {id: $id}) DETACH DELETE e`, { id: entityId });
    } finally {
      await session.close();
    }
  },

  async stats(): Promise<any> {
    const session = getSession();
    try {
      const entities = await session.run(`MATCH (e:Entity) RETURN count(e) as n`);
      const relations = await session.run(`MATCH ()-[r]->() RETURN count(r) as n`);
      const byType = await session.run(`MATCH (e:Entity) RETURN e.type as type, count(e) as n ORDER BY n DESC`);
      const avgDecay = await session.run(`MATCH (e:Entity) RETURN avg(e.decay_score) as avg`);

      return {
        entities: entities.records[0].get("n").toNumber(),
        relations: relations.records[0].get("n").toNumber(),
        avg_decay: avgDecay.records[0].get("avg"),
        by_type: byType.records.map((r) => ({
          type: r.get("type"),
          count: r.get("n").toNumber(),
        })),
      };
    } finally {
      await session.close();
    }
  },

  async decay(): Promise<void> {
    const session = getSession();
    try {
      await session.run(`
        MATCH (e:Entity)
        WHERE e.type IN ['system', 'core']
        SET e.decay_score = CASE WHEN e.decay_score < 0.5 THEN 0.5 ELSE e.decay_score END
      `);
      await session.run(`
        MATCH (e:Entity)
        WHERE NOT e.type IN ['system', 'core', 'user_pref']
          AND e.last_accessed < datetime() - duration('P1D')
        SET e.decay_score = e.decay_score * 0.95
      `);
    } finally {
      await session.close();
    }
  },
};

export async function closeNeo4j(): Promise<void> {
  if (driver) await driver.close();
}
