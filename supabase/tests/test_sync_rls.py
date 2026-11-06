"""Облачное хранение: RLS, выгрузка изменений, конфликты, удаление, переключение аккаунтов."""

import re
from datetime import datetime, timedelta, timezone
from pathlib import Path

import httpx

from conftest import ANON, Client, confirmed_user, db

T0 = "2026-11-01T10:00:00Z"
T1 = "2026-11-01T11:00:00Z"
T2 = "2026-11-01T12:00:00Z"


def lead(lead_id: str, ts: dict, **fields) -> dict:
    base = {"lead_id": lead_id, "fingerprint": f"fp-{lead_id}", "kind": "order", "source": "fl_ru",
            "title": f"Заказ {lead_id}", "score": 70, "relevance": "medium", "discovered_at": T0,
            "data": {"title": f"Заказ {lead_id}", "kind": "order"}, "favorite": False, "archived": False,
            "deleted": False, "seen": False, "note": ""}
    base.update(fields)
    base["ts"] = ts
    return base


def push(c: Client, device: str = "dev-a", **changes) -> dict:
    r = c.rpc("sync_push", {"p_device": device, "p_changes": changes})
    assert r.status_code == 200, r.text
    return r.json()


def pull(c: Client, table: str, since: int = 0) -> list[dict]:
    r = c.rest("GET", f"{table}?server_seq=gt.{since}&order=server_seq.asc&limit=1000")
    assert r.status_code == 200, r.text
    return r.json()


ALL = {f: T0 for f in ("data", "favorite", "archived", "deleted", "seen", "note")}


def test_rls_isolates_users_read_update_delete():
    a, _ = confirmed_user()
    b, _ = confirmed_user()
    push(a, leads=[lead("L1", ALL, note="секрет A")])
    push(b, leads=[lead("L1", ALL, note="секрет B")])
    # Каждый видит только своё, даже с одинаковым lead_id.
    assert [r["note"] for r in pull(a, "leads")] == ["секрет A"]
    assert [r["note"] for r in pull(b, "leads")] == ["секрет B"]
    a_uid = pull(a, "leads")[0]["user_id"]
    # B пытается прочитать, изменить и удалить строку A по user_id.
    assert b.rest("GET", f"leads?user_id=eq.{a_uid}").json() == []
    r = b.rest("PATCH", f"leads?user_id=eq.{a_uid}", json={"note": "взлом"}, headers={"prefer": "return=representation"})
    assert r.status_code == 200 and r.json() == []
    r = b.rest("DELETE", f"leads?user_id=eq.{a_uid}", headers={"prefer": "return=representation"})
    assert r.json() == []
    assert pull(a, "leads")[0]["note"] == "секрет A"


def test_rls_blocks_insert_for_other_user_and_owner_change():
    a, _ = confirmed_user()
    b, _ = confirmed_user()
    push(a, leads=[lead("L1", ALL)])
    a_uid = pull(a, "leads")[0]["user_id"]
    row = {"user_id": a_uid, "lead_id": "INJECT", "kind": "order", "source": "x", "title": "x", "data": {}}
    r = b.rest("POST", "leads", json=row)
    assert r.status_code in (401, 403), r.text
    # Переписать владельца своей строки на чужого тоже нельзя.
    push(b, leads=[lead("MINE", ALL)])
    r = b.rest("PATCH", "leads?lead_id=eq.MINE", json={"user_id": a_uid})
    assert r.status_code in (400, 401, 403), r.text
    assert [x["lead_id"] for x in pull(a, "leads")] == ["L1"]


def test_anon_key_has_no_data_access():
    a, _ = confirmed_user()
    push(a, leads=[lead("L1", ALL)], settings=[{"key": "draft.signature", "value": "s", "changed_at": T0}])
    anon = httpx.Client(base_url=a.http.base_url, headers={"apikey": ANON})
    for t in ("leads", "exclusions", "user_settings"):
        assert anon.get(f"/rest/v1/{t}").status_code in (401, 403)
    assert anon.post("/rest/v1/rpc/sync_push", json={"p_device": "x", "p_changes": {}}).status_code in (401, 403)


