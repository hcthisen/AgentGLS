-- AgentOS-CC: Scheduled Tasks Table
-- Allows the agent to create persistent cron jobs stored in Supabase

CREATE TABLE IF NOT EXISTS cc_scheduled_tasks (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name TEXT NOT NULL,
  cron_expr TEXT NOT NULL,
  prompt TEXT NOT NULL,
  chat_id TEXT,
  model TEXT DEFAULT 'opus',
  enabled BOOLEAN DEFAULT true,
  last_run TIMESTAMPTZ,
  last_result TEXT,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_tasks_enabled ON cc_scheduled_tasks(enabled);

-- RLS
ALTER TABLE cc_scheduled_tasks ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS anon_read ON cc_scheduled_tasks;
CREATE POLICY anon_read ON cc_scheduled_tasks FOR SELECT TO anon USING (true);

DROP POLICY IF EXISTS service_role_all ON cc_scheduled_tasks;
CREATE POLICY service_role_all ON cc_scheduled_tasks FOR ALL TO service_role USING (true) WITH CHECK (true);

GRANT SELECT ON cc_scheduled_tasks TO anon;
GRANT ALL ON cc_scheduled_tasks TO service_role;
