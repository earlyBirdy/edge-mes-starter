-- ===============================================
-- Real OEE wiring: shift calendar + views
-- Shifts (Asia/Bangkok): Night 00:00–08:00, Day 08:00–16:00, Evening 16:00–00:00
-- ===============================================

-- Optional: extend op_run with plan & counters if columns are missing
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                 WHERE table_name='op_run' AND column_name='planned_seconds') THEN
    ALTER TABLE op_run ADD COLUMN planned_seconds integer; -- planned run time in seconds for this run
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                 WHERE table_name='op_run' AND column_name='ideal_cycle_time_s') THEN
    ALTER TABLE op_run ADD COLUMN ideal_cycle_time_s numeric; -- ideal sec/unit
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                 WHERE table_name='op_run' AND column_name='good_units') THEN
    ALTER TABLE op_run ADD COLUMN good_units integer; -- produced good units in run
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                 WHERE table_name='op_run' AND column_name='total_units') THEN
    ALTER TABLE op_run ADD COLUMN total_units integer; -- total units (good + scrap)
  END IF;
END$$;

-- Helper: shift calendar per timestamp (using Asia/Bangkok)
CREATE OR REPLACE FUNCTION shift_of(ts_in timestamptz)
RETURNS TABLE(shift_name text, shift_start timestamptz, shift_end timestamptz)
LANGUAGE sql STABLE AS $$
  WITH tz AS (
    SELECT (ts_in AT TIME ZONE 'Asia/Bangkok') AS ts_local
  ),
  base AS (
    SELECT date_trunc('day', ts_local) AS d, ts_local FROM tz
  ),
  shifts AS (
    SELECT d + TIME '00:00' AS night_start, d + TIME '08:00' AS day_start, d + TIME '16:00' AS eve_start FROM base
  ),
  pick AS (
    SELECT ts_local,
           CASE
             WHEN ts_local >= night_start AND ts_local < day_start THEN 'Night'
             WHEN ts_local >= day_start  AND ts_local < eve_start THEN 'Day'
             ELSE 'Evening'
           END AS shift_name,
           CASE
             WHEN ts_local >= night_start AND ts_local < day_start THEN night_start
             WHEN ts_local >= day_start  AND ts_local < eve_start THEN day_start
             ELSE eve_start
           END AS local_shift_start
    FROM base JOIN shifts USING (d)
  )
  SELECT shift_name,
         (local_shift_start AT TIME ZONE 'Asia/Bangkok') AT TIME ZONE 'UTC' AS shift_start,
         ((local_shift_start + INTERVAL '8 hour') AT TIME ZONE 'Asia/Bangkok') AT TIME ZONE 'UTC' AS shift_end
  FROM pick;
$$;

-- Quality per shift using readings:
-- Prefer yield (%) if present; else derive 1 - defect_rate (%)
CREATE OR REPLACE VIEW v_quality_per_shift AS
WITH r AS (
  SELECT *,
         (shift_of(ts)).shift_name AS shift_name,
         (shift_of(ts)).shift_start AS shift_start,
         (shift_of(ts)).shift_end   AS shift_end
  FROM readings
),
y AS (
  SELECT resource_id, shift_name, shift_start, shift_end,
         avg(CASE WHEN sensor='yield' THEN value END) AS avg_yield,
         avg(CASE WHEN sensor='defect_rate' THEN value END) AS avg_defect_rate
  FROM r
  GROUP BY 1,2,3,4
)
SELECT resource_id, shift_name, shift_start, shift_end,
       COALESCE(avg_yield/100.0, 1.0 - COALESCE(avg_defect_rate,0)/100.0) AS quality -- 0..1
FROM y;

