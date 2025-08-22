import os
import json
import time
import threading
from datetime import datetime, timezone
from typing import List, Optional
import psycopg2
from psycopg2.extras import execute_values
from fastapi import FastAPI, Body
from pydantic import BaseModel, Field

# Environment
DB_USER = os.getenv("POSTGRES_USER", "mes")
DB_PASS = os.getenv("POSTGRES_PASSWORD", "mespass")
DB_NAME = os.getenv("POSTGRES_DB", "mesdb")
DB_HOST = os.getenv("POSTGRES_HOST", "db")
DB_PORT = int(os.getenv("POSTGRES_PORT", "5432"))

HOT_DIR = os.getenv("HOT_DIR", "/ingest/hot")
BATCH_SIZE = int(os.getenv("BATCH_SIZE", "500"))
BATCH_SECONDS = float(os.getenv("BATCH_SECONDS", "2"))

app = FastAPI(title="Edge → MES Ingestor", version="0.1.0")

def get_conn():
    return psycopg2.connect(
        dbname=DB_NAME, user=DB_USER, password=DB_PASS,
        host=DB_HOST, port=DB_PORT
    )

# Pydantic model for manual ingestion
class Reading(BaseModel):
    ts: datetime = Field(default_factory=lambda: datetime.now(timezone.utc))
    resource_id: Optional[str] = None
    work_order_id: Optional[str] = None
    operation_id: Optional[str] = None
    sensor: str
    value: Optional[float] = None
    unit: Optional[str] = None
    quality: Optional[dict] = None
    meta: Optional[dict] = None

@app.get("/health")
def health():
    try:
        with get_conn() as conn, conn.cursor() as cur:
            cur.execute("SELECT 1")
        return {"ok": True}
    except Exception as e:
        return {"ok": False, "error": str(e)}

@app.post("/ingest")
def ingest(readings: List[Reading] = Body(...)):
    rows = [
        (
            r.ts, r.resource_id, r.work_order_id, r.operation_id,
            r.sensor, r.value, r.unit, json.dumps(r.quality) if r.quality else None,
            json.dumps(r.meta) if r.meta else None
        ) for r in readings
    ]
    with get_conn() as conn, conn.cursor() as cur:
        execute_values(cur, """
            INSERT INTO readings (ts, resource_id, work_order_id, operation_id, sensor, value, unit, quality, meta)
            VALUES %s
        """, rows)
    return {"ingested": len(rows)}

# ---- Simple file tailer for *.jsonl in HOT_DIR ----
_offsets = {}
_stop = False

def _flush_batch(batch):
    if not batch:
        return 0
    rows = []
    for rec in batch:
        # Coerce types and defaults
        ts = rec.get("ts")
        if isinstance(ts, str):
            ts = datetime.fromisoformat(ts.replace("Z", "+00:00"))
        elif ts is None:
            ts = datetime.now(timezone.utc)
        rows.append((
            ts,
            rec.get("resource_id"),
            rec.get("work_order_id"),
            rec.get("operation_id"),
            rec.get("sensor"),
            rec.get("value"),
            rec.get("unit"),
            json.dumps(rec.get("quality")) if isinstance(rec.get("quality"), dict) else None,
            json.dumps(rec.get("meta")) if isinstance(rec.get("meta"), dict) else None,
        ))
    with get_conn() as conn, conn.cursor() as cur:
        execute_values(cur, """
            INSERT INTO readings (ts, resource_id, work_order_id, operation_id, sensor, value, unit, quality, meta)
            VALUES %s
        """, rows)
    return len(rows)

def tailer():
    last_flush = time.time()
    batch = []
    while not _stop:
        # list files
        try:
            files = [f for f in os.listdir(HOT_DIR) if f.endswith(".jsonl")]
        except FileNotFoundError:
            os.makedirs(HOT_DIR, exist_ok=True)
            files = []
        for fname in sorted(files):
            path = os.path.join(HOT_DIR, fname)
            pos = _offsets.get(path, 0)
            try:
                with open(path, "r", encoding="utf-8") as fh:
                    fh.seek(pos)
                    for line in fh:
                        line = line.strip()
                        if not line:
                            continue
                        try:
                            rec = json.loads(line)
                            batch.append(rec)
                        except Exception:
                            continue
                    _offsets[path] = fh.tell()
            except FileNotFoundError:
                continue

        now = time.time()
        if len(batch) >= BATCH_SIZE or (now - last_flush) >= BATCH_SECONDS:
            try:
                n = _flush_batch(batch)
                batch.clear()
            except Exception as e:
                # backoff on failure
                time.sleep(1)
            last_flush = now
        time.sleep(0.5)

