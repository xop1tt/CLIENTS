"""SQLite — рабочая база, кэш и журнал состояния. Только параметризованные запросы."""
from __future__ import annotations

import json
import sqlite3
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Iterator

from leadgen.core.models import ExternalResult, Lead, utcnow

SCHEMA = """
CREATE TABLE IF NOT EXISTS leads (
    lead_id TEXT PRIMARY KEY,
    fingerprint TEXT NOT NULL,
    kind TEXT NOT NULL,
    source TEXT NOT NULL,
    external_id TEXT NOT NULL,
    data_json TEXT NOT NULL,
    score REAL NOT NULL DEFAULT 0,
    relevance TEXT NOT NULL,
    discovered_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    notion_page_id TEXT,
    notion_status TEXT NOT NULL DEFAULT 'pending',
    notified_at TEXT,
    enrich_due_at TEXT
);
CREATE INDEX IF NOT EXISTS ix_leads_fp ON leads(fingerprint);
CREATE INDEX IF NOT EXISTS ix_leads_notion ON leads(notion_status);

CREATE TABLE IF NOT EXISTS external_results (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    lead_id TEXT NOT NULL,
    service TEXT NOT NULL,
    processed_at TEXT NOT NULL,
    ok INTEGER NOT NULL,
    score REAL,
    label TEXT,
    details_json TEXT,
    error TEXT
);
CREATE INDEX IF NOT EXISTS ix_ext_lead ON external_results(lead_id, service);

CREATE TABLE IF NOT EXISTS source_state (
    source TEXT PRIMARY KEY,
    last_success_at TEXT,
    last_attempt_at TEXT,
    cursor_json TEXT,
    consecutive_failures INTEGER NOT NULL DEFAULT 0,
    status TEXT NOT NULL DEFAULT 'ok',
    last_error TEXT
);

CREATE TABLE IF NOT EXISTS request_stats (
    source TEXT NOT NULL,
    day TEXT NOT NULL,
    requests INTEGER NOT NULL DEFAULT 0,
    errors INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (source, day)
);

CREATE TABLE IF NOT EXISTS quota (
    service TEXT NOT NULL,
    period TEXT NOT NULL,
    used INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (service, period)
);

CREATE TABLE IF NOT EXISTS query_history (
    query_hash TEXT PRIMARY KEY,
    source TEXT NOT NULL,
    query_text TEXT NOT NULL,
    last_run_at TEXT NOT NULL,
    result_count INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS seen_objects (
    source TEXT NOT NULL,
    object_id TEXT NOT NULL,
    checked_at TEXT NOT NULL,
    PRIMARY KEY (source, object_id)
);

CREATE TABLE IF NOT EXISTS errors (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    at TEXT NOT NULL,
    module TEXT NOT NULL,
    signature TEXT NOT NULL,
    message TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS notifications_log (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    at TEXT NOT NULL,
    kind TEXT NOT NULL,
    key TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS ix_notif_key ON notifications_log(kind, key);

CREATE TABLE IF NOT EXISTS kv (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL
);
"""


def _iso(dt: datetime | None) -> str | None:
    return dt.isoformat() if dt else None


def _dt(s: str | None) -> datetime | None:
    return datetime.fromisoformat(s) if s else None


