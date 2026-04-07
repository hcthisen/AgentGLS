-- AgentOS-CC: Initial Database Schema
-- Idempotent — safe to re-run

-- ============================================================
-- 1. PostgREST Roles
-- ============================================================

DO $$ BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'anon') THEN
    CREATE ROLE anon NOLOGIN;
  END IF;
END $$;

DO $$ BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'service_role') THEN
    CREATE ROLE service_role NOLOGIN;
  END IF;
END $$;

DO $$ BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'authenticator') THEN
    CREATE ROLE authenticator NOINHERIT LOGIN PASSWORD 'AUTHENTICATOR_PASSWORD_PLACEHOLDER';
  END IF;
END $$;

GRANT anon TO authenticator;
GRANT service_role TO authenticator;

-- ============================================================
-- 2. Core Memory Tables
-- ============================================================

CREATE TABLE IF NOT EXISTS cc_sessions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  session_date TIMESTAMPTZ DEFAULT now(),
  project TEXT,
  summary TEXT,
  detail_summary TEXT,
  content TEXT DEFAULT '',
  tags TEXT[] DEFAULT ARRAY[]::TEXT[],
  created_at TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE IF NOT EXISTS cc_memory (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  type TEXT NOT NULL,
  topic TEXT NOT NULL,
  content TEXT NOT NULL,
  tags TEXT[] DEFAULT ARRAY[]::TEXT[],
  project TEXT,
  updated_at TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE IF NOT EXISTS cc_projects (
  name TEXT PRIMARY KEY,
  description TEXT,
  tech_stack TEXT[] DEFAULT ARRAY[]::TEXT[],
  status TEXT DEFAULT 'active'
);

CREATE TABLE IF NOT EXISTS cc_user_profile (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  category TEXT NOT NULL,
  key TEXT NOT NULL,
  value TEXT NOT NULL,
  UNIQUE(category, key)
);

-- ============================================================
-- 3. Security Tables
-- ============================================================

CREATE TABLE IF NOT EXISTS cc_security_bans (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  ip TEXT NOT NULL UNIQUE,
  jail TEXT DEFAULT 'sshd',
  country TEXT,
  country_code TEXT,
  banned_at TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE IF NOT EXISTS cc_security_logins (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_name TEXT,
  ip TEXT,
  login_at TEXT,
  session_type TEXT,
  duration TEXT
);

CREATE TABLE IF NOT EXISTS cc_security_stats (
  id INTEGER PRIMARY KEY,
  total_banned INTEGER DEFAULT 0,
  total_failed INTEGER DEFAULT 0,
  total_logins INTEGER DEFAULT 0,
  last_updated TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE IF NOT EXISTS cc_server_health (
  id INTEGER PRIMARY KEY,
  uptime TEXT,
  cpu_percent FLOAT,
  ram_used_mb INTEGER,
  ram_total_mb INTEGER,
  disk_used_gb FLOAT,
  disk_total_gb FLOAT,
  load_avg TEXT,
  active_connections INTEGER,
  docker_containers JSONB,
  services JSONB,
  claude_status JSONB,
  open_ports JSONB,
  top_attackers JSONB,
  failed_per_day JSONB,
  system_overview JSONB,
  last_updated TIMESTAMPTZ DEFAULT now()
);

-- ============================================================
-- 4. Indexes
-- ============================================================

CREATE INDEX IF NOT EXISTS idx_sessions_date ON cc_sessions(session_date DESC);
CREATE INDEX IF NOT EXISTS idx_memory_type ON cc_memory(type);
CREATE INDEX IF NOT EXISTS idx_bans_ip ON cc_security_bans(ip);

-- ============================================================
-- 5. Seed Rows
-- ============================================================

INSERT INTO cc_server_health (id) VALUES (1) ON CONFLICT DO NOTHING;
INSERT INTO cc_security_stats (id, total_banned, total_failed, total_logins)
  VALUES (1, 0, 0, 0) ON CONFLICT DO NOTHING;

-- ============================================================
-- 6. Grants
-- ============================================================

GRANT USAGE ON SCHEMA public TO anon;
GRANT USAGE ON SCHEMA public TO service_role;

GRANT SELECT ON ALL TABLES IN SCHEMA public TO anon;
GRANT ALL ON ALL TABLES IN SCHEMA public TO service_role;

-- Apply to future tables too
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO anon;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO service_role;

-- ============================================================
-- 7. Row Level Security
-- ============================================================

ALTER TABLE cc_sessions ENABLE ROW LEVEL SECURITY;
ALTER TABLE cc_memory ENABLE ROW LEVEL SECURITY;
ALTER TABLE cc_projects ENABLE ROW LEVEL SECURITY;
ALTER TABLE cc_user_profile ENABLE ROW LEVEL SECURITY;
ALTER TABLE cc_security_bans ENABLE ROW LEVEL SECURITY;
ALTER TABLE cc_security_logins ENABLE ROW LEVEL SECURITY;
ALTER TABLE cc_security_stats ENABLE ROW LEVEL SECURITY;
ALTER TABLE cc_server_health ENABLE ROW LEVEL SECURITY;

-- anon: read-only
DO $$ DECLARE t TEXT; BEGIN
  FOREACH t IN ARRAY ARRAY['cc_sessions','cc_memory','cc_projects','cc_user_profile',
    'cc_security_bans','cc_security_logins','cc_security_stats','cc_server_health']
  LOOP
    EXECUTE format('DROP POLICY IF EXISTS anon_read ON %I', t);
    EXECUTE format('CREATE POLICY anon_read ON %I FOR SELECT TO anon USING (true)', t);
  END LOOP;
END $$;

-- service_role: full access
DO $$ DECLARE t TEXT; BEGIN
  FOREACH t IN ARRAY ARRAY['cc_sessions','cc_memory','cc_projects','cc_user_profile',
    'cc_security_bans','cc_security_logins','cc_security_stats','cc_server_health']
  LOOP
    EXECUTE format('DROP POLICY IF EXISTS service_role_all ON %I', t);
    EXECUTE format('CREATE POLICY service_role_all ON %I FOR ALL TO service_role USING (true) WITH CHECK (true)', t);
  END LOOP;
END $$;
