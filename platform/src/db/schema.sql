-- Claude-OS Platform Database
-- Operational state for agents, sessions, events
-- Separate from memory graph (knowledge vs operations)

PRAGMA journal_mode = WAL;
PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS agents (
    id          TEXT PRIMARY KEY,
    version     INTEGER NOT NULL DEFAULT 1,
    name        TEXT NOT NULL,
    description TEXT DEFAULT '',
    system_prompt TEXT DEFAULT '',
    model_provider TEXT NOT NULL DEFAULT 'ollama',  -- ollama | claude
    model_id    TEXT NOT NULL DEFAULT 'gemma4:31b-cloud',
    model_fallback TEXT DEFAULT 'ollama',
    tools       TEXT DEFAULT '[]',       -- JSON array of tool configs
    skills      TEXT DEFAULT '[]',       -- JSON array of skill names
    composition TEXT DEFAULT NULL,       -- link to claude-os-compose name
    packages    TEXT DEFAULT '[]',       -- JSON array of nix packages
    env_vars    TEXT DEFAULT '{}',       -- JSON object of env vars
    max_turns   INTEGER DEFAULT 50,
    max_tokens  INTEGER DEFAULT 16384,
    created_at  DATETIME DEFAULT (datetime('now')),
    updated_at  DATETIME DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS agent_versions (
    agent_id    TEXT NOT NULL REFERENCES agents(id) ON DELETE CASCADE,
    version     INTEGER NOT NULL,
    snapshot    TEXT NOT NULL,           -- full JSON snapshot
    created_at  DATETIME DEFAULT (datetime('now')),
    PRIMARY KEY (agent_id, version)
);

CREATE TABLE IF NOT EXISTS sessions (
    id          TEXT PRIMARY KEY,
    agent_id    TEXT NOT NULL REFERENCES agents(id),
    agent_version INTEGER NOT NULL,
    agent_snapshot TEXT NOT NULL,         -- frozen agent config JSON
    title       TEXT DEFAULT 'Untitled',
    status      TEXT NOT NULL DEFAULT 'idle', -- idle | running | requires_action | archived
    metadata    TEXT DEFAULT '{}',
    resources   TEXT DEFAULT '[]',       -- JSON array of mounted resources
    usage_input_tokens  INTEGER DEFAULT 0,
    usage_output_tokens INTEGER DEFAULT 0,
    usage_ollama_calls  INTEGER DEFAULT 0,
    usage_claude_calls  INTEGER DEFAULT 0,
    turns       INTEGER DEFAULT 0,
    tools_used  INTEGER DEFAULT 0,
    systemd_unit TEXT DEFAULT NULL,       -- systemd-run unit name for isolation
    pid         INTEGER DEFAULT NULL,
    created_at  DATETIME DEFAULT (datetime('now')),
    updated_at  DATETIME DEFAULT (datetime('now')),
    archived_at DATETIME DEFAULT NULL
);

CREATE INDEX IF NOT EXISTS idx_sessions_agent ON sessions(agent_id);
CREATE INDEX IF NOT EXISTS idx_sessions_status ON sessions(status);

CREATE TABLE IF NOT EXISTS events (
    id          TEXT PRIMARY KEY,
    session_id  TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
    type        TEXT NOT NULL,           -- message | tool_call | tool_result | status
    role        TEXT NOT NULL,           -- user | agent | system
    content     TEXT NOT NULL,           -- JSON payload
    processed_at DATETIME DEFAULT (datetime('now'))
);

CREATE INDEX IF NOT EXISTS idx_events_session ON events(session_id, processed_at);

CREATE TABLE IF NOT EXISTS api_tokens (
    token       TEXT PRIMARY KEY,
    name        TEXT NOT NULL,
    scopes      TEXT DEFAULT '["*"]',    -- JSON array: ["*"] | ["agents:read","sessions:write",...]
    created_at  DATETIME DEFAULT (datetime('now')),
    last_used   DATETIME DEFAULT NULL,
    expires_at  DATETIME DEFAULT NULL
);

-- Lifecycle management
CREATE TABLE IF NOT EXISTS session_limits (
    key         TEXT PRIMARY KEY,
    value       TEXT NOT NULL
);

INSERT OR IGNORE INTO session_limits VALUES ('max_concurrent', '10');
INSERT OR IGNORE INTO session_limits VALUES ('session_ttl_hours', '24');
INSERT OR IGNORE INTO session_limits VALUES ('event_retention_days', '7');
INSERT OR IGNORE INTO session_limits VALUES ('max_disk_per_session_mb', '1000');
