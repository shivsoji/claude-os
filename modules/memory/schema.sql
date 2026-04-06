-- Claude-OS Memory Graph Schema
-- SQLite with FTS5 for full-text search
-- Graph modeled as entities + relations tables

PRAGMA journal_mode = WAL;
PRAGMA foreign_keys = ON;

-- ============================================
-- Core entity table — nodes in the graph
-- ============================================
CREATE TABLE IF NOT EXISTS entities (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    type          TEXT NOT NULL,          -- system, user_pref, tool_knowledge, task_pattern, skill, fact, episode, goal
    name          TEXT NOT NULL,          -- short identifier
    content       TEXT NOT NULL,          -- full content
    tags          TEXT DEFAULT '',        -- comma-separated tags for fast filtering
    created_at    DATETIME DEFAULT (datetime('now')),
    last_accessed DATETIME DEFAULT (datetime('now')),
    access_count  INTEGER DEFAULT 0,
    decay_score   REAL DEFAULT 1.0,      -- 1.0 = fresh, decays toward 0
    session_id    TEXT DEFAULT NULL,      -- which session created this
    metadata      TEXT DEFAULT '{}'       -- JSON blob for extensible metadata
);

CREATE INDEX IF NOT EXISTS idx_entities_type ON entities(type);
CREATE INDEX IF NOT EXISTS idx_entities_decay ON entities(decay_score);
CREATE INDEX IF NOT EXISTS idx_entities_accessed ON entities(last_accessed);
CREATE INDEX IF NOT EXISTS idx_entities_tags ON entities(tags);

-- ============================================
-- Relations table — edges in the graph
-- ============================================
CREATE TABLE IF NOT EXISTS relations (
    id       INTEGER PRIMARY KEY AUTOINCREMENT,
    src_id   INTEGER NOT NULL REFERENCES entities(id) ON DELETE CASCADE,
    dst_id   INTEGER NOT NULL REFERENCES entities(id) ON DELETE CASCADE,
    rel_type TEXT NOT NULL,              -- related_to, requires, part_of, supersedes, triggers, caused_by, learned_from
    weight   REAL DEFAULT 1.0,          -- edge weight (0-1)
    created_at DATETIME DEFAULT (datetime('now')),
    metadata TEXT DEFAULT '{}',
    UNIQUE(src_id, dst_id, rel_type)
);

CREATE INDEX IF NOT EXISTS idx_relations_src ON relations(src_id);
CREATE INDEX IF NOT EXISTS idx_relations_dst ON relations(dst_id);
CREATE INDEX IF NOT EXISTS idx_relations_type ON relations(rel_type);

-- ============================================
-- Context windows — tracks what's loaded per session
-- ============================================
CREATE TABLE IF NOT EXISTS context_windows (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id  TEXT NOT NULL,
    entity_id   INTEGER NOT NULL REFERENCES entities(id) ON DELETE CASCADE,
    relevance   REAL NOT NULL,           -- computed relevance score
    inserted_at DATETIME DEFAULT (datetime('now')),
    token_cost  INTEGER DEFAULT 0,       -- estimated tokens this entity costs
    UNIQUE(session_id, entity_id)
);

CREATE INDEX IF NOT EXISTS idx_context_session ON context_windows(session_id);

-- ============================================
-- Summaries — compressed versions of entities
-- ============================================
CREATE TABLE IF NOT EXISTS summaries (
    id        INTEGER PRIMARY KEY AUTOINCREMENT,
    entity_id INTEGER NOT NULL REFERENCES entities(id) ON DELETE CASCADE,
    level     INTEGER NOT NULL DEFAULT 1, -- 1=brief, 2=compressed, 3=keyword-only
    summary   TEXT NOT NULL,
    created_at DATETIME DEFAULT (datetime('now')),
    UNIQUE(entity_id, level)
);

