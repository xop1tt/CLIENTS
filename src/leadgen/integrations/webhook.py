"""Универсальный webhook: передача лида в Make, n8n (Community Edition на своём компьютере) или
любой другой сервис. Ответ (необязательно) — JSON {"score": 0..100, "label": "...", "comment": "...",
"details": {...}}. Запрос подписывается HMAC-SHA256 (заголовок X-Leadgen-Signature)."""
from __future__ import annotations

import hashlib
import hmac
import json

from leadgen.core.http import HttpError
from leadgen.core.models import ExternalResult, Lead, utcnow
from leadgen.integrations.base import Adapter


class WebhookAdapter(Adapter):
    name = "webhook"
    required_secrets = ("WEBHOOK_URL",)

    def process(self, lead: Lead) -> ExternalResult:
        body = json.dumps(self.payload(lead), ensure_ascii=False).encode("utf-8")
        headers = {"Content-Type": "application/json"}
        if secret := self.secrets.get("WEBHOOK_SECRET"):
            headers["X-Leadgen-Signature"] = hmac.new(secret.encode(), body, hashlib.sha256).hexdigest()
        try:
            resp = self.http.post(self.secrets["WEBHOOK_URL"], content=body, headers=headers)
        except HttpError as e:
            # URL webhook'а сам по себе секрет (Make/n8n) — в тексте ошибки его не должно быть
            raise HttpError(f"webhook ответил ошибкой (HTTP {e.status or 'нет ответа'})", e.status, e.transient) from None
        self.consume_quota()
        data = {}
        if "json" in resp.headers.get("content-type", ""):
            try:
                data = resp.json() or {}
            except ValueError:
                data = {}
        score = data.get("score")
        try:
            score = float(score) if score is not None else None
        except (TypeError, ValueError):
            score = None
        return ExternalResult(service=self.name, processed_at=utcnow(), ok=True, score=score,
                              label=str(data.get("label"))[:100] if data.get("label") else None,
                              details={"comment": str(data.get("comment", ""))[:500],
                                       **({"details": data["details"]} if isinstance(data.get("details"), dict) else {})})