def test_newer_change_wins_older_is_ignored_per_field():
    a, _ = confirmed_user()
    push(a, leads=[lead("L1", ALL)])
    # Устройство A: отметило избранное в 11:00. Устройство B: заметка в 12:00, не зная про избранное.
    push(a, "dev-a", leads=[lead("L1", {"favorite": T1}, favorite=True)])
    push(a, "dev-b", leads=[lead("L1", {"note": T2}, note="позвонить")])
    row = pull(a, "leads")[0]
    assert row["favorite"] is True and row["note"] == "позвонить"
    # Опоздавшее старое изменение (10:30) не затирает более новое.
    push(a, "dev-c", leads=[lead("L1", {"note": "2026-11-01T10:30:00Z", "favorite": "2026-11-01T10:30:00Z"},
                                 note="старое", favorite=False)])
    row = pull(a, "leads")[0]
    assert row["favorite"] is True and row["note"] == "позвонить"


def test_push_is_idempotent_and_no_echo_loop():
    a, _ = confirmed_user()
    first = push(a, leads=[lead("L1", ALL)])
    assert first["leads"] == 1
    seq = pull(a, "leads")[0]["server_seq"]
    again = push(a, leads=[lead("L1", ALL)])
    assert again["leads"] == 0
    assert pull(a, "leads", since=seq) == []  # нечего забирать — цикл не возникает


def test_device_clock_in_future_is_clamped():
    a, _ = confirmed_user()
    future = (datetime.now(timezone.utc) + timedelta(days=365)).isoformat()
    push(a, leads=[lead("L1", {**ALL, "note": future}, note="из будущего")])
    ts = datetime.fromisoformat(pull(a, "leads")[0]["field_ts"]["note"])
    assert ts <= datetime.now(timezone.utc) + timedelta(seconds=5)
    # Настоящее новое изменение после этого всё равно применяется.
    now = datetime.now(timezone.utc).isoformat()
    push(a, leads=[lead("L1", {"note": now}, note="свежее")])
    assert pull(a, "leads")[0]["note"] == "свежее"


def test_incremental_pull_and_deletion_tombstone():
    a, _ = confirmed_user()
    push(a, leads=[lead("L1", ALL), lead("L2", ALL)])
    rows = pull(a, "leads")
    cursor = max(r["server_seq"] for r in rows)
    push(a, "dev-b", leads=[lead("L2", {"deleted": T1}, deleted=True)])
    delta = pull(a, "leads", since=cursor)
    assert [(r["lead_id"], r["deleted"]) for r in delta] == [("L2", True)]
    # Исключение удалили на одном устройстве — другое узнаёт об этом.
    push(a, exclusions=[{"kind": "domain", "value": "example.ru", "deleted": False, "changed_at": T0}])
    c2 = max(r["server_seq"] for r in pull(a, "exclusions"))
    push(a, "dev-b", exclusions=[{"kind": "domain", "value": "example.ru", "deleted": True, "changed_at": T1}])
    assert [r["deleted"] for r in pull(a, "exclusions", since=c2)] == [True]


def test_settings_last_writer_wins():
    a, _ = confirmed_user()
    push(a, settings=[{"key": "search.settings", "value": {"v": 1}, "changed_at": T1}])
    push(a, "dev-b", settings=[{"key": "search.settings", "value": {"v": 0}, "changed_at": T0}])
    assert pull(a, "user_settings")[0]["value"] == {"v": 1}
    push(a, "dev-b", settings=[{"key": "search.settings", "value": {"v": 2}, "changed_at": T2}])
    assert pull(a, "user_settings")[0]["value"] == {"v": 2}