-- ============================================
-- Sessions — tracks interaction sessions
-- ============================================
CREATE TABLE IF NOT EXISTS sessions (
    id         TEXT PRIMARY KEY,          -- session identifier
    agent_type TEXT NOT NULL,             -- shell, master, cron, task
    started_at DATETIME DEFAULT (datetime('now')),
    ended_at   DATETIME,
    summary    TEXT,
    entities_created INTEGER DEFAULT 0,
    entities_accessed INTEGER DEFAULT 0
);

-- ============================================
-- Full-text search index (FTS5)
-- ============================================
CREATE VIRTUAL TABLE IF NOT EXISTS entities_fts USING fts5(
    name,
    content,
    tags,
    content=entities,
    content_rowid=id,
    tokenize='porter unicode61'           -- stemming + unicode support
);

-- Triggers to keep FTS in sync
CREATE TRIGGER IF NOT EXISTS entities_fts_insert AFTER INSERT ON entities BEGIN
    INSERT INTO entities_fts(rowid, name, content, tags)
    VALUES (new.id, new.name, new.content, new.tags);
END;

CREATE TRIGGER IF NOT EXISTS entities_fts_update AFTER UPDATE OF name, content, tags ON entities BEGIN
    INSERT INTO entities_fts(entities_fts, rowid, name, content, tags)
    VALUES ('delete', old.id, old.name, old.content, old.tags);
    INSERT INTO entities_fts(rowid, name, content, tags)
    VALUES (new.id, new.name, new.content, new.tags);
END;

CREATE TRIGGER IF NOT EXISTS entities_fts_delete AFTER DELETE ON entities BEGIN
    INSERT INTO entities_fts(entities_fts, rowid, name, content, tags)
    VALUES ('delete', old.id, old.name, old.content, old.tags);
END;

-- ============================================
-- Embeddings — vector storage for semantic search
-- ============================================
CREATE TABLE IF NOT EXISTS embeddings (
    entity_id INTEGER PRIMARY KEY REFERENCES entities(id) ON DELETE CASCADE,
    vector    BLOB NOT NULL,       -- float32 array stored as blob
    model     TEXT DEFAULT 'nomic-embed-text',
    dims      INTEGER DEFAULT 768, -- nomic-embed-text dimension
    created_at DATETIME DEFAULT (datetime('now'))
);

-- ============================================
-- Importance scores — topology-aware decay input
-- ============================================
-- Materialized by the intelligent decay process, not a live view
-- (computing graph centrality on every query would be too slow)
CREATE TABLE IF NOT EXISTS importance (
    entity_id  INTEGER PRIMARY KEY REFERENCES entities(id) ON DELETE CASCADE,
    connection_count INTEGER DEFAULT 0,   -- total edges
    in_degree        INTEGER DEFAULT 0,   -- edges pointing to this entity
    out_degree       INTEGER DEFAULT 0,   -- edges from this entity
    hub_score        REAL DEFAULT 0.0,    -- is this a hub? (many outgoing)
    authority_score  REAL DEFAULT 0.0,    -- is this authoritative? (many incoming)
    importance       REAL DEFAULT 0.5,    -- composite importance 0-1
    computed_at      DATETIME DEFAULT (datetime('now'))
);

-- ============================================
-- Views for common queries
-- ============================================

-- Relevance-scored entities with topology-aware importance
CREATE VIEW IF NOT EXISTS v_relevant_entities AS
SELECT
    e.id,
    e.type,
    e.name,
    e.content,
    e.tags,
    e.access_count,
    e.decay_score,
    COALESCE(imp.importance, 0.5) as importance,
    -- Relevance = decay * frequency * recency * importance * connections
    (
        e.decay_score *
        (1.0 + ln(1 + e.access_count)) *
        (1.0 / (1.0 + (julianday('now') - julianday(e.last_accessed)))) *
        (0.5 + COALESCE(imp.importance, 0.5)) *
        (1.0 + (SELECT COUNT(*) FROM relations WHERE src_id = e.id OR dst_id = e.id) * 0.1)
    ) AS relevance_score
FROM entities e
LEFT JOIN importance imp ON imp.entity_id = e.id
ORDER BY relevance_score DESC;
