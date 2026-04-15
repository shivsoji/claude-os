import { execSync } from "child_process";
import * as fs from "fs";
import * as path from "path";
import * as crypto from "crypto";

const STATE_DIR = process.env.CLAUDE_OS_STATE || "/var/lib/claude-os";
const DB_PATH = path.join(STATE_DIR, "platform", "platform.sqlite");
const SCHEMA_PATH = path.join(import.meta.dirname, "schema.sql");

// Ensure directory exists
fs.mkdirSync(path.dirname(DB_PATH), { recursive: true });

// Initialize schema
execSync(`sqlite3 '${DB_PATH}' < '${SCHEMA_PATH}'`, { encoding: "utf-8" });

// SQLite via CLI — pass SQL through stdin to avoid shell escaping hell
function sqlExec(sql: string): string {
  try {
    return execSync(`sqlite3 '${DB_PATH}'`, {
      input: sql,
      encoding: "utf-8",
      maxBuffer: 10 * 1024 * 1024,
      timeout: 10000,
    }).trim();
  } catch (e: any) {
    console.error(`SQL error: ${e.message?.slice(0, 200)}`);
    return "";
  }
}

function sqlJson(sql: string): any[] {
  try {
    const result = execSync(`sqlite3 -json '${DB_PATH}'`, {
      input: sql,
      encoding: "utf-8",
      maxBuffer: 10 * 1024 * 1024,
      timeout: 10000,
    }).trim();
    return result ? JSON.parse(result) : [];
  } catch {
    return [];
  }
}

function escVal(val: any): string {
  if (val === null || val === undefined) return "NULL";
  if (typeof val === "number") return String(val);
  return `'${String(val).replace(/'/g, "''")}'`;
}

function resolveParams(sql: string, params: any[]): string {
  let i = 0;
  return sql.replace(/\?/g, () => escVal(params[i++]));
}

export const db = {
  exec(sql: string) { sqlExec(sql); },
  run(sql: string, ...params: any[]) { sqlExec(resolveParams(sql, params)); },
  query(sql: string, ...params: any[]): any[] { return sqlJson(resolveParams(sql, params)); },
  get(sql: string, ...params: any[]): any | undefined { return sqlJson(resolveParams(sql, params))[0]; },
};

// ID generation
export function genId(prefix: string): string {
  return `${prefix}_${crypto.randomBytes(12).toString("hex")}`;
}

// Ensure a default API token exists
export function ensureDefaultToken(): string {
  const existing = db.get("SELECT token FROM api_tokens WHERE name = 'default' LIMIT 1");
  if (existing) return existing.token;

  const token = `cos_${crypto.randomBytes(24).toString("hex")}`;
  db.run("INSERT INTO api_tokens (token, name, scopes) VALUES (?, ?, ?)", token, "default", '["*"]');

  const tokenFile = path.join(STATE_DIR, "platform", "api-token");
  fs.writeFileSync(tokenFile, token, { mode: 0o600 });

  return token;
}
