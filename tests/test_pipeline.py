"""Сквозные тесты конвейера на фикстурах: пропущенные запуски, недоступность источников и сервисов."""
import json
from datetime import timedelta

import httpx

from conftest import load_fixture, make_pipeline, make_settings
from leadgen.core.models import utcnow
from leadgen.scheduler.runner import is_due, restore_from_notion
from leadgen.storage.notion import API

FEED = "https://www.fl.ru/rss/all.xml"
OVERPASS = "https://overpass-api.de/api/interpreter"
TOKEN = "123456789:AAEexampleexampleexampleexampleexample"
TG = f"https://api.telegram.org/bot{TOKEN}/sendMessage"
LIVE_SECRETS = {"TELEGRAM_BOT_TOKEN": TOKEN, "TELEGRAM_CHAT_ID": "1", "NOTION_TOKEN": "secret_x", "NOTION_DATABASE_ID": "db"}


def only_fl(data):
    for name, cfg in data["sources"].items():
        cfg["enabled"] = name == "fl_ru"


def fl_and_tg(data):
    for name, cfg in data["sources"].items():
        cfg["enabled"] = name in ("fl_ru", "telegram_channels")
    data["sources"]["telegram_channels"]["channels"] = ["test_orders"]


def mock_sources(mock):
    mock.get(FEED).mock(return_value=httpx.Response(200, text=load_fixture("fl_rss.xml")))
    mock.get("https://t.me/s/test_orders").mock(return_value=httpx.Response(200, text=load_fixture("tg_page_latest.html")))


def test_dry_run_full_cycle_touches_no_external_services(store, no_network):
    mock_sources(no_network)
    tg = no_network.post(TG)
    notion = no_network.post(url__startswith=API)
    pipe = make_pipeline(make_settings("dry-run", LIVE_SECRETS, fl_and_tg), store)
    rep = pipe.run()
    assert rep.sources_run == ["fl_ru", "telegram_channels"]
    assert rep.new_relevant >= 2 and rep.notified >= 1
    assert not tg.called and not notion.called                              # dry-run: наружу ничего
    assert any("dry-run" in w for w in rep.warnings)


def test_intervals_respected_and_force(store, no_network):
    mock_sources(no_network)
    pipe = make_pipeline(make_settings("dry-run", {}, only_fl), store)
    assert pipe.run().sources_run == ["fl_ru"]
    rep = pipe.run()
    assert rep.sources_run == [] and rep.sources_skipped["fl_ru"] == "ещё не пора по расписанию"
    assert pipe.run(force=True).sources_run == ["fl_ru"]


def test_is_due_logic():
    now = utcnow()
    assert is_due({"last_success_at": None}, 2, now)
    assert not is_due({"last_success_at": now - timedelta(hours=1)}, 2, now)
    assert is_due({"last_success_at": now - timedelta(hours=1, minutes=55)}, 2, now)  # допуск на задержку cron
    assert is_due({"last_success_at": now - timedelta(days=3)}, 2, now)               # пропущенные запуски
    assert is_due({"consecutive_failures": 1, "last_attempt_at": now - timedelta(hours=1)}, 24, now)


def test_one_source_down_others_work_and_notify_after_threshold(store, no_network):
    no_network.get(FEED).mock(return_value=httpx.Response(503))
    no_network.get("https://t.me/s/test_orders").mock(
        return_value=httpx.Response(200, text=load_fixture("tg_page_latest.html")))
    tg = no_network.post(TG).mock(return_value=httpx.Response(200, json={"ok": True}))
    no_network.post(f"{API}/databases/db/query").mock(return_value=httpx.Response(200, json={"results": []}))
    no_network.post(f"{API}/pages").mock(return_value=httpx.Response(200, json={"id": "p"}))
    pipe = make_pipeline(make_settings("live", LIVE_SECRETS, fl_and_tg), store)
    rep1 = pipe.run()
    assert rep1.new_relevant >= 2 and not rep1.problems                     # 1-й сбой — молчим
    assert store.source_state("fl_ru")["consecutive_failures"] == 1
    rep2 = pipe.run(force=True)
    assert [p["module"] for p in rep2.problems] == ["fl_ru"]                 # 2-й подряд — сообщаем
    texts = [json.loads(c.request.content)["text"] for c in tg.calls]
    assert any("fl_ru" in t and "только этот источник" in t for t in texts)
    # восстановление
    no_network.get(FEED).mock(return_value=httpx.Response(200, text=load_fixture("fl_rss.xml")))
    rep3 = pipe.run(force=True)
    assert rep3.recovered == ["fl_ru"]
    assert any("Снова работают: fl_ru" in json.loads(c.request.content)["text"] for c in tg.calls)


