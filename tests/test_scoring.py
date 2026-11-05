from datetime import timedelta

from leadgen.core.models import Lead, LeadKind, Relevance, utcnow
from leadgen.scoring.scorer import merge_external, parse_budget, score_lead
from leadgen.core.models import ExternalResult


def order(title, desc="", age_h=1):
    return Lead(kind=LeadKind.ORDER, source="t", external_id=title, title=title, description=desc,
                published_at=utcnow() - timedelta(hours=age_h))


def test_parse_budget_variants():
    assert parse_budget("Бюджет: 25 000 руб") == (25000, "RUB")
    assert parse_budget("до 50к ₽") == (50000, "RUB")
    assert parse_budget("оплата 300$") == (300, "USD")
    assert parse_budget("нужно 3 страницы") == (None, None)


def test_real_request_is_high(base_settings):
    l = score_lead(order("Нужен Telegram-бот для записи клиентов",
                         "Ищем разработчика. Нужен телеграм-бот для салона: запись, напоминания, интеграция с Google "
                         "таблицами. Бюджет 25 000 руб. Срочно."), base_settings.section("scoring"))
    assert l.relevance == Relevance.HIGH
    assert l.project_type == "telegram_bot"
    assert l.budget == 25000


def test_offer_of_services_is_not_high(base_settings):
    l = score_lead(order("Сделаю сайт недорого", "Сделаю сайт на тильде, моё портфолио, беру заказы"),
                   base_settings.section("scoring"))
    assert l.relevance in (Relevance.REJECTED, Relevance.LOW)


def test_stop_words_and_offtopic(base_settings):
    cfg = base_settings.section("scoring")
    assert score_lead(order("Нужен сайт", "Работа в штат, оклад 80 000"), cfg).relevance == Relevance.REJECTED
    assert score_lead(order("Нарисовать логотип", "Нужен дизайнер логотипа"), cfg).relevance == Relevance.REJECTED


def test_spam_and_old(base_settings):
    cfg = base_settings.section("scoring")
    spam = score_lead(order("Нужен сайт", "Пассивный доход! Подписывайся, розыгрыш"), cfg)
    assert spam.relevance in (Relevance.REJECTED, Relevance.LOW)
    old = score_lead(order("Нужен сайт для компании", "Ищем разработчика сайта", age_h=24 * 30), cfg)
    assert old.relevance == Relevance.REJECTED and "устарело" in old.score_reasons


def test_organization_scoring_keeps_facts_and_assumptions_separate(base_settings):
    org = Lead(kind=LeadKind.ORGANIZATION, source="osm", external_id="node/1", title="Салон", category="beauty",
               phone="+7", facts=["В OpenStreetMap у организации не указан сайт"],
               assumptions=["Возможно, пригодится сайт с онлайн-записью"], raw={"signals": {"no_website": True}})
    score_lead(org, base_settings.section("scoring"))
    assert org.relevance == Relevance.HIGH
    assert all("Возможно" not in f for f in org.facts)
    assert all("Возможно" in a for a in org.assumptions)


def test_external_score_is_weighted_not_absolute(base_settings):
    l = order("x")
    l.score = 80
    l.external_results = [ExternalResult(service="w", processed_at=utcnow(), ok=True, score=0)]
    assert merge_external(l, base_settings.section("scoring")) == 60.0
    l.external_results.append(ExternalResult(service="bad", processed_at=utcnow(), ok=False, error="x"))
    assert merge_external(l, base_settings.section("scoring")) == 60.0