@app.on_event("startup")
def _start_bg():
    t = threading.Thread(target=tailer, daemon=True)
    t.start()

# =========================
# op_run lifecycle endpoints
# =========================
from fastapi import HTTPException

class OpRunStart(BaseModel):
    work_order_id: str
    operation_id: str
    resource_id: str
    planned_seconds: int | None = None         # e.g., planned 8h = 28800
    ideal_cycle_time_s: float | None = None    # sec per unit

class OpRunReport(BaseModel):
    op_run_id: str
    good_delta: int = 0
    scrap_delta: int = 0

class OpRunComplete(BaseModel):
    op_run_id: str
    good_units: int | None = None
    scrap_units: int | None = None
    planned_seconds: int | None = None
    ideal_cycle_time_s: float | None = None

@app.post("/op_run/start")
def op_run_start(payload: OpRunStart):
    with get_conn() as conn, conn.cursor() as cur:
        cur.execute(
            """
            INSERT INTO op_run (work_order_id, operation_id, resource_id, started_ts, status,
                                planned_seconds, ideal_cycle_time_s, good_units, total_units, meta)
            VALUES (%s, %s, %s, now(), 'RUNNING', %s, %s, 0, 0, '{}'::jsonb)
            RETURNING op_run_id
            """,
            (payload.work_order_id, payload.operation_id, payload.resource_id,
             payload.planned_seconds, payload.ideal_cycle_time_s)
        )
        op_run_id = cur.fetchone()[0]
    return {"op_run_id": str(op_run_id), "status": "RUNNING"}

@app.post("/op_run/report")
def op_run_report(payload: OpRunReport):
    if payload.good_delta == 0 and payload.scrap_delta == 0:
        raise HTTPException(status_code=400, detail="Nothing to update (both deltas are 0).")
    with get_conn() as conn, conn.cursor() as cur:
        cur.execute(
            """
            UPDATE op_run
            SET good_units = COALESCE(good_units,0) + %s,
                total_units = COALESCE(total_units,0) + %s + %s
            WHERE op_run_id = %s AND (status = 'RUNNING' OR status IS NULL)
            RETURNING op_run_id
            """,
            (payload.good_delta, payload.good_delta, payload.scrap_delta, payload.op_run_id)
        )
        if cur.rowcount == 0:
            raise HTTPException(status_code=404, detail="op_run not found or not RUNNING")
    return {"op_run_id": payload.op_run_id, "good_added": payload.good_delta, "scrap_added": payload.scrap_delta}

@app.post("/op_run/complete")
def op_run_complete(payload: OpRunComplete):
    # If good/scrap provided, set absolute values; else keep existing.
    sets = []
    params = []
    if payload.good_units is not None and payload.scrap_units is not None:
        sets.append("good_units = %s")
        params.append(payload.good_units)
        sets.append("total_units = %s")
        params.append(payload.good_units + payload.scrap_units)
    elif payload.good_units is not None:
        sets.append("good_units = %s")
        params.append(payload.good_units)
    elif payload.scrap_units is not None:
        sets.append("total_units = COALESCE(good_units,0) + %s")
        params.append(payload.scrap_units)
    if payload.planned_seconds is not None:
        sets.append("planned_seconds = %s")
        params.append(payload.planned_seconds)
    if payload.ideal_cycle_time_s is not None:
        sets.append("ideal_cycle_time_s = %s")
        params.append(payload.ideal_cycle_time_s)

    sets.append("ended_ts = now()")
    sets.append("status = 'COMPLETED'")

    sql = "UPDATE op_run SET " + ", ".join(sets) + " WHERE op_run_id = %s RETURNING op_run_id"
    params.append(payload.op_run_id)

    with get_conn() as conn, conn.cursor() as cur:
        cur.execute(sql, tuple(params))
        if cur.rowcount == 0:
            raise HTTPException(status_code=404, detail="op_run not found")
    return {"op_run_id": payload.op_run_id, "status": "COMPLETED"}

@app.get("/op_run/active")
def op_run_active():
    with get_conn() as conn, conn.cursor() as cur:
        cur.execute(
            "SELECT op_run_id::text, work_order_id, operation_id, resource_id, started_ts, status, good_units, total_units FROM op_run WHERE status='RUNNING' ORDER BY started_ts DESC"
        )
        rows = cur.fetchall()
    return [
        {"op_run_id": r[0], "work_order_id": r[1], "operation_id": r[2], "resource_id": r[3],
         "started_ts": r[4].isoformat(), "status": r[5], "good_units": r[6], "total_units": r[7]}
        for r in rows
    ]
