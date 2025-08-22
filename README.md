# Edge → MES Starter

A production-ready starter stack to bridge **edge AI data collection** with **MES/SFC systems**.

## Why this repo?
In modern factories, **edge devices** generate massive volumes of operational data (temperature, speed, vibration, defect detection, yield, etc.).  
Storing these logs directly in MES/SFC is inefficient, while leaving them in raw files prevents real-time insight.  
This repo provides the **missing bridge**: ingesting edge JSONL logs into a time-series database, wiring in REST endpoints for MES/SFC, and exposing live dashboards.  

By using this repo/module, you can:
- Reduce integration complexity between edge AI and enterprise MES/SFC.  
- Ensure **traceability** with hot JSONL logs + Parquet archives.  
- Monitor **live KPIs** (SPC, OEE, shift calendars) without waiting for batch ETL.  
- Enable downstream analytics, alerts, and compliance reporting.

## Industrial applications
This stack is designed for industries where **real-time visibility and quality monitoring** are critical:
- **Electronics assembly & SMT lines** → monitor yield, defects, cycle time.  
- **Automotive & EV manufacturing** → ensure OEE and quality across multi-shift operations.  
- **Food & beverage production** → track temperature, safety, batch yields.  
- **Pharmaceuticals & biotech** → maintain compliance with traceable sensor and quality logs.  
- **Logistics & warehousing** → monitor equipment uptime and throughput.  

### 🔑 Design Concept
- **Separation of concerns:**  
  - **Hot JSONL logs** for raw traceability.  
  - **TimescaleDB (Postgres)** for operational queries, KPIs, and MES integration.  
  - **Parquet (via edge-ai-data-collection)** for long-term analytics in a lake.  
- **MES/SFC compatibility:**  
  - Postgres views (`v_quality_per_shift`, `v_oee_shift_real`) are consumable via ODBC/JDBC.  
  - FastAPI provides REST endpoints for run lifecycle and traceability.  
- **Operator visibility:** Grafana dashboards (SPC, OEE, Shift Calendar) for immediate shopfloor insights.

---

## 📡 End-to-End Data Flow

```
[Edge Device / Sintrones Kit]
   └─ JSONL hot logs (sensor readings, detections)
        ↓
[edge-ai-data-collection]
   ├─ JSONL hot store (short-term)
   └─ Parquet batches + manifests (long-term)
        ↓
[FastAPI Ingestor]
   └─ Tails JSONL → Inserts into TimescaleDB (hypertable: readings)
        ↓
[Operational Core]
   ├─ TimescaleDB (operational store, 30–90 days)
   ├─ Views for MES (ODBC/JDBC) and KPIs
   └─ REST endpoints (/op_run/*, /trace/*)
        ↓
[Grafana Dashboards]
   ├─ Live sensor trends
   ├─ SPC (mean / ±3σ)
   ├─ OEE (Availability × Performance × Quality)
   └─ Shift calendar (Day/Evening/Night)
```

---

## 📂 What’s Inside

| Path                          | Purpose                                                                 |
|-------------------------------|-------------------------------------------------------------------------|
| `docker-compose.yml`          | Orchestrates TimescaleDB, FastAPI API, and Grafana                      |
| `api/app/`                    | FastAPI app (ingestor + REST endpoints)                                 |
| `db/init/01_schema.sql`       | Base schema (resources, work_orders, op_run, readings)                  |
| `db/init/02_oee.sql`          | Shift calendar + views for OEE (availability, performance, quality)     |
| `db/init/99_seed.sql`         | Demo `op_run` to show OEE panels immediately                           |
| `grafana/`                    | Datasource provisioning + dashboards                                   |
| `hotdata/`                    | Mount point for JSONL hot logs (sample included)                        |
| `README.md`                   | Documentation and quickstart                                            |

---

## 📊 Data Types & Logs

| Layer / File                 | Format         | Example Fields                                                                 |
|------------------------------|----------------|--------------------------------------------------------------------------------|
| **Edge hot logs**            | JSONL          | `ts`, `resource_id`, `work_order_id`, `operation_id`, `sensor`, `value`, `unit` |
| **Batch analytics**          | Parquet        | Partitioned by date/site/resource/sensor                                       |
| **Manifest**                 | JSON           | Checksums, schema fingerprint, Merkle root, optional txid                      |
| **TimescaleDB.hypertable**   | SQL rows       | `readings(ts, resource_id, sensor, value, unit, meta)`                          |
| **Views (for MES)**          | SQL views      | `v_quality_per_shift`, `v_runtime_per_shift`, `v_oee_shift_real`                |
| **REST endpoints**           | JSON/HTTP      | `/op_run/start`, `/op_run/report`, `/op_run/complete`, `/op_run/active`        |
| **Grafana dashboards**       | Timeseries/SQL | SPC charts, OEE KPIs, Shift tables                                             |

---

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
