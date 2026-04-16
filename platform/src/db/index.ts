import pg from "pg";
import * as crypto from "crypto";
import * as fs from "fs";
import * as path from "path";

const STATE_DIR = process.env.CLAUDE_OS_STATE || "/var/lib/claude-os";
const DB_URL = process.env.SUPABASE_DB_URL || "";

let pool: pg.Pool | null = null;

export function getPool(): pg.Pool | null {
  return pool;
}

// Initialize Postgres connection
export async function initDb(maxRetries = 10): Promise<void> {
  if (!DB_URL) throw new Error("SUPABASE_DB_URL not set");

  pool = new pg.Pool({ connectionString: DB_URL, max: 10 });

  for (let i = 0; i < maxRetries; i++) {
    try {
      const client = await pool.connect();
      await client.query("SELECT 1");
      client.release();
      console.log("Postgres connected");
      return;
    } catch (e: any) {
      console.log(`Waiting for Postgres... (${i + 1}/${maxRetries}): ${e.message?.slice(0, 80)}`);
      await new Promise((r) => setTimeout(r, 2000));
    }
  }
  throw new Error("Could not connect to Postgres");
}

// Simple query helper
export async function query(sql: string, params: any[] = []): Promise<any[]> {
  if (!pool) return [];
  const result = await pool.query(sql, params);
  return result.rows;
}

export async function queryOne(sql: string, params: any[] = []): Promise<any | null> {
  const rows = await query(sql, params);
  return rows[0] || null;
}

export async function exec(sql: string, params: any[] = []): Promise<void> {
  if (!pool) return;
  await pool.query(sql, params);
}

// ID generation
export function genId(prefix: string): string {
  return `${prefix}_${crypto.randomBytes(12).toString("hex")}`;
}

// Ensure a default API token exists
export async function ensureDefaultToken(): Promise<string> {
  const row = await queryOne("SELECT token FROM api_tokens WHERE name = $1 LIMIT 1", ["default"]);
  if (row) return row.token;

  const token = `cos_${crypto.randomBytes(24).toString("hex")}`;
  await exec("INSERT INTO api_tokens (token, name, scopes) VALUES ($1, $2, $3)", [token, "default", JSON.stringify(["*"])]);

  const tokenFile = path.join(STATE_DIR, "platform", "api-token");
  fs.mkdirSync(path.dirname(tokenFile), { recursive: true });
  fs.writeFileSync(tokenFile, token, { mode: 0o600 });

  return token;
}

// Auth check
export async function validateToken(token: string): Promise<boolean> {
  const row = await queryOne("SELECT token FROM api_tokens WHERE token = $1", [token]);
  if (row) {
    await exec("UPDATE api_tokens SET last_used = NOW() WHERE token = $1", [token]);
  }
  return !!row;
}

export async function closeDb(): Promise<void> {
  if (pool) await pool.end();
}