def test_new_device_downloads_everything_after_login():
    a, email = confirmed_user()
    push(a, leads=[lead(f"L{i}", ALL) for i in range(120)],
         settings=[{"key": "draft.signature", "value": "Максим", "changed_at": T0}])
    other = Client()
    assert other.login(email).status_code == 200
    assert len(pull(other, "leads")) == 120
    assert pull(other, "user_settings")[0]["value"] == "Максим"
    stats = other.rpc("sync_stats", {}).json()
    assert stats["leads"] == 120 and stats["settings"] == 1


def test_switching_accounts_shows_only_own_data():
    a, _ = confirmed_user()
    b, b_email = confirmed_user()
    push(a, leads=[lead("A-only", ALL)])
    push(b, leads=[lead("B-only", ALL)])
    # Тот же «компьютер» (клиент) выходит из A и входит в B.
    a.http.post("/auth/v1/logout", headers=a.h())
    assert a.login(b_email).status_code == 200
    assert [r["lead_id"] for r in pull(a, "leads")] == ["B-only"]


def test_push_limits_and_validation():
    a, _ = confirmed_user()
    r = a.rpc("sync_push", {"p_device": "d", "p_changes": {"leads": [lead(f"X{i}", ALL) for i in range(501)]}})
    assert r.status_code >= 400
    r = a.rpc("sync_push", {"p_device": "d", "p_changes": {"leads": [lead("BAD", ALL, kind="spam")]}})
    assert r.status_code >= 400
    r = a.rpc("sync_push", {"p_device": "d", "p_changes": {"settings": [{"key": "../../etc", "value": 1, "changed_at": T0}]}})
    assert r.status_code >= 400
    assert pull(a, "leads") == []


def test_sql_injection_payloads_are_plain_data():
    a, _ = confirmed_user()
    evil = "x'); drop table public.leads; --"
    push(a, leads=[lead(evil, ALL, note=evil, title=evil)])
    assert pull(a, "leads")[0]["lead_id"] == evil
    with db() as d:
        assert d.execute("select to_regclass('public.leads')").fetchone()[0] == "leads"


def test_no_service_role_key_in_client_code():
    """В исходниках приложения нет ключа service_role и вообще JWT-подобных строк."""
    root = Path(__file__).resolve().parents[2]
    jwt = re.compile(r"eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.")
    # Код, который попадает в приложение и его сборку (тесты с поддельными ключами не в счёт).
    shipped = [root / "macos" / "Sources", root / "macos" / "scripts"]
    for path in [p for d in shipped for ext in ("*.swift", "*.sh", "*.plist") for p in d.rglob(ext)]:
        text = path.read_text(errors="ignore")
        assert "SERVICE_ROLE" not in text.upper().replace("_", "_"), path
        assert not jwt.search(text), path
        assert not re.search(r"sb_secret_[A-Za-z0-9_-]{16,}", text), path


def test_direct_table_writes_cannot_set_future_timestamps():
    c, _ = confirmed_user()
    base = {"lead_id": "future-1", "fingerprint": "fpf", "kind": "order", "source": "fl_ru", "title": "t",
            "score": 1, "relevance": "medium", "data": {}, "discovered_at": "2099-01-01T00:00:00Z",
            "field_ts": {"note": "2099-01-01T00:00:00Z"}}
    me = c.http.get("/auth/v1/user", headers=c.h()).json()["id"]
    r = c.http.post("/rest/v1/leads", headers={**c.h(), "Prefer": "return=representation"}, json={**base, "user_id": me})
    assert r.status_code == 201, r.text
    row = r.json()[0]
    assert row["discovered_at"] < "2099" and row["field_ts"]["note"] < "2099"
    r = c.http.post("/rest/v1/exclusions", headers={**c.h(), "Prefer": "return=representation"},
                    json={"user_id": me, "kind": "domain", "value": "x.ru", "changed_at": "2099-01-01T00:00:00Z"})
    assert r.status_code == 201, r.text
    assert r.json()[0]["changed_at"] < "2099"
