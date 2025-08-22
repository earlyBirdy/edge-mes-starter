-- Seed op_run for demo OEE
-- One 4-hour run within the last 8 hours on SMT01 / WO123 / OP10
DO $$
DECLARE
  now_utc timestamptz := now();
  start_ts timestamptz := now() - interval '6 hour';
  end_ts   timestamptz := now() - interval '2 hour';
BEGIN
  IF NOT EXISTS (SELECT 1 FROM resource WHERE resource_id='SMT01') THEN
    INSERT INTO resource(resource_id, name, area, type, meta) VALUES ('SMT01','SMT Line 01','BKK','SMT','{{}}'::jsonb);
  END IF;

  IF NOT EXISTS (SELECT 1 FROM work_order WHERE work_order_id='WO123') THEN
    INSERT INTO work_order(work_order_id, product_code, lot_id, qty_planned, status, meta)
    VALUES ('WO123','P-ABC','LOT-001', 1000, 'RUNNING','{{}}'::jsonb);
  END IF;

  IF NOT EXISTS (SELECT 1 FROM operation WHERE operation_id='OP10') THEN
    INSERT INTO operation(operation_id, route_id, step_no, name, spec)
    VALUES ('OP10','R-1',10,'Placement','{{}}'::jsonb);
  END IF;

  -- planned 4 hours = 14400s, ideal 1.5 sec/unit
  -- produced 800 total, 780 good (20 scrap) for demo
  INSERT INTO op_run(work_order_id, operation_id, resource_id, started_ts, ended_ts,
                     status, meta, planned_seconds, ideal_cycle_time_s, good_units, total_units)
  VALUES ('WO123','OP10','SMT01', start_ts, end_ts,
          'COMPLETED','{{}}'::jsonb, 14400, 1.5, 780, 800);
END$$;
