-- AgentOS-CC Migration 002: Secrets table
-- Idempotent — safe to re-run

CREATE TABLE IF NOT EXISTS cc_secrets (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL,
  description TEXT DEFAULT '',
  updated_at TIMESTAMPTZ DEFAULT now()
);

ALTER TABLE cc_secrets ENABLE ROW LEVEL SECURITY;

-- service_role only — NO anon access (secrets must never be readable via ANON_KEY)
DROP POLICY IF EXISTS service_role_all ON cc_secrets;
CREATE POLICY service_role_all ON cc_secrets FOR ALL TO service_role USING (true) WITH CHECK (true);

GRANT ALL ON cc_secrets TO service_role;
