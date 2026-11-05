"""Собственная фильтрация и scoring без AI: ключевые слова, правила и веса из конфигурации.

Итоговая оценка — это оценка системы (эвристика), а не установленный факт.
"""
from __future__ import annotations

import re
from datetime import timedelta
from typing import Any

from leadgen.core.models import Lead, LeadKind, Relevance, normalize_text, utcnow

_NUM = r"(\d[\d\s.,]*\d|\d)"
_BUDGET_RE = re.compile(
    _NUM + r"\s*(тыс\.?|тысяч|к|k|млн)?\s*(руб(?:лей|\.|ля)?|р\.|₽|rub|\$|usd|долл\w*|€|eur)", re.I)
_BUDGET_PREFIX_RE = re.compile(r"бюджет[:\s—-]*(?:до|от|около)?\s*" + _NUM + r"\s*(тыс\.?|тысяч|к|k|млн)?", re.I)

CURRENCIES = {"$": "USD", "usd": "USD", "€": "EUR", "eur": "EUR"}


def _to_number(raw: str, mult: str | None) -> float | None:
    s = raw.replace(" ", "").replace("\u00a0", "")
    if re.fullmatch(r"\d{1,3}([.,]\d{3})+", s):
        s = re.sub(r"[.,]", "", s)
    else:
        s = s.replace(",", ".")
    try:
        value = float(s)
    except ValueError:
        return None
    m = (mult or "").lower().rstrip(".")
    if m in ("тыс", "тысяч", "к", "k"):
        value *= 1000
    elif m == "млн":
        value *= 1_000_000
    return value


def parse_budget(text: str) -> tuple[float | None, str | None]:
    """Извлекает бюджет из текста. Возвращает (сумма, валюта) или (None, None)."""
    m = _BUDGET_RE.search(text or "")
    if m:
        cur_raw = m.group(3).lower()
        currency = CURRENCIES.get(cur_raw, "USD" if cur_raw.startswith("долл") else "RUB")
        value = _to_number(m.group(1), m.group(2))
        if value and (value >= 100 or currency != "RUB"):
            return value, currency
    m = _BUDGET_PREFIX_RE.search(text or "")
    if m:
        value = _to_number(m.group(1), m.group(2))
        if value and value >= 100:
            return value, "RUB"
    return None, None


def _contains_any(text: str, words: list[str]) -> list[str]:
    found = []
    for w in words:
        wn = normalize_text(w)
        if not wn:
            continue
        if re.search(r"(?<!\w)" + re.escape(wn), text):
            found.append(w)
    return found


def classify(score: float, thresholds: dict[str, float]) -> Relevance:
    if score >= thresholds.get("high", 70):
        return Relevance.HIGH
    if score >= thresholds.get("medium", 45):
        return Relevance.MEDIUM
    if score >= thresholds.get("low", 25):
        return Relevance.LOW
    return Relevance.REJECTED


