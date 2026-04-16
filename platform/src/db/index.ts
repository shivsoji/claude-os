import { createClient, type SupabaseClient } from "@supabase/supabase-js";
import * as crypto from "crypto";
import * as fs from "fs";
import * as path from "path";

const STATE_DIR = process.env.CLAUDE_OS_STATE || "/var/lib/claude-os";
const SUPABASE_URL = process.env.SUPABASE_URL || "http://supabase-kong:8000";
const SUPABASE_SERVICE_KEY = process.env.SUPABASE_SERVICE_KEY || "";

// Use service_role key for full access (server-side only)
export const supabase: SupabaseClient = createClient(SUPABASE_URL, SUPABASE_SERVICE_KEY, {
  auth: { persistSession: false, autoRefreshToken: false },
});

// ID generation
export function genId(prefix: string): string {
  return `${prefix}_${crypto.randomBytes(12).toString("hex")}`;
}

// Ensure a default API token exists
export async function ensureDefaultToken(): Promise<string> {
  const { data } = await supabase
    .from("api_tokens")
    .select("token")
    .eq("name", "default")
    .limit(1)
    .single();

  if (data?.token) return data.token;

  const token = `cos_${crypto.randomBytes(24).toString("hex")}`;
  await supabase.from("api_tokens").insert({
    token,
    name: "default",
    scopes: ["*"],
  });

  // Write to file for CLI access
  const tokenDir = path.join(STATE_DIR, "platform");
  fs.mkdirSync(tokenDir, { recursive: true });
  fs.writeFileSync(path.join(tokenDir, "api-token"), token, { mode: 0o600 });

  return token;
}

// Auth check
export async function validateToken(token: string): Promise<boolean> {
  const { data } = await supabase
    .from("api_tokens")
    .select("token")
    .eq("token", token)
    .limit(1)
    .single();

  if (data) {
    await supabase
      .from("api_tokens")
      .update({ last_used: new Date().toISOString() })
      .eq("token", token);
  }
  return !!data;
}

// Wait for Supabase to be ready
export async function waitForDb(maxRetries = 30): Promise<void> {
  for (let i = 0; i < maxRetries; i++) {
    try {
      const { error } = await supabase.from("session_limits").select("key").limit(1);
      if (!error) {
        console.log("Supabase connected");
        return;
      }
      console.log(`Waiting for Supabase... (${i + 1}/${maxRetries}): ${error.message}`);
    } catch (e) {
      console.log(`Waiting for Supabase... (${i + 1}/${maxRetries})`);
    }
    await new Promise((r) => setTimeout(r, 2000));
  }
  throw new Error("Could not connect to Supabase");
}
