import json
from datetime import timedelta

import httpx

from conftest import http_factory, load_fixture
from leadgen.core.models import LeadKind, utcnow
from leadgen.sources.osm_overpass import OsmOverpassSource, build_query
from leadgen.sources.rss import RssSource
from leadgen.sources.site_checker import check_site, is_public_http_url
from leadgen.sources.telegram_web import TelegramWebSource, parse_channel_page
from leadgen.sources.vk import VkWallSource

FEED = "https://www.fl.ru/rss/all.xml"


def test_rss_parses_and_remembers_seen(store, no_network):
    route = no_network.get(FEED).mock(return_value=httpx.Response(200, text=load_fixture("fl_rss.xml"),
                                                                  headers={"ETag": "abc"}))
    src = RssSource("fl_ru", {"feeds": [{"url": FEED}]}, store, http_factory(store)("fl_ru", {}))
    r1 = src.fetch(None, {})
    assert len(r1.leads) == 3
    bot = r1.leads[0]
    assert bot.kind == LeadKind.ORDER and "Telegram-бот" in bot.title and bot.published_at
    assert bot.contacts.get("email") == "test@example.com"
    r2 = src.fetch(utcnow(), r1.cursor)
    assert r2.leads == []                                     # повторно ничего не создаём
    assert route.calls[-1].request.headers["If-None-Match"] == "abc"   # условный запрос


def test_rss_304_costs_nothing(store, no_network):
    no_network.get(FEED).mock(return_value=httpx.Response(304))
    src = RssSource("fl_ru", {"feeds": [FEED]}, store, http_factory(store)("fl_ru", {}))
    r = src.fetch(None, {FEED: {"etag": "x", "seen": ["a"]}})
    assert r.leads == [] and r.cursor[FEED]["etag"] == "x"


def test_rss_gap_warning(store, no_network):
    no_network.get(FEED).mock(return_value=httpx.Response(200, text=load_fixture("fl_rss.xml")))
    src = RssSource("fl_ru", {"feeds": [FEED]}, store, http_factory(store)("fl_ru", {}))
    r = src.fetch(utcnow() - timedelta(days=3), {FEED: {"seen": ["very-old-id"]}})
    assert len(r.leads) == 3 and any("пропущенного периода" in w for w in r.warnings)


def test_telegram_parse_page():
    posts = parse_channel_page(load_fixture("tg_page_latest.html"))
    assert [p["id"] for p in posts] == [101, 102, 103]
    assert posts[0]["url"] == "https://t.me/test_orders/101" and posts[0]["published"]


def test_telegram_catches_up_after_missed_runs(store, no_network):
    no_network.get("https://t.me/s/test_orders", params={"before": "101"}).mock(
        return_value=httpx.Response(200, text=load_fixture("tg_page_before_101.html")))
    no_network.get("https://t.me/s/test_orders").mock(
        return_value=httpx.Response(200, text=load_fixture("tg_page_latest.html")))
    cfg = {"channels": ["test_orders"], "prefilter_keywords": ["сайт", "парсер", "crm"], "max_pages_per_channel": 3}
    src = TelegramWebSource("tg", cfg, store, http_factory(store)("tg", {}))
    # последний обработанный пост — 97: пропущены 98..103, нужна вторая страница
    r = src.fetch(None, {"test_orders": 97})
    ids = sorted(l.external_id for l in r.leads)
    assert ids == ["test_orders/101", "test_orders/103", "test_orders/98"]
    assert r.cursor["test_orders"] == 103 and not r.warnings
    assert r.leads[0].contacts.get("telegram") == "@dance_owner"


def test_telegram_missing_channel_is_partial_error(store, no_network):
    no_network.get("https://t.me/s/nochannel").mock(return_value=httpx.Response(200, text="<html></html>"))
    src = TelegramWebSource("tg", {"channels": ["nochannel"]}, store, http_factory(store)("tg", {}))
    r = src.fetch(None, {})
    assert r.partial_errors and not r.leads


def test_telegram_config_validation(store):
    src = TelegramWebSource("tg", {"channels": ["bad name!"]}, store, None)
    assert src.is_configured()[0] is False


def test_vk_wall(store, no_network):
    no_network.get("https://api.vk.com/method/wall.get").mock(
        return_value=httpx.Response(200, text=load_fixture("vk_wall.json")))
    cfg = {"communities": ["orders"], "prefilter_keywords": ["приложени"]}
    src = VkWallSource("vk", cfg, store, http_factory(store)("vk", {}), {"VK_SERVICE_TOKEN": "tok"})
    assert src.is_configured()[0]
    r = src.fetch(None, {})
    assert [l.external_id for l in r.leads] == ["-123_512"]
    assert r.cursor["orders"] == 512


