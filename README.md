# Edge → MES Starter

A minimal stack to ingest JSONL hot data into TimescaleDB, visualize live in Grafana, and expose a FastAPI surface that MES/SFC can integrate with.

## Run

```bash
docker compose up --build
```

- API: http://localhost:8000 (health at `/health`)
- Grafana: http://localhost:3000 (admin/admin by default)
- Drop JSONL files into `./hotdata/*.jsonl` to see live charts.

A sample stream is included at `hotdata/sample_readings.jsonl` (10 minutes of `temp`, `speed`, `defect_rate`, `yield` for `resource_id=SMT01`).

## JSONL line format (example)
```json
{"ts":"2025-08-22T00:37:41Z","resource_id":"SMT01","work_order_id":"WO123","operation_id":"OP10","sensor":"temp","value":37.2,"unit":"C","meta":{"site":"BKK"}}
```

## Make this a new GitHub repo

```bash
# from the project root
git init -b main
git add .
git commit -m "chore: initial Edge → MES starter (TimescaleDB + FastAPI + Grafana)"
gh repo create edge-mes-starter --public --source . --remote origin --push
# or, if not using GitHub CLI:
# 1) create an empty repo on GitHub named edge-mes-starter
# 2) then:
# git remote add origin https://github.com/<you>/edge-mes-starter.git
# git push -u origin main
```

## Notes
- TimescaleDB stores the operational window (30–90d recommended). Keep your long-term Parquet in your collection repo/lake.
- MES/SFC can read Postgres views (ODBC/JDBC) or call FastAPI endpoints you extend.

## Real OEE wiring
- Views:
  - `v_quality_per_shift` (Quality from `yield` or `defect_rate` readings)
  - `v_runtime_per_shift` (Availability & Performance from `op_run`)
  - `v_oee_shift_real` (final OEE per shift)
- Shifts (Asia/Bangkok): Night 00:00–08:00, Day 08:00–16:00, Evening 16:00–00:00
- Demo seed: `db/init/99_seed.sql` inserts a 4-hour `op_run` so the Real OEE panels render.

## REST endpoints (op_run lifecycle)
- `POST /op_run/start` — start a run
  ```json
  {"work_order_id":"WO123","operation_id":"OP10","resource_id":"SMT01","planned_seconds":14400,"ideal_cycle_time_s":1.5}
  ```
- `POST /op_run/report` — increment counters during a run
  ```json
  {"op_run_id":"<uuid>","good_delta":10,"scrap_delta":1}
  ```
- `POST /op_run/complete` — complete a run (optionally set final counters)
  ```json
  {"op_run_id":"<uuid>","good_units":780,"scrap_units":20}
  ```
- `GET /op_run/active` — list active runs
