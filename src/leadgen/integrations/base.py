"""Универсальная система адаптеров внешних сервисов.

Каждый адаптер: включается/выключается независимо, имеет свои настройки, квоты, статус и журнал ошибок,
получает только нужные ему поля и никогда не блокирует остальную систему.
"""
from __future__ import annotations

import logging
from typing import Any

from leadgen.core.http import BudgetExceeded, HttpError, SourceHttp
from leadgen.core.models import ExternalResult, Lead, LeadKind, Relevance, utcnow
from leadgen.storage.sqlite_store import Store

log = logging.getLogger(__name__)

RELEVANCE_ORDER = [Relevance.REJECTED, Relevance.LOW, Relevance.MEDIUM, Relevance.HIGH]


class QuotaExceeded(Exception):
    pass


class Adapter:
    name = "base"
    required_secrets: tuple[str, ...] = ()

    def __init__(self, cfg: dict[str, Any], store: Store, http: SourceHttp, secrets: dict[str, str]):
        self.cfg = cfg
        self.store = store
        self.http = http
        self.secrets = secrets
        self.status = "idle"
        self.errors: list[str] = []

    # --- настройки ---
    def missing_secrets(self) -> list[str]:
        return [s for s in self.required_secrets if not self.secrets.get(s)]

    def accepts(self, lead: Lead) -> bool:
        """Правила маршрутизации из конфигурации."""
        route = self.cfg.get("route", {})
        kinds = route.get("kinds")
        if kinds and lead.kind.value not in kinds:
            return False
        if lead.source in route.get("exclude_sources", []):
            return False
        min_rel = Relevance(route.get("min_relevance", "medium"))
        return RELEVANCE_ORDER.index(lead.relevance) >= RELEVANCE_ORDER.index(min_rel)

    def payload(self, lead: Lead) -> dict[str, Any]:
        """Только необходимые поля (минимизация передаваемых данных)."""
        fields = self.cfg.get("fields") or ["lead_id", "kind", "title", "description", "source", "url"]
        full = {"lead_id": lead.lead_id, "kind": lead.kind.value, "title": lead.title,
                "description": lead.description[:3000], "source": lead.source, "url": lead.url,
                "budget": lead.budget, "currency": lead.currency, "region": lead.region,
                "category": lead.category, "project_type": lead.project_type, "score": lead.score,
                "relevance": lead.relevance.value, "website": lead.website}
        return {k: full[k] for k in fields if k in full}

    # --- квоты ---
    def _period(self) -> str:
        return utcnow().strftime("%Y-%m")

    def check_quota(self) -> None:
        limit = self.cfg.get("monthly_quota")
        if limit is not None and self.store.quota_used(self.name, self._period()) >= int(limit):
            raise QuotaExceeded(f"{self.name}: исчерпана месячная квота {limit}")

    def consume_quota(self, n: int = 1) -> None:
        self.store.quota_add(self.name, self._period(), n)

    def process(self, lead: Lead) -> ExternalResult:
        raise NotImplementedError


class Router:
    """Маршрутизация: собственная фильтрация → подходящие адаптеры → результаты отдельно от исходных данных."""

    def __init__(self, adapters: list[Adapter], max_failures: int = 3):
        self.adapters = adapters
        self.max_failures = max_failures

    def run(self, leads: list[Lead]) -> list[str]:
        problems: list[str] = []
        for ad in self.adapters:
            failures = 0
            per_run = int(ad.cfg.get("max_per_run", 10))
            sent = 0
            for lead in leads:
                if sent >= per_run or failures >= self.max_failures:
                    break
                if not ad.accepts(lead) or ad.store.was_sent_to(lead.lead_id, ad.name):
                    continue  # повторно одну и ту же заявку не отправляем
                try:
                    ad.check_quota()
                    result = ad.process(lead)
                except (QuotaExceeded, BudgetExceeded) as e:
                    ad.status = "quota"
                    problems.append(str(e))
                    break
                except (HttpError, ValueError, KeyError) as e:
                    failures += 1
                    result = ExternalResult(service=ad.name, processed_at=utcnow(), ok=False, error=str(e)[:300])
                    ad.errors.append(str(e))
                sent += 1
                ad.store.add_external_result(lead.lead_id, result)
                lead.external_results.append(result)
            if failures >= self.max_failures:
                ad.status = "failing"
                problems.append(f"{ad.name}: {failures} ошибок подряд, адаптер пропущен до следующего запуска")
            elif ad.status == "idle":
                ad.status = "ok"
        return problems
