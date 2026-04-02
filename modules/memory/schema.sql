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
-- Views for common queries
-- ============================================

-- Relevance-scored entities for context loading
CREATE VIEW IF NOT EXISTS v_relevant_entities AS
SELECT
    e.id,
    e.type,
    e.name,
    e.content,
    e.tags,
    e.access_count,
    e.decay_score,
    -- Relevance = recency * frequency * decay * connection_density
    (
        e.decay_score *
        (1.0 + ln(1 + e.access_count)) *
        (1.0 / (1.0 + (julianday('now') - julianday(e.last_accessed)))) *
        (1.0 + (SELECT COUNT(*) FROM relations WHERE src_id = e.id OR dst_id = e.id) * 0.1)
    ) AS relevance_score
FROM entities e
ORDER BY relevance_score DESC;

-- Graph neighborhood: entities connected to a given entity
-- Usage: SELECT * FROM v_relevant_entities WHERE id IN (
--          SELECT dst_id FROM relations WHERE src_id = ?
--          UNION SELECT src_id FROM relations WHERE dst_id = ?
--        )
