import json
import random
from datetime import timedelta

import httpx

from conftest import http_factory
from leadgen.core.logging_setup import SecretFilter
from leadgen.core.models import Lead, LeadKind, Relevance, utcnow
from leadgen.notifications.phrases import PHRASES, PhrasePicker
from leadgen.notifications.telegram import TelegramNotifier, format_lead

TOKEN = "123456789:AAEexampleexampleexampleexampleexample"
SEND = f"https://api.telegram.org/bot{TOKEN}/sendMessage"
CFG = {"notify_min_relevance": ["high", "medium"], "max_lead_messages_per_run": 2, "error_cooldown_hours": 6}


def notifier(store, live=True):
    return TelegramNotifier(store, http_factory(store)("telegram", {}), TOKEN, "42", CFG, live=live)


def lead(i, rel=Relevance.HIGH, score=80):
    l = Lead(kind=LeadKind.ORDER, source="fl_ru", external_id=str(i), title=f"Нужен бот <{i}>", url=f"https://x/{i}",
             description=f"Описание {i} & детали", budget=15000, currency="RUB", published_at=utcnow())
    l.relevance, l.score = rel, score
    return l


def test_phrase_sets_are_big_and_rotate_without_repeats():
    assert sum(len(v) for v in PHRASES.values()) >= 60
    assert all(len(v) >= 5 for v in PHRASES.values())
    p = PhrasePicker(avoid_last=5, rng=random.Random(1))
    seq = [p.pick("new_leads") for _ in range(60)]
    for i in range(len(seq) - 5):
        assert len(set(seq[i:i + 6])) == 6                                   # нет повторов в окне


def test_lead_message_contains_required_fields():
    text = format_lead(lead(1), "Опа!", final_score=70)
    for part in ("Опа!", "Нужен бот &lt;1&gt;", "Бюджет: 15 000 RUB", "Источник: fl_ru", "Оценка системы: 80/100",
                 'href="https://x/1"'):
        assert part in text


def test_dry_run_sends_nothing(store, no_network):
    route = no_network.post(SEND)
    n = notifier(store, live=False)
    store.insert_lead(lead(1))
    assert n.notify_leads([(lead(1), 80)]) == 1
    assert not route.called and n.outbox


def test_no_duplicate_notifications_and_digest(store, no_network):
    route = no_network.post(SEND).mock(return_value=httpx.Response(200, json={"ok": True}))
    leads = [lead(i) for i in range(5)] + [lead(9, Relevance.LOW)]
    for l in leads:
        store.insert_lead(l)
    n = notifier(store)
    n.notify_leads([(l, l.score) for l in leads])
    assert route.call_count == 3                                             # 2 отдельных + 1 дайджест, LOW — нет
    assert "И ещё 3" in json.loads(route.calls[2].request.content)["text"]
    n.notify_leads([(l, l.score) for l in leads])
    assert route.call_count == 3                                             # повторно не шлём


def test_errors_aggregated_and_cooldown(store, no_network):
    route = no_network.post(SEND).mock(return_value=httpx.Response(200, json={"ok": True}))
    n = notifier(store)
    probs = [{"module": "fl_ru", "message": "HTTP 503", "scope": "source", "signature": "a"},
             {"module": "notion", "message": "down", "scope": "integration", "signature": "b"}]
    n.notify_problems(probs)
    assert route.call_count == 1
    text = json.loads(route.calls[0].request.content)["text"]
    assert "fl_ru" in text and "notion" in text and "только этот источник" in text
    n.notify_problems(probs)
    assert route.call_count == 1                                             # та же ошибка — не спамим


def test_telegram_failure_does_not_raise(store, no_network):
    no_network.post(SEND).mock(return_value=httpx.Response(400, json={"ok": False}))
    store.insert_lead(lead(1))
    assert notifier(store).notify_leads([(lead(1), 80)]) == 0
    assert not store.is_notified(lead(1).lead_id)


def test_daily_summary_once(store, no_network):
    route = no_network.post(SEND).mock(return_value=httpx.Response(200, json={"ok": True}))
    n = TelegramNotifier(store, http_factory(store)("telegram", {}), TOKEN, "42", {"send_daily_summary": True}, live=True)
    n.notify_summary({"sources_run": 1})
    n.notify_summary({"sources_run": 1})
    assert route.call_count == 1


def test_secrets_scrubbed_from_logs():
    f = SecretFilter(["my-notion-secret-value"])
    s = f.scrub(f"url https://api.telegram.org/bot{TOKEN}/x key=my-notion-secret-value api_key=zzz")
    assert TOKEN not in s and "my-notion-secret-value" not in s and "zzz" not in s
