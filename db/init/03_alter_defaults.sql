-- Ensure defaults for counters on op_run
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name='op_run' AND column_name='good_units') THEN
    EXECUTE 'ALTER TABLE op_run ALTER COLUMN good_units SET DEFAULT 0';
  END IF;
  IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name='op_run' AND column_name='total_units') THEN
    EXECUTE 'ALTER TABLE op_run ALTER COLUMN total_units SET DEFAULT 0';
  END IF;
END$$;
