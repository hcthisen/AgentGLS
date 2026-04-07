-- AgentGLS GoalLoop projection
-- Idempotent: safe to re-run on existing deployments.

CREATE TABLE IF NOT EXISTS cc_goals (
  slug TEXT PRIMARY KEY
);

ALTER TABLE cc_goals
  ADD COLUMN IF NOT EXISTS title TEXT,
  ADD COLUMN IF NOT EXISTS status TEXT NOT NULL DEFAULT 'active',
  ADD COLUMN IF NOT EXISTS priority TEXT NOT NULL DEFAULT 'medium',
  ADD COLUMN IF NOT EXISTS brief_status TEXT NOT NULL DEFAULT 'draft',
  ADD COLUMN IF NOT EXISTS run_state TEXT DEFAULT 'idle',
  ADD COLUMN IF NOT EXISTS objective TEXT,
  ADD COLUMN IF NOT EXISTS finish_criteria JSONB NOT NULL DEFAULT '[]'::jsonb,
  ADD COLUMN IF NOT EXISTS scoreboard JSONB NOT NULL DEFAULT '{}'::jsonb,
  ADD COLUMN IF NOT EXISTS heartbeat_minutes INTEGER NOT NULL DEFAULT 60,
  ADD COLUMN IF NOT EXISTS last_run TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS next_eligible_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS measurement_due_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS deadline_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS approval_policy TEXT NOT NULL DEFAULT 'auto',
  ADD COLUMN IF NOT EXISTS parent TEXT,
  ADD COLUMN IF NOT EXISTS notify_chat_id TEXT,
  ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ NOT NULL DEFAULT now();

UPDATE cc_goals
SET title = COALESCE(NULLIF(title, ''), slug)
WHERE title IS NULL OR title = '';

CREATE INDEX IF NOT EXISTS idx_goals_status ON cc_goals(status);
CREATE INDEX IF NOT EXISTS idx_goals_parent ON cc_goals(parent);
CREATE INDEX IF NOT EXISTS idx_goals_updated_at ON cc_goals(updated_at DESC);

ALTER TABLE cc_goals ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS anon_read ON cc_goals;
CREATE POLICY anon_read ON cc_goals FOR SELECT TO anon USING (true);

DROP POLICY IF EXISTS service_role_all ON cc_goals;
CREATE POLICY service_role_all ON cc_goals FOR ALL TO service_role USING (true) WITH CHECK (true);

GRANT SELECT ON cc_goals TO anon;
GRANT ALL ON cc_goals TO service_role;
