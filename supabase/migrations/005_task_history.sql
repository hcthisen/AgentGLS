-- AgentOS-CC: Task Execution History
-- Stores results from each scheduled task run for memory and thread awareness

CREATE TABLE IF NOT EXISTS cc_task_history (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  task_id UUID NOT NULL REFERENCES cc_scheduled_tasks(id) ON DELETE CASCADE,
  task_name TEXT,
  result TEXT,
  chat_id TEXT,
  created_at TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_task_history_task ON cc_task_history(task_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_task_history_recent ON cc_task_history(created_at DESC);

-- RLS
ALTER TABLE cc_task_history ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS anon_read ON cc_task_history;
CREATE POLICY anon_read ON cc_task_history FOR SELECT TO anon USING (true);

DROP POLICY IF EXISTS service_role_all ON cc_task_history;
CREATE POLICY service_role_all ON cc_task_history FOR ALL TO service_role USING (true) WITH CHECK (true);

GRANT SELECT ON cc_task_history TO anon;
GRANT ALL ON cc_task_history TO service_role;
