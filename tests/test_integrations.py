import hashlib
import hmac
import json

import httpx

from conftest import http_factory
from leadgen.core.models import Lead, LeadKind, Relevance
from leadgen.integrations.base import Router
from leadgen.integrations.hunter import HunterAdapter
from leadgen.integrations.webhook import WebhookAdapter

HOOK = "https://hook.example/abc"


def order(eid, rel=Relevance.HIGH):
    l = Lead(kind=LeadKind.ORDER, source="fl_ru", external_id=eid, title=f"Заявка {eid}", description="секрет " * 3,
             contacts={"phone": "+79000000000"})
    l.relevance, l.score = rel, 80
    return l


def webhook(store, **cfg):
    base = {"route": {"min_relevance": "high"}, "fields": ["lead_id", "title", "score"], "max_per_run": 10}
    base.update(cfg)
    return WebhookAdapter(base, store, http_factory(store)("webhook", {}), {"WEBHOOK_URL": HOOK, "WEBHOOK_SECRET": "s"})


def test_webhook_sends_only_needed_fields_signed_and_parses_result(store, no_network):
    route = no_network.post(HOOK).mock(return_value=httpx.Response(200, json={"score": 70, "label": "годно"}))
    leads = [order("1"), order("2", Relevance.LOW)]
    for l in leads:
        store.insert_lead(l)
    Router([webhook(store)]).run(leads)
    assert route.call_count == 1                                         # LOW не прошёл маршрутизацию
    req = route.calls[0].request
    body = json.loads(req.content)
    assert set(body) == {"lead_id", "title", "score"}                     # контакты не передаются
    assert req.headers["X-Leadgen-Signature"] == hmac.new(b"s", req.content, hashlib.sha256).hexdigest()
    assert leads[0].external_results[0].score == 70
    assert store.external_results(leads[0].lead_id)[0].label == "годно"


def test_no_resend_of_same_lead(store, no_network):
    route = no_network.post(HOOK).mock(return_value=httpx.Response(200, text="ok"))
    l = order("1")
    store.insert_lead(l)
    Router([webhook(store)]).run([l])
    Router([webhook(store)]).run([l])
    assert route.call_count == 1


def test_failing_adapter_does_not_break_others_and_circuit_breaks(store, no_network):
    bad = no_network.post(HOOK).mock(return_value=httpx.Response(500))
    leads = [order(str(i)) for i in range(6)]
    for l in leads:
        store.insert_lead(l)
    problems = Router([webhook(store)], max_failures=3).run(leads)
    assert bad.call_count == 3 * 3                                       # 3 лида × 3 попытки, дальше — стоп
    assert problems and "ошибок подряд" in problems[0]
    assert all(not r.ok for l in leads[:3] for r in l.external_results)


def test_monthly_quota(store, no_network):
    route = no_network.post(HOOK).mock(return_value=httpx.Response(200))
    leads = [order(str(i)) for i in range(5)]
    for l in leads:
        store.insert_lead(l)
    problems = Router([webhook(store, monthly_quota=2)]).run(leads)
    assert route.call_count == 2 and "квота" in problems[0]


def test_hunter_only_for_organizations_with_site(store, no_network):
    api = no_network.get("https://api.hunter.io/v2/domain-search").mock(return_value=httpx.Response(200, json={
        "data": {"organization": "Modern", "pattern": "{first}", "emails": [{"value": "info@modern.example",
                                                                               "type": "generic", "confidence": 90}]}}))
    org = Lead(kind=LeadKind.ORGANIZATION, source="osm", external_id="n/1", title="Модерн",
               website="https://www.modern.example/about")
    org.relevance = Relevance.MEDIUM
    no_site = Lead(kind=LeadKind.ORGANIZATION, source="osm", external_id="n/2", title="Без сайта")
    no_site.relevance = Relevance.HIGH
    for l in (org, no_site, order("x")):
        store.insert_lead(l)
    h = HunterAdapter({"route": {"min_relevance": "medium"}, "monthly_quota": 25}, store,
                      http_factory(store)("hunter", {}), {"HUNTER_API_KEY": "k"})
    Router([h]).run([org, no_site, order("x")])
    assert api.call_count == 1 and api.calls[0].request.url.params["domain"] == "modern.example"
    assert org.external_results[0].details["emails"][0]["value"] == "info@modern.example"
    assert store.quota_used("hunter", org.external_results[0].processed_at.strftime("%Y-%m")) == 1
