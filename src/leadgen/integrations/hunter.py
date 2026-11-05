"""Hunter.io Domain Search — обогащение организаций с сайтом публичными email-адресами компании.

Бесплатный тариф Hunter: 50 кредитов в месяц (hunter.io/pricing, проверено 05.11.2026).
Адаптер сам держит месячную квоту ниже этого лимита (monthly_quota в конфиге).
AI-оценки через API Hunter не даёт — только данные о контактах.
Покрытие российского малого бизнеса, скорее всего, низкое (это предположение, не проверено).
"""
from __future__ import annotations

from urllib.parse import urlparse

from leadgen.core.models import ExternalResult, Lead, LeadKind, utcnow
from leadgen.integrations.base import Adapter

API = "https://api.hunter.io/v2/domain-search"


class HunterAdapter(Adapter):
    name = "hunter"
    required_secrets = ("HUNTER_API_KEY",)

    def accepts(self, lead: Lead) -> bool:
        return lead.kind == LeadKind.ORGANIZATION and bool(lead.website) and \
            not lead.raw.get("signals", {}).get("site_unreachable") and super().accepts(lead)

    def process(self, lead: Lead) -> ExternalResult:
        url = lead.website if "://" in (lead.website or "") else f"http://{lead.website}"
        domain = (urlparse(url).hostname or "").removeprefix("www.")
        data = self.http.get(API, params={"domain": domain, "limit": 10,
                                          "api_key": self.secrets["HUNTER_API_KEY"]}).json()
        self.consume_quota()
        d = data.get("data", {})
        emails = [{"value": e.get("value"), "type": e.get("type"), "confidence": e.get("confidence"),
                   "verification": (e.get("verification") or {}).get("status")} for e in d.get("emails", [])]
        return ExternalResult(service=self.name, processed_at=utcnow(), ok=True, score=None,
                              label=f"email: {len(emails)}",
                              details={"domain": domain, "organization": d.get("organization"),
                                       "pattern": d.get("pattern"), "emails": emails})