-- Availability & Performance per shift using op_run:
-- Availability = runtime / planned_time
-- Performance = actual_output / ideal_output  (ideal_output = runtime / ideal_cycle_time_s)
CREATE OR REPLACE VIEW v_runtime_per_shift AS
WITH grid AS (
  -- build rows for op_runs exploded by overlapping shift windows
  SELECT op.op_run_id, op.resource_id, op.started_ts, COALESCE(op.ended_ts, now()) AS ended_ts,
         op.planned_seconds, op.ideal_cycle_time_s, op.good_units, op.total_units
  FROM op_run op
),
exp AS (
  SELECT g.*, (shift_of(g.started_ts)).shift_start AS s_start_0
  FROM grid g
),
norm AS (
  -- For each run, generate one row per shift boundary it overlaps (8h buckets).
  SELECT e.*, generate_series(0, 100) AS k  -- cap at 100*8h just in case
  FROM exp e
  WHERE e.started_ts < e.ended_ts
),
buckets AS (
  SELECT
    op_run_id, resource_id, planned_seconds, ideal_cycle_time_s, good_units, total_units,
    -- Start of the kth shift since the run's start
    (s_start_0 + (k * INTERVAL '8 hour')) AS shift_start_k,
    (s_start_0 + ((k+1) * INTERVAL '8 hour')) AS shift_end_k,
    started_ts, ended_ts
  FROM norm
),
overlp AS (
  SELECT resource_id,
         greatest(started_ts, shift_start_k) AS seg_start,
         least(ended_ts, shift_end_k)       AS seg_end,
         planned_seconds, ideal_cycle_time_s, good_units, total_units
  FROM buckets
  WHERE shift_end_k > started_ts AND shift_start_k < ended_ts
),
final AS (
  SELECT resource_id,
         seg_start AS shift_start,
         seg_end   AS shift_end,
         EXTRACT(EPOCH FROM (seg_end - seg_start))::numeric AS runtime_seconds,
         planned_seconds, ideal_cycle_time_s, good_units, total_units
  FROM overlp
  WHERE seg_end > seg_start
)
SELECT resource_id,
       (shift_of(shift_start)).shift_name AS shift_name,
       (shift_of(shift_start)).shift_start AS shift_start,
       (shift_of(shift_start)).shift_end   AS shift_end,
       sum(runtime_seconds) AS runtime_seconds,
       max(planned_seconds) AS planned_seconds, -- assume same plan per run/shift
       sum(good_units)      AS good_units,
       sum(total_units)     AS total_units,
       max(ideal_cycle_time_s) AS ideal_cycle_time_s
FROM final
GROUP BY 1,2,3,4;

-- OEE per shift (real)
CREATE OR REPLACE VIEW v_oee_shift_real AS
WITH q AS (
  SELECT * FROM v_quality_per_shift
),
a AS (
  SELECT * FROM v_runtime_per_shift
)
SELECT
  COALESCE(a.resource_id, q.resource_id) AS resource_id,
  COALESCE(a.shift_name, q.shift_name)   AS shift_name,
  COALESCE(a.shift_start, q.shift_start) AS shift_start,
  COALESCE(a.shift_end, q.shift_end)     AS shift_end,
  -- Availability (0..1)
  CASE WHEN a.planned_seconds IS NULL OR a.planned_seconds = 0
       THEN NULL
       ELSE (a.runtime_seconds / a.planned_seconds)
  END AS availability,
  -- Performance (0..1)
  CASE WHEN a.ideal_cycle_time_s IS NULL OR a.ideal_cycle_time_s = 0
       THEN NULL
       ELSE ((COALESCE(a.total_units,0)::numeric) / NULLIF(a.runtime_seconds / a.ideal_cycle_time_s, 0))
  END AS performance,
  -- Quality (0..1)
  q.quality AS quality,
  -- OEE (0..1)
  CASE
    WHEN q.quality IS NULL OR a.ideal_cycle_time_s IS NULL OR a.ideal_cycle_time_s=0
         OR a.planned_seconds IS NULL OR a.planned_seconds=0
    THEN NULL
    ELSE
      LEAST(1.0, GREATEST(0.0, (a.runtime_seconds / a.planned_seconds))) *
      LEAST(1.0, GREATEST(0.0, ((COALESCE(a.total_units,0)::numeric) / NULLIF(a.runtime_seconds / a.ideal_cycle_time_s,0)))) *
      LEAST(1.0, GREATEST(0.0, q.quality))
  END AS oee
FROM a
FULL OUTER JOIN q
  ON a.resource_id=q.resource_id
 AND a.shift_start=q.shift_start
 AND a.shift_end=q.shift_end;