class Store:
    def __init__(self, path: str | Path = ":memory:"):
        self.path = str(path)
        if self.path != ":memory:":
            Path(self.path).parent.mkdir(parents=True, exist_ok=True)
        self.conn = sqlite3.connect(self.path)
        self.conn.row_factory = sqlite3.Row
        self.conn.execute("PRAGMA journal_mode=DELETE")
        self.conn.executescript(SCHEMA)
        self.conn.commit()

    def close(self) -> None:
        self.conn.commit()
        self.conn.close()

    # ---------- leads ----------
    def has_lead(self, lead_id: str) -> bool:
        return self.conn.execute("SELECT 1 FROM leads WHERE lead_id=?", (lead_id,)).fetchone() is not None

    def has_fingerprint(self, fp: str) -> bool:
        return self.conn.execute("SELECT 1 FROM leads WHERE fingerprint=?", (fp,)).fetchone() is not None

    def insert_lead(self, lead: Lead) -> bool:
        """True — новая запись; False — дубль (по ID или отпечатку)."""
        if self.has_lead(lead.lead_id) or self.has_fingerprint(lead.content_fingerprint):
            return False
        now = _iso(utcnow())
        self.conn.execute(
            "INSERT INTO leads (lead_id, fingerprint, kind, source, external_id, data_json, score,"
            " relevance, discovered_at, updated_at) VALUES (?,?,?,?,?,?,?,?,?,?)",
            (lead.lead_id, lead.content_fingerprint, lead.kind.value, lead.source, lead.external_id,
             lead.to_json(), lead.score, lead.relevance.value, _iso(lead.discovered_at), now),
        )
        self.conn.commit()
        return True

    def update_lead(self, lead: Lead) -> None:
        self.conn.execute(
            "UPDATE leads SET data_json=?, score=?, relevance=?, updated_at=? WHERE lead_id=?",
            (lead.to_json(), lead.score, lead.relevance.value, _iso(utcnow()), lead.lead_id),
        )
        self.conn.commit()

    def get_lead(self, lead_id: str) -> Lead | None:
        row = self.conn.execute("SELECT data_json FROM leads WHERE lead_id=?", (lead_id,)).fetchone()
        return Lead.from_json(row["data_json"]) if row else None

    def iter_leads(self, where: str = "1=1", params: tuple = ()) -> Iterator[Lead]:
        # where формируется только внутри кода, пользовательские значения — через params
        for row in self.conn.execute(f"SELECT data_json FROM leads WHERE {where} ORDER BY discovered_at", params):
            yield Lead.from_json(row["data_json"])

    def leads_pending_notion(self, limit: int = 100) -> list[Lead]:
        rows = self.conn.execute(
            "SELECT data_json FROM leads WHERE notion_status IN ('pending','error') AND relevance != 'rejected'"
            " ORDER BY discovered_at LIMIT ?", (limit,)).fetchall()
        return [Lead.from_json(r["data_json"]) for r in rows]

    def set_notion(self, lead_id: str, status: str, page_id: str | None = None) -> None:
        self.conn.execute("UPDATE leads SET notion_status=?, notion_page_id=COALESCE(?, notion_page_id) WHERE lead_id=?",
                          (status, page_id, lead_id))
        self.conn.commit()

    def notion_page_id(self, lead_id: str) -> str | None:
        row = self.conn.execute("SELECT notion_page_id FROM leads WHERE lead_id=?", (lead_id,)).fetchone()
        return row["notion_page_id"] if row else None

    def mark_notified(self, lead_id: str) -> None:
        self.conn.execute("UPDATE leads SET notified_at=? WHERE lead_id=?", (_iso(utcnow()), lead_id))
        self.conn.commit()

    def is_notified(self, lead_id: str) -> bool:
        row = self.conn.execute("SELECT notified_at FROM leads WHERE lead_id=?", (lead_id,)).fetchone()
        return bool(row and row["notified_at"])

    def register_remote_key(self, lead_id: str, source: str, page_id: str | None) -> None:
        """Восстановление из Notion: минимальная запись-маркер 'уже видели'."""
        if self.has_lead(lead_id):
            return
        now = _iso(utcnow())
        self.conn.execute(
            "INSERT INTO leads (lead_id, fingerprint, kind, source, external_id, data_json, relevance,"
            " discovered_at, updated_at, notion_page_id, notion_status, notified_at)"
            " VALUES (?,?,?,?,?,?,?,?,?,?,?,?)",
            (lead_id, "remote:" + lead_id, "order", source, "", json.dumps(
                {"kind": "order", "source": source, "external_id": "", "title": "(restored)"}),
             "rejected", now, now, page_id, "synced", now),
        )
        self.conn.commit()

    def count_leads(self) -> int:
        return self.conn.execute("SELECT COUNT(*) FROM leads").fetchone()[0]

    # ---------- external results ----------
    def add_external_result(self, lead_id: str, r: ExternalResult) -> None:
        self.conn.execute(
            "INSERT INTO external_results (lead_id, service, processed_at, ok, score, label, details_json, error)"
            " VALUES (?,?,?,?,?,?,?,?)",
            (lead_id, r.service, _iso(r.processed_at), int(r.ok), r.score, r.label,
             json.dumps(r.details, ensure_ascii=False), r.error))
        self.conn.commit()

    def external_results(self, lead_id: str) -> list[ExternalResult]:
        rows = self.conn.execute(
            "SELECT * FROM external_results WHERE lead_id=? ORDER BY processed_at", (lead_id,)).fetchall()
        return [ExternalResult(service=r["service"], processed_at=_dt(r["processed_at"]), ok=bool(r["ok"]),
                               score=r["score"], label=r["label"], details=json.loads(r["details_json"] or "{}"),
                               error=r["error"]) for r in rows]

    def was_sent_to(self, lead_id: str, service: str) -> bool:
        return self.conn.execute(
            "SELECT 1 FROM external_results WHERE lead_id=? AND service=? AND ok=1", (lead_id, service)
        ).fetchone() is not None

    # ---------- source state ----------
    def source_state(self, source: str) -> dict[str, Any]:
        row = self.conn.execute("SELECT * FROM source_state WHERE source=?", (source,)).fetchone()
        if not row:
            return {"source": source, "last_success_at": None, "last_attempt_at": None, "cursor": {},
                    "consecutive_failures": 0, "status": "ok", "last_error": None}
        return {"source": source, "last_success_at": _dt(row["last_success_at"]),
                "last_attempt_at": _dt(row["last_attempt_at"]), "cursor": json.loads(row["cursor_json"] or "{}"),
                "consecutive_failures": row["consecutive_failures"], "status": row["status"],
                "last_error": row["last_error"]}

    def _upsert_state(self, source: str, **fields: Any) -> None:
        st = self.source_state(source)
        st.update(fields)
        self.conn.execute(
            "INSERT INTO source_state (source, last_success_at, last_attempt_at, cursor_json, consecutive_failures,"
            " status, last_error) VALUES (?,?,?,?,?,?,?) ON CONFLICT(source) DO UPDATE SET"
            " last_success_at=excluded.last_success_at, last_attempt_at=excluded.last_attempt_at,"
            " cursor_json=excluded.cursor_json, consecutive_failures=excluded.consecutive_failures,"
            " status=excluded.status, last_error=excluded.last_error",
            (source, _iso(st["last_success_at"]), _iso(st["last_attempt_at"]),
             json.dumps(st["cursor"], ensure_ascii=False), st["consecutive_failures"], st["status"], st["last_error"]))
        self.conn.commit()

    def mark_source_success(self, source: str, cursor: dict[str, Any]) -> None:
        now = utcnow()
        self._upsert_state(source, last_success_at=now, last_attempt_at=now, cursor=cursor,
                           consecutive_failures=0, status="ok", last_error=None)

    def mark_source_failure(self, source: str, error: str) -> int:
        st = self.source_state(source)
        n = st["consecutive_failures"] + 1
        self._upsert_state(source, last_attempt_at=utcnow(), consecutive_failures=n,
                           status="failing", last_error=error[:500])
        return n

    def all_source_states(self) -> list[dict[str, Any]]:
        names = [r["source"] for r in self.conn.execute("SELECT source FROM source_state ORDER BY source")]
        return [self.source_state(n) for n in names]

    # ---------- statistics & quotas ----------
    def count_request(self, source: str, error: bool = False) -> None:
        day = utcnow().date().isoformat()
        self.conn.execute(
            "INSERT INTO request_stats (source, day, requests, errors) VALUES (?,?,1,?) ON CONFLICT(source, day)"
            " DO UPDATE SET requests=requests+1, errors=errors+excluded.errors", (source, day, int(error)))
        self.conn.commit()

    def requests_today(self, source: str) -> int:
        row = self.conn.execute("SELECT requests FROM request_stats WHERE source=? AND day=?",
                                (source, utcnow().date().isoformat())).fetchone()
        return row["requests"] if row else 0

    def request_stats(self, days: int = 7) -> list[dict[str, Any]]:
        since = (utcnow().date() - timedelta(days=days)).isoformat()
        rows = self.conn.execute(
            "SELECT source, SUM(requests) r, SUM(errors) e FROM request_stats WHERE day>=? GROUP BY source"
            " ORDER BY source", (since,)).fetchall()
        return [{"source": r["source"], "requests": r["r"], "errors": r["e"]} for r in rows]

    def quota_used(self, service: str, period: str) -> int:
        row = self.conn.execute("SELECT used FROM quota WHERE service=? AND period=?", (service, period)).fetchone()
        return row["used"] if row else 0

    def quota_add(self, service: str, period: str, n: int = 1) -> None:
        self.conn.execute("INSERT INTO quota (service, period, used) VALUES (?,?,?) ON CONFLICT(service, period)"
                          " DO UPDATE SET used=used+excluded.used", (service, period, n))
        self.conn.commit()

    # ---------- query history (экономия запросов к картам) ----------
    def query_last_run(self, query_hash: str) -> datetime | None:
        row = self.conn.execute("SELECT last_run_at FROM query_history WHERE query_hash=?", (query_hash,)).fetchone()
        return _dt(row["last_run_at"]) if row else None

    def record_query(self, query_hash: str, source: str, text: str, count: int) -> None:
        self.conn.execute(
            "INSERT INTO query_history (query_hash, source, query_text, last_run_at, result_count) VALUES (?,?,?,?,?)"
            " ON CONFLICT(query_hash) DO UPDATE SET last_run_at=excluded.last_run_at, result_count=excluded.result_count",
            (query_hash, source, text, _iso(utcnow()), count))
        self.conn.commit()

    def forget_query(self, query_hash: str) -> None:
        self.conn.execute("DELETE FROM query_history WHERE query_hash=?", (query_hash,))
        self.conn.commit()

    def object_checked_at(self, source: str, object_id: str) -> datetime | None:
        row = self.conn.execute("SELECT checked_at FROM seen_objects WHERE source=? AND object_id=?",
                                (source, object_id)).fetchone()
        return _dt(row["checked_at"]) if row else None

    def mark_object_checked(self, source: str, object_id: str) -> None:
        self.conn.execute("INSERT INTO seen_objects (source, object_id, checked_at) VALUES (?,?,?) ON CONFLICT"
                          " (source, object_id) DO UPDATE SET checked_at=excluded.checked_at",
                          (source, object_id, _iso(utcnow())))
        self.conn.commit()

    # ---------- errors & notifications ----------
    def log_error(self, module: str, signature: str, message: str) -> None:
        self.conn.execute("INSERT INTO errors (at, module, signature, message) VALUES (?,?,?,?)",
                          (_iso(utcnow()), module, signature, message[:1000]))
        self.conn.commit()

    def recent_errors(self, hours: int = 24) -> list[dict[str, Any]]:
        since = _iso(utcnow() - timedelta(hours=hours))
        rows = self.conn.execute("SELECT * FROM errors WHERE at>=? ORDER BY at", (since,)).fetchall()
        return [dict(r) for r in rows]

    def notification_sent_since(self, kind: str, key: str, since: datetime) -> bool:
        return self.conn.execute("SELECT 1 FROM notifications_log WHERE kind=? AND key=? AND at>=?",
                                 (kind, key, _iso(since))).fetchone() is not None

    def log_notification(self, kind: str, key: str) -> None:
        self.conn.execute("INSERT INTO notifications_log (at, kind, key) VALUES (?,?,?)", (_iso(utcnow()), kind, key))
        self.conn.commit()

    def kv_get(self, key: str, default: Any = None) -> Any:
        row = self.conn.execute("SELECT value FROM kv WHERE key=?", (key,)).fetchone()
        return json.loads(row["value"]) if row else default

    def kv_set(self, key: str, value: Any) -> None:
        self.conn.execute("INSERT INTO kv (key, value) VALUES (?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
                          (key, json.dumps(value, ensure_ascii=False)))
        self.conn.commit()

    def prune(self, keep_days: int = 90) -> None:
        """Чистим журналы, чтобы база (и кэш GitHub) не росли бесконечно."""
        since = _iso(utcnow() - timedelta(days=keep_days))
        self.conn.execute("DELETE FROM errors WHERE at<?", (since,))
        self.conn.execute("DELETE FROM notifications_log WHERE at<?", (since,))
        self.conn.execute("DELETE FROM request_stats WHERE day<?", (since[:10],))
        self.conn.commit()