def test_notion_down_keeps_leads_locally_and_syncs_later(store, no_network):
    mock_sources(no_network)
    no_network.post(TG).mock(return_value=httpx.Response(200, json={"ok": True}))
    q = no_network.post(f"{API}/databases/db/query").mock(return_value=httpx.Response(502))
    pipe = make_pipeline(make_settings("live", LIVE_SECRETS, only_fl), store)
    rep = pipe.run()
    assert rep.notion_synced == 0 and rep.notified >= 1                     # уведомления не зависят от Notion
    assert not rep.problems                                                 # первый сбой — без тревоги
    rep = pipe.run()
    assert [p["module"] for p in rep.problems] == ["notion"]                # второй подряд — сообщаем
    pending = store.leads_pending_notion()
    assert pending
    q.mock(return_value=httpx.Response(200, json={"results": []}))
    no_network.post(f"{API}/pages").mock(return_value=httpx.Response(200, json={"id": "p1"}))
    rep2 = pipe.run()                                                      # источник не пора, но синк догоняет
    assert rep2.sources_run == [] and rep2.notion_synced == len(pending)
    assert rep2.recovered == ["notion"]
    assert store.leads_pending_notion() == []


def test_everything_external_disabled_still_works(store, no_network):
    mock_sources(no_network)
    pipe = make_pipeline(make_settings("live", {}, only_fl), store)          # ни Telegram, ни Notion
    rep = pipe.run()
    assert rep.new_relevant >= 1
    assert any("Notion не настроен" in w for w in rep.warnings)
    assert store.count_leads() == 3


def test_restore_from_notion_prevents_duplicate_notifications(store, no_network):
    mock_sources(no_network)
    tg = no_network.post(TG).mock(return_value=httpx.Response(200, json={"ok": True}))
    # Первый «старый» запуск во временной базе — получаем ключи, которые есть в Notion
    from leadgen.storage.sqlite_store import Store
    old = Store(":memory:")
    make_pipeline(make_settings("dry-run", {}, only_fl), old).run()
    keys = [r["lead_id"] for r in old.conn.execute("SELECT lead_id FROM leads WHERE relevance!='rejected'")]
    pages = [{"id": f"p{i}", "properties": {"Dedup Key": {"rich_text": [{"plain_text": k}]},
                                             "Source": {"select": {"name": "fl_ru"}}}} for i, k in enumerate(keys)]
    no_network.post(f"{API}/databases/db/query").mock(
        return_value=httpx.Response(200, json={"results": pages, "has_more": False}))
    pipe = make_pipeline(make_settings("live", LIVE_SECRETS, only_fl), store)  # «кэш потерян»
    assert restore_from_notion(pipe, 30) == len(keys)
    rep = pipe.run()
    texts = " ".join(json.loads(c.request.content)["text"] for c in tg.calls)
    assert rep.notified == 0 and "Telegram-бот" not in texts                 # заявки повторно не прислали


def test_osm_end_to_end_economy(store, no_network):
    def only_osm(data):
        for name, cfg in data["sources"].items():
            cfg["enabled"] = name == "osm_organizations"
        data["sources"]["osm_organizations"]["categories"] = {
            "beauty": {"label": "Салоны", "group": "beauty", "filters": ['["shop"="beauty"]']}}
    ov = no_network.post(OVERPASS).mock(return_value=httpx.Response(200, text=load_fixture("overpass_beauty.json")))
    no_network.get(url__regex=r".*\.example.*").mock(return_value=httpx.Response(200, text=load_fixture("site_old.html")))
    pipe = make_pipeline(make_settings("dry-run", {}, only_osm), store)
    rep = pipe.run()
    assert rep.new_total == 3 and ov.call_count == 1
    pipe.run(force=True)
    assert ov.call_count == 1                                               # повтор запроса не тратит квоту
    stats = {r["source"]: r["requests"] for r in store.request_stats()}
    assert stats["osm_organizations"] == 1 and stats["osm_organizations:sites"] == 2


def test_core_crash_is_reported_as_system(store, no_network, monkeypatch):
    no_network.post(TG).mock(return_value=httpx.Response(200, json={"ok": True}))
    pipe = make_pipeline(make_settings("live", LIVE_SECRETS, only_fl), store)
    monkeypatch.setattr(pipe, "run_sources", lambda *a: (_ for _ in ()).throw(RuntimeError("boom")))
    rep = pipe.run()
    assert rep.problems[0]["scope"] == "system"


def test_webhook_url_secret_never_reaches_telegram_or_logs(store, no_network, caplog):
    secret_hook = "https://hook.example/very-secret-path-123"
    mock_sources(no_network)
    no_network.post(secret_hook).mock(return_value=httpx.Response(500))
    tg = no_network.post(TG).mock(return_value=httpx.Response(200, json={"ok": True}))

    def patch(data):
        only_fl(data)
        data["integrations"]["webhook"].update({"enabled": True, "route": {"min_relevance": "medium"}})
        data["integrations"]["notion"]["enabled"] = False
    pipe = make_pipeline(make_settings("live", {**LIVE_SECRETS, "WEBHOOK_URL": secret_hook}, patch), store)
    pipe.run()
    sent = " ".join(c.request.content.decode() for c in tg.calls)
    assert "very-secret-path" not in sent
    assert all("very-secret-path" not in r["message"] for r in store.recent_errors())
    ext = store.conn.execute("SELECT error FROM external_results").fetchall()
    assert ext and all("very-secret-path" not in (r["error"] or "") for r in ext)


def test_dry_run_logs_do_not_contain_lead_contents(store, no_network, caplog):
    import logging
    mock_sources(no_network)
    caplog.set_level(logging.INFO)
    make_pipeline(make_settings("dry-run", {}, only_fl), store).run()
    assert "test@example.com" not in caplog.text and "салона красоты" not in caplog.text
