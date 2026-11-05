"""Единая модель данных Lead.

Принцип: подтверждённые факты (facts) и предположения (assumptions) хранятся
раздельно. Оценка (score/relevance) — это оценка системы, а не факт.
"""
from __future__ import annotations

import hashlib
import json
import re
from dataclasses import asdict, dataclass, field
from datetime import datetime, timezone
from enum import Enum
from typing import Any


class LeadKind(str, Enum):
    ORDER = "order"                # готовая заявка (биржа, канал, пост)
    ORGANIZATION = "organization"  # организация — потенциальный клиент


class Relevance(str, Enum):
    HIGH = "high"
    MEDIUM = "medium"
    LOW = "low"
    REJECTED = "rejected"


RELEVANCE_RU = {
    Relevance.HIGH: "Высокая",
    Relevance.MEDIUM: "Средняя",
    Relevance.LOW: "Низкая",
    Relevance.REJECTED: "Не подходит",
}


def utcnow() -> datetime:
    return datetime.now(timezone.utc).replace(microsecond=0)


def normalize_text(text: str) -> str:
    text = (text or "").lower().replace("ё", "е")
    text = re.sub(r"https?://\S+", " ", text)
    text = re.sub(r"[^\w\s]", " ", text)
    return re.sub(r"\s+", " ", text).strip()


def _h(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()[:24]


@dataclass
class ExternalResult:
    """Результат внешнего сервиса. Хранится отдельно, исходные данные не меняет."""
    service: str
    processed_at: datetime
    ok: bool
    score: float | None = None
    label: str | None = None
    details: dict[str, Any] = field(default_factory=dict)
    error: str | None = None


@dataclass
class Lead:
    kind: LeadKind
    source: str
    external_id: str          # ID внутри источника (id поста, id OSM-объекта...)
    title: str
    url: str = ""
    description: str = ""
    published_at: datetime | None = None
    discovered_at: datetime = field(default_factory=utcnow)
    budget: float | None = None
    currency: str | None = None
    region: str | None = None
    contacts: dict[str, str] = field(default_factory=dict)
    category: str | None = None
    project_type: str | None = None
    customer_name: str | None = None
    # Организации
    address: str | None = None
    phone: str | None = None
    website: str | None = None
    # Факты и предположения раздельно
    facts: list[str] = field(default_factory=list)
    assumptions: list[str] = field(default_factory=list)
    # Оценка системы
    score: float = 0.0
    relevance: Relevance = Relevance.REJECTED
    score_reasons: list[str] = field(default_factory=list)
    status: str = "new"
    external_results: list[ExternalResult] = field(default_factory=list)
    raw: dict[str, Any] = field(default_factory=dict)

    @property
    def lead_id(self) -> str:
        """Стабильный внутренний ID: источник + ID в источнике."""
        return _h(f"{self.source}|{self.external_id}")

    @property
    def content_fingerprint(self) -> str:
        """Отпечаток содержимого — ловит одну и ту же заявку, опубликованную в разных местах."""
        if self.kind == LeadKind.ORGANIZATION:
            domain = ""
            if self.website:
                domain = re.sub(r"^(https?://)?(www\.)?", "", self.website.lower()).split("/")[0]
            phone = re.sub(r"\D", "", self.phone or "")[-10:]
            key = domain or phone or f"{normalize_text(self.title)}|{normalize_text(self.address or '')}"
            return _h("org|" + key)
        body = normalize_text(f"{self.title} {self.description}")[:400]
        return _h("order|" + body)

    def to_json(self) -> str:
        d = asdict(self)
        d["kind"] = self.kind.value
        d["relevance"] = self.relevance.value
        return json.dumps(d, ensure_ascii=False, default=_json_default)

    @classmethod
    def from_json(cls, data: str | dict) -> "Lead":
        d = json.loads(data) if isinstance(data, str) else dict(data)
        d["kind"] = LeadKind(d["kind"])
        d["relevance"] = Relevance(d.get("relevance", "rejected"))
        for k in ("published_at", "discovered_at"):
            if d.get(k):
                d[k] = datetime.fromisoformat(d[k])
        d["external_results"] = [
            ExternalResult(**{**r, "processed_at": datetime.fromisoformat(r["processed_at"])})
            for r in d.get("external_results", [])
        ]
        return cls(**d)


def _json_default(o: Any) -> Any:
    if isinstance(o, datetime):
        return o.isoformat()
    if isinstance(o, Enum):
        return o.value
    raise TypeError(type(o))
