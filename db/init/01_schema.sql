-- Enable extensions
CREATE EXTENSION IF NOT EXISTS timescaledb;
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- Master data
CREATE TABLE IF NOT EXISTS resource(
  resource_id text PRIMARY KEY,
  name text, area text, type text, meta jsonb
);

CREATE TABLE IF NOT EXISTS work_order(
  work_order_id text PRIMARY KEY,
  product_code text, lot_id text, qty_planned numeric,
  due_ts timestamptz, status text, meta jsonb
);

CREATE TABLE IF NOT EXISTS operation(
  operation_id text PRIMARY KEY,
  route_id text, step_no int, name text, spec jsonb
);

CREATE TABLE IF NOT EXISTS op_run(
  op_run_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  work_order_id text REFERENCES work_order,
  operation_id text REFERENCES operation,
  resource_id  text REFERENCES resource,
  started_ts timestamptz NOT NULL,
  ended_ts timestamptz,
  status text,
  meta jsonb
);

-- Time-series readings
CREATE TABLE IF NOT EXISTS readings(
  ts timestamptz NOT NULL,
  resource_id text REFERENCES resource,
  work_order_id text,
  operation_id text,
  sensor text NOT NULL,
  value double precision,
  unit text,
  quality jsonb,
  meta jsonb
);
SELECT create_hypertable('readings','ts', if_not_exists => TRUE);
CREATE INDEX IF NOT EXISTS idx_readings_main ON readings(resource_id, work_order_id, operation_id, sensor, ts DESC);

-- Views MES can bind to
CREATE OR REPLACE VIEW v_quality_latest AS
SELECT DISTINCT ON (work_order_id, operation_id, sensor)
  work_order_id, operation_id, sensor, value, unit, ts
FROM readings
WHERE sensor IN ('defect_rate','yield')
ORDER BY work_order_id, operation_id, sensor, ts DESC;

CREATE OR REPLACE VIEW v_oee_shift AS
SELECT resource_id,
       date_trunc('hour', ts) AS hour_bucket,
       1.0 AS oee -- placeholder; replace with your calc
FROM readings;
