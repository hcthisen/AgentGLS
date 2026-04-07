-- Add unique constraint on (type, topic) to enable PostgREST upserts
-- Used by memory-consolidate.sh to upsert topic-based consolidated memories
-- Safe on existing deployments: cc_memory table is currently empty

DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'cc_memory_type_topic_unique'
  ) THEN
    ALTER TABLE cc_memory ADD CONSTRAINT cc_memory_type_topic_unique UNIQUE(type, topic);
  END IF;
END $$;