def test_vk_api_error_reported(store, no_network):
    no_network.get("https://api.vk.com/method/wall.get").mock(
        return_value=httpx.Response(200, json={"error": {"error_code": 5, "error_msg": "User authorization failed"}}))
    src = VkWallSource("vk", {"communities": ["x"]}, store, http_factory(store)("vk", {}), {"VK_SERVICE_TOKEN": "t"})
    assert "VK API 5" in src.fetch(None, {}).partial_errors[0]


def test_vk_requires_token(store):
    assert VkWallSource("vk", {"communities": ["x"]}, store, None, {}).is_configured()[0] is False


OSM_CFG = {"regions": [{"name": "Казань"}], "refresh_days": 7, "recheck_days": 60, "max_new_per_run": 10,
           "categories": {"beauty": {"label": "Салоны", "group": "beauty",
                                     "filters": ['["shop"="beauty"]', '["shop"="hairdresser"]']}}}


def _osm(store):
    f = http_factory(store)
    return OsmOverpassSource("osm", OSM_CFG, store, f("osm", {}), site_http=f("osm:sites", {}))


def test_overpass_query_builder():
    q = build_query({"name": 'Ка"зань', "admin_level": 4}, ['["shop"="beauty"]'])
    assert '["name"="Казань"]' in q and '["admin_level"="4"]' in q and 'nwr["shop"="beauty"](area.a);' in q


def test_overpass_query_matches_localized_names():
    q = build_query({"name": "Ереван"}, ['["shop"="beauty"]'])
    assert '["name:ru"="Ереван"]' in q and '["name"="Ереван"]' in q and "(.a0;.a1;.a2;)->.a;" in q


def test_osm_facts_site_checks_and_quota_economy(store, no_network):
    overpass = no_network.post("https://overpass-api.de/api/interpreter").mock(
        return_value=httpx.Response(200, text=load_fixture("overpass_beauty.json")))
    no_network.get("http://old-barber.example").mock(return_value=httpx.Response(200, text=load_fixture("site_old.html")))
    no_network.get("https://modern.example").mock(return_value=httpx.Response(200, text=load_fixture("site_modern.html")))
    r = _osm(store).fetch(None, {})
    by = {l.title: l for l in r.leads}
    assert set(by) == {"Салон Ромашка", "Barber Old", "Студия Модерн"}          # без имени — пропущен
    romashka = by["Салон Ромашка"]
    assert romashka.raw["signals"]["no_website"] and any("не указан сайт" in f for f in romashka.facts)
    assert any("Возможно" in a for a in romashka.assumptions)
    old = by["Barber Old"]
    assert old.raw["signals"]["no_https"] and old.raw["signals"]["no_viewport"] and old.raw["signals"]["outdated"]
    assert any("2015" in f for f in old.facts)
    modern = by["Студия Модерн"]
    assert not modern.raw["signals"].get("no_booking") and not modern.raw["signals"].get("no_viewport")
    # второй запуск: идентичный запрос не повторяется, сайты повторно не проверяются
    calls = overpass.call_count
    r2 = _osm(store).fetch(None, {})
    assert overpass.call_count == calls and r2.leads == []


def test_osm_known_objects_skipped_even_if_query_repeats(store, no_network):
    no_network.post("https://overpass-api.de/api/interpreter").mock(
        return_value=httpx.Response(200, text=load_fixture("overpass_beauty.json")))
    no_network.get(url__regex=r".*\.example.*").mock(return_value=httpx.Response(200, text="<html></html>"))
    _osm(store).fetch(None, {})
    store.conn.execute("DELETE FROM query_history")
    sites_before = store.requests_today("osm:sites")
    r = _osm(store).fetch(None, {})
    assert r.leads == [] and store.requests_today("osm:sites") == sites_before


def test_site_checker_unreachable_is_fact(store, no_network):
    no_network.get("http://down.example").mock(side_effect=httpx.ConnectError("refused"))
    chk = check_site(http_factory(store)("s", {"http": {"max_attempts": 1}}), "down.example", utcnow())
    assert not chk.reachable and "не открылся" in chk.facts[0]


def test_url_validation_blocks_local_addresses():
    assert not is_public_http_url("http://127.0.0.1/admin")
    assert not is_public_http_url("http://192.168.1.1")
    assert not is_public_http_url("file:///etc/passwd")
    assert is_public_http_url("https://example.com")
