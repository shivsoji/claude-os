-- Claude-OS Platform Schema (Supabase/Postgres)
-- Replaces the SQLite platform.sqlite

-- ============================================
-- Agents — configurable AI agent definitions
-- ============================================
CREATE TABLE IF NOT EXISTS public.agents (
    id          TEXT PRIMARY KEY,
    version     INTEGER NOT NULL DEFAULT 1,
    name        TEXT NOT NULL,
    description TEXT DEFAULT '',
    system_prompt TEXT DEFAULT '',
    model_provider TEXT NOT NULL DEFAULT 'ollama',
    model_id    TEXT NOT NULL DEFAULT 'gemma4:31b-cloud',
    model_fallback TEXT DEFAULT 'ollama',
    tools       JSONB DEFAULT '[]'::jsonb,
    skills      JSONB DEFAULT '[]'::jsonb,
    composition TEXT DEFAULT NULL,
    packages    JSONB DEFAULT '[]'::jsonb,
    env_vars    JSONB DEFAULT '{}'::jsonb,
    max_turns   INTEGER DEFAULT 50,
    max_tokens  INTEGER DEFAULT 16384,
    created_at  TIMESTAMPTZ DEFAULT NOW(),
    updated_at  TIMESTAMPTZ DEFAULT NOW()
);

-- ============================================
-- Agent versions — snapshot history
-- ============================================
CREATE TABLE IF NOT EXISTS public.agent_versions (
    agent_id    TEXT NOT NULL REFERENCES public.agents(id) ON DELETE CASCADE,
    version     INTEGER NOT NULL,
    snapshot    JSONB NOT NULL,
    created_at  TIMESTAMPTZ DEFAULT NOW(),
    PRIMARY KEY (agent_id, version)
);

-- ============================================
-- Sessions — execution contexts
-- ============================================
CREATE TABLE IF NOT EXISTS public.sessions (
    id              TEXT PRIMARY KEY,
    agent_id        TEXT NOT NULL REFERENCES public.agents(id),
    agent_version   INTEGER NOT NULL,
    agent_snapshot  JSONB NOT NULL,
    title           TEXT DEFAULT 'Untitled',
    status          TEXT NOT NULL DEFAULT 'idle',
    metadata        JSONB DEFAULT '{}'::jsonb,
    resources       JSONB DEFAULT '[]'::jsonb,
    usage_input_tokens  INTEGER DEFAULT 0,
    usage_output_tokens INTEGER DEFAULT 0,
    usage_ollama_calls  INTEGER DEFAULT 0,
    usage_claude_calls  INTEGER DEFAULT 0,
    turns           INTEGER DEFAULT 0,
    tools_used      INTEGER DEFAULT 0,
    created_at      TIMESTAMPTZ DEFAULT NOW(),
    updated_at      TIMESTAMPTZ DEFAULT NOW(),
    archived_at     TIMESTAMPTZ DEFAULT NULL
);

CREATE INDEX IF NOT EXISTS idx_sessions_agent ON public.sessions(agent_id);
CREATE INDEX IF NOT EXISTS idx_sessions_status ON public.sessions(status);

-- ============================================
-- Events — message and tool interaction stream
-- ============================================
CREATE TABLE IF NOT EXISTS public.events (
    id          TEXT PRIMARY KEY,
    session_id  TEXT NOT NULL REFERENCES public.sessions(id) ON DELETE CASCADE,
    type        TEXT NOT NULL,       -- message | tool_call | tool_result | status
    role        TEXT NOT NULL,       -- user | agent | system
    content     JSONB NOT NULL,
    processed_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_events_session ON public.events(session_id, processed_at);

-- ============================================
-- API tokens
-- ============================================
CREATE TABLE IF NOT EXISTS public.api_tokens (
    token       TEXT PRIMARY KEY,
    name        TEXT NOT NULL,
    scopes      JSONB DEFAULT '["*"]'::jsonb,
    created_at  TIMESTAMPTZ DEFAULT NOW(),
    last_used   TIMESTAMPTZ DEFAULT NULL,
    expires_at  TIMESTAMPTZ DEFAULT NULL
);

-- ============================================
-- Session limits / config
-- ============================================
CREATE TABLE IF NOT EXISTS public.session_limits (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
);

INSERT INTO public.session_limits (key, value) VALUES
    ('max_concurrent', '10'),
    ('session_ttl_hours', '24'),
    ('event_retention_days', '7'),
    ('max_disk_per_session_mb', '1000')
ON CONFLICT DO NOTHING;

-- ============================================
-- System state (genome, evolution, awareness)
-- ============================================
CREATE TABLE IF NOT EXISTS public.system_state (
    key     TEXT PRIMARY KEY,
    value   JSONB NOT NULL,
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- ============================================
-- Enable Realtime on events table
-- ============================================
ALTER PUBLICATION supabase_realtime ADD TABLE public.events;

-- ============================================
-- Row Level Security (basic policies)
-- ============================================
ALTER TABLE public.agents ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sessions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.events ENABLE ROW LEVEL SECURITY;

-- Allow service_role full access
CREATE POLICY "service_role_all" ON public.agents FOR ALL USING (true);
CREATE POLICY "service_role_all" ON public.sessions FOR ALL USING (true);
CREATE POLICY "service_role_all" ON public.events FOR ALL USING (true);

-- ============================================
-- Auto-update updated_at timestamps
-- ============================================
CREATE OR REPLACE FUNCTION update_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER agents_updated_at BEFORE UPDATE ON public.agents
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();

CREATE TRIGGER sessions_updated_at BEFORE UPDATE ON public.sessions
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();
