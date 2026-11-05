import json
from datetime import timedelta

import httpx

from conftest import http_factory
from leadgen.core.models import Lead, LeadKind, utcnow
from leadgen.storage.notion import API, NotionAdapter, lead_properties

DB = "db123"
QUERY = f"{API}/databases/{DB}/query"


def na(store):
    return NotionAdapter(http_factory(store)("notion", {}), "secret_token", DB)


def lead():
    return Lead(kind=LeadKind.ORDER, source="fl_ru", external_id="1", title="Нужен сайт", description="x" * 5000)


def test_properties_truncated_and_typed():
    p = lead_properties(lead())
    assert len(p["Description"]["rich_text"][0]["text"]["content"]) <= 1900
    assert p["Kind"]["select"]["name"] == "Заявка" and p["Dedup Key"]["rich_text"][0]["text"]["content"]


def test_upsert_creates_when_missing(store, no_network):
    q = no_network.post(QUERY).mock(return_value=httpx.Response(200, json={"results": []}))
    c = no_network.post(f"{API}/pages").mock(return_value=httpx.Response(200, json={"id": "p1"}))
    assert na(store).upsert(lead()) == "p1"
    body = json.loads(q.calls[0].request.content)
    assert body["filter"]["rich_text"]["equals"] == lead().lead_id
    assert c.calls[0].request.headers["Notion-Version"]


def test_upsert_updates_existing_without_touching_status(store, no_network):
    no_network.post(QUERY).mock(return_value=httpx.Response(200, json={"results": [{"id": "p9"}]}))
    patch = no_network.patch(f"{API}/pages/p9").mock(return_value=httpx.Response(200, json={}))
    assert na(store).upsert(lead()) == "p9"
    assert "Status" not in json.loads(patch.calls[0].request.content)["properties"]


def test_known_page_id_skips_lookup(store, no_network):
    patch = no_network.patch(f"{API}/pages/p5").mock(return_value=httpx.Response(200, json={}))
    q = no_network.post(QUERY)
    na(store).upsert(lead(), known_page_id="p5")
    assert patch.called and not q.called


def test_rate_limit_retry(store, no_network):
    no_network.post(QUERY).mock(side_effect=[httpx.Response(429, headers={"Retry-After": "1"}),
                                             httpx.Response(200, json={"results": []})])
    assert na(store).find_page("k") is None


def test_restore_reads_only_recent_with_pagination(store, no_network):
    def page(key, pid):
        return {"id": pid, "properties": {"Dedup Key": {"rich_text": [{"plain_text": key}]},
                                          "Source": {"select": {"name": "fl_ru"}}}}
    route = no_network.post(QUERY).mock(side_effect=[
        httpx.Response(200, json={"results": [page("k1", "p1")], "has_more": True, "next_cursor": "c2"}),
        httpx.Response(200, json={"results": [page("k2", "p2")], "has_more": False})])
    keys = list(na(store).iter_recent_keys(utcnow() - timedelta(days=30)))
    assert [k for k, _, _ in keys] == ["k1", "k2"]
    b1, b2 = (json.loads(c.request.content) for c in route.calls)
    assert "on_or_after" in b1["filter"]["date"] and b2["start_cursor"] == "c2"