class OrderScorer:
    """Оценка готовых заявок (биржи, каналы, посты)."""

    def __init__(self, cfg: dict[str, Any]):
        self.cfg = cfg
        self.w = cfg.get("weights", {})
        self.thresholds = cfg.get("thresholds", {})

    def score(self, lead: Lead) -> Lead:
        text = normalize_text(f"{lead.title} {lead.description}")
        reasons: list[str] = []
        total = 0.0

        stop = _contains_any(text, self.cfg.get("stop_words", []))
        if stop:
            lead.score, lead.relevance = 0.0, Relevance.REJECTED
            lead.score_reasons = [f"стоп-слова: {', '.join(stop[:3])}"]
            return lead

        # 1. Тематика разработки и тип проекта
        best_type, best_hits = None, 0
        for ptype, spec in self.cfg.get("project_types", {}).items():
            hits = len(_contains_any(text, spec.get("keywords", [])))
            if hits > best_hits:
                best_type, best_hits = ptype, hits
        if not best_hits:
            lead.score, lead.relevance = 0.0, Relevance.REJECTED
            lead.score_reasons = ["нет признаков разработки"]
            return lead
        lead.project_type = lead.project_type or best_type
        pts = self.w.get("topic", 30) * min(1.0, 0.6 + 0.2 * best_hits)
        total += pts
        reasons.append(f"тематика «{best_type}» (+{pts:.0f})")

        # 2. Конкретный запрос: «ищу/нужен/требуется»
        intent = _contains_any(text, self.cfg.get("intent_keywords", []))
        if intent:
            total += self.w.get("intent", 20)
            reasons.append(f"явный запрос: «{intent[0]}» (+{self.w.get('intent', 20)})")
        offers = _contains_any(text, self.cfg.get("offer_markers", []))
        if offers:
            total -= self.w.get("offer_penalty", 35)
            reasons.append("похоже на предложение услуг, а не заказ")

        # 3. Бюджет
        if lead.budget is None:
            lead.budget, lead.currency = parse_budget(f"{lead.title} {lead.description}")
        if lead.budget:
            total += self.w.get("budget", 15)
            reasons.append(f"указан бюджет (+{self.w.get('budget', 15)})")
            min_b = self.cfg.get("min_budget_rub", 0)
            if lead.currency == "RUB" and min_b and lead.budget < min_b:
                total -= self.w.get("low_budget_penalty", 10)
                reasons.append(f"бюджет ниже {min_b} ₽")

        # 4. Срочность
        if _contains_any(text, self.cfg.get("urgency_keywords", [])):
            total += self.w.get("urgency", 5)
            reasons.append("срочно")

        # 5. Полнота описания
        words = len(text.split())
        if words >= 40:
            total += self.w.get("completeness", 10)
            reasons.append("подробное описание")
        elif words < 8:
            total -= self.w.get("too_short_penalty", 10)
            reasons.append("слишком короткое описание")

        # 6. Тип заказчика
        if _contains_any(text, self.cfg.get("business_markers", [])):
            total += self.w.get("customer_type", 5)
            reasons.append("заказчик — бизнес")

        # 7. Выполнимость силами одного разработчика с Claude Code
        hard = _contains_any(text, self.cfg.get("hard_markers", []))
        if hard:
            total -= self.w.get("feasibility_penalty", 15)
            reasons.append(f"сложно выполнить удалённо/в одиночку: {hard[0]}")
        else:
            total += self.w.get("feasibility", 5)

        # 8. Спам
        spam = _contains_any(text, self.cfg.get("spam_markers", []))
        links = len(re.findall(r"https?://", lead.description or ""))
        if spam or links > 5:
            total -= self.w.get("spam_penalty", 40)
            reasons.append("признаки спама")

        # 9. Свежесть
        if lead.published_at:
            age = utcnow() - lead.published_at
            max_age = timedelta(days=self.cfg.get("max_age_days", 14))
            if age > max_age:
                lead.score, lead.relevance = 0.0, Relevance.REJECTED
                lead.score_reasons = reasons + ["устарело"]
                return lead
            if age <= timedelta(hours=24):
                total += self.w.get("freshness", 10)
                reasons.append("свежая публикация")

        lead.score = round(max(0.0, min(100.0, total)), 1)
        lead.relevance = classify(lead.score, self.thresholds)
        lead.score_reasons = reasons
        return lead


class OrganizationScorer:
    """Потенциальная привлекательность организации. Опирается на проверенные факты из site_checker."""

    def __init__(self, cfg: dict[str, Any]):
        self.cfg = cfg
        self.w = cfg.get("weights", {})
        self.thresholds = cfg.get("thresholds", {})

    def score(self, lead: Lead) -> Lead:
        signals: dict[str, bool] = lead.raw.get("signals", {})
        reasons: list[str] = []
        total = float(self.cfg.get("category_weights", {}).get(lead.category or "", self.w.get("base", 10)))
        reasons.append(f"категория «{lead.category}» (+{total:.0f})")
        for signal, label in (
            ("no_website", "сайт не указан в источнике"),
            ("site_unreachable", "сайт недоступен"),
            ("no_https", "нет HTTPS"),
            ("no_viewport", "нет мобильной вёрстки (meta viewport)"),
            ("outdated", "сайт выглядит устаревшим"),
            ("no_booking", "нет онлайн-записи (предположение о потребности)"),
        ):
            if signals.get(signal):
                pts = self.w.get(signal, 0)
                total += pts
                reasons.append(f"{label} (+{pts})")
        if lead.phone or lead.contacts:
            total += self.w.get("has_contacts", 5)
            reasons.append("есть публичный контакт")
        else:
            total -= self.w.get("no_contacts_penalty", 15)
            reasons.append("нет контактов")
        lead.score = round(max(0.0, min(100.0, total)), 1)
        lead.relevance = classify(lead.score, self.thresholds)
        lead.score_reasons = reasons
        return lead


def score_lead(lead: Lead, scoring_cfg: dict[str, Any]) -> Lead:
    if lead.kind == LeadKind.ORGANIZATION:
        return OrganizationScorer(scoring_cfg.get("organizations", {})).score(lead)
    return OrderScorer(scoring_cfg.get("orders", {})).score(lead)


def merge_external(lead: Lead, cfg: dict[str, Any]) -> float:
    """Итоговая оценка: собственная + взвешенные внешние (внешняя — не абсолютная истина)."""
    ext = [r for r in lead.external_results if r.ok and r.score is not None]
    if not ext:
        return lead.score
    weight = float(cfg.get("external_weight", 0.25))
    avg = sum(max(0.0, min(100.0, r.score)) for r in ext) / len(ext)
    return round((1 - weight) * lead.score + weight * avg, 1)
