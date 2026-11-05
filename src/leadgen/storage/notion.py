"""Notion API — постоянное хранилище заявок (бесплатный тариф Notion поддерживает интеграции API).

Минимизация обращений: проверка существования — один фильтрованный запрос по «Dedup Key»;
полная выгрузка базы не делается. Лимит Notion — в среднем 3 запроса/с, учитываем Retry-After.
"""
from __future__ import annotations

import logging
from datetime import datetime
from typing import Any, Iterator

from leadgen.core.http import SourceHttp
from leadgen.core.models import RELEVANCE_RU, Lead, LeadKind

log = logging.getLogger(__name__)

API = "https://api.notion.com/v1"
NOTION_VERSION = "2022-06-28"
TEXT_LIMIT = 1900

SCHEMA: dict[str, Any] = {
    "Name": {"title": {}},
    "Dedup Key": {"rich_text": {}},
    "Kind": {"select": {"options": [{"name": "Заявка"}, {"name": "Организация"}]}},
    "Source": {"select": {}},
    "URL": {"url": {}},
    "Relevance": {"select": {"options": [{"name": v} for v in RELEVANCE_RU.values()]}},
    "Score": {"number": {}},
    "Final Score": {"number": {}},
    "Budget": {"number": {}},
    "Currency": {"select": {}},
    "Region": {"rich_text": {}},
    "Category": {"rich_text": {}},
    "Project Type": {"select": {}},
    "Published": {"date": {}},
    "Discovered": {"date": {}},
    "Status": {"select": {"options": [{"name": "Новая"}, {"name": "В работе"}, {"name": "Отклонена"},
                                      {"name": "Выиграна"}]}},
    "Contacts": {"rich_text": {}},
    "Description": {"rich_text": {}},
    "Facts": {"rich_text": {}},
    "Assumptions": {"rich_text": {}},
    "Score Reasons": {"rich_text": {}},
    "External": {"rich_text": {}},
}


def _rt(text: str | None) -> dict[str, Any]:
    return {"rich_text": [{"text": {"content": (text or "")[:TEXT_LIMIT]}}] if text else []}


def _date(dt: datetime | None) -> dict[str, Any]:
    return {"date": {"start": dt.isoformat()} if dt else None}


def _sel(name: str | None) -> dict[str, Any]:
    return {"select": {"name": name.replace(",", " ")[:100]} if name else None}


def lead_properties(lead: Lead, final_score: float | None = None, include_status: bool = True) -> dict[str, Any]:
    contacts = "; ".join(f"{k}: {v}" for k, v in lead.contacts.items())
    if lead.kind == LeadKind.ORGANIZATION:
        extra = "; ".join(x for x in (lead.address, lead.phone and f"тел. {lead.phone}",
                                      lead.website and f"сайт {lead.website}") if x)
        contacts = "; ".join(x for x in (extra, contacts) if x)
    external = "\n".join(
        f"{r.service} {r.processed_at:%d.%m %H:%M}: " + (f"{r.label or ''} {r.score if r.score is not None else ''}"
                                                         if r.ok else f"ошибка: {r.error}")
        for r in lead.external_results)
    props: dict[str, Any] = {
        "Name": {"title": [{"text": {"content": (lead.title or "(без названия)")[:200]}}]},
        "Dedup Key": _rt(lead.lead_id),
        "Kind": _sel("Организация" if lead.kind == LeadKind.ORGANIZATION else "Заявка"),
        "Source": _sel(lead.source),
        "URL": {"url": lead.url or None},
        "Relevance": _sel(RELEVANCE_RU[lead.relevance]),
        "Score": {"number": lead.score},
        "Final Score": {"number": final_score if final_score is not None else lead.score},
        "Budget": {"number": lead.budget},
        "Currency": _sel(lead.currency),
        "Region": _rt(lead.region),
        "Category": _rt(lead.category),
        "Project Type": _sel(lead.project_type),
        "Published": _date(lead.published_at),
        "Discovered": _date(lead.discovered_at),
        "Contacts": _rt(contacts),
        "Description": _rt(lead.description),
        "Facts": _rt("\n".join(lead.facts)),
        "Assumptions": _rt("\n".join(lead.assumptions)),
        "Score Reasons": _rt("; ".join(lead.score_reasons)),
        "External": _rt(external),
    }
    if include_status:
        props["Status"] = _sel("Новая")
    return props


class NotionAdapter:
    name = "notion"

    def __init__(self, http: SourceHttp, token: str, database_id: str):
        self.http = http
        self.database_id = database_id.replace("-", "")
        self.headers = {"Authorization": f"Bearer {token}", "Notion-Version": NOTION_VERSION,
                        "Content-Type": "application/json"}

    def find_page(self, dedup_key: str) -> str | None:
        body = {"filter": {"property": "Dedup Key", "rich_text": {"equals": dedup_key}}, "page_size": 1}
        r = self.http.post(f"{API}/databases/{self.database_id}/query", json=body, headers=self.headers).json()
        results = r.get("results", [])
        return results[0]["id"] if results else None

    def create(self, lead: Lead, final_score: float | None = None) -> str:
        body = {"parent": {"database_id": self.database_id}, "properties": lead_properties(lead, final_score)}
        return self.http.post(f"{API}/pages", json=body, headers=self.headers).json()["id"]

    def update(self, page_id: str, lead: Lead, final_score: float | None = None) -> None:
        # Статус, который владелец мог поменять вручную, не перезаписываем
        body = {"properties": lead_properties(lead, final_score, include_status=False)}
        self.http.request("PATCH", f"{API}/pages/{page_id}", json=body, headers=self.headers)

    def upsert(self, lead: Lead, known_page_id: str | None = None, final_score: float | None = None) -> str:
        page_id = known_page_id or self.find_page(lead.lead_id)
        if page_id:
            self.update(page_id, lead, final_score)
            return page_id
        return self.create(lead, final_score)

    def iter_recent_keys(self, since: datetime, max_pages: int = 20) -> Iterator[tuple[str, str, str]]:
        """Восстановление состояния: только записи, обнаруженные после since (не вся база)."""
        body: dict[str, Any] = {"filter": {"property": "Discovered", "date": {"on_or_after": since.isoformat()}},
                                "page_size": 100}
        for _ in range(max_pages):
            r = self.http.post(f"{API}/databases/{self.database_id}/query", json=body, headers=self.headers).json()
            for page in r.get("results", []):
                props = page.get("properties", {})
                key = "".join(t.get("plain_text", "") for t in props.get("Dedup Key", {}).get("rich_text", []))
                src = (props.get("Source", {}).get("select") or {}).get("name", "")
                if key:
                    yield key, src, page["id"]
            if not r.get("has_more"):
                return
            body["start_cursor"] = r.get("next_cursor")

    def init_database(self, parent_page_id: str, title: str = "Lead Generator") -> str:
        body = {"parent": {"type": "page_id", "page_id": parent_page_id},
                "title": [{"type": "text", "text": {"content": title}}], "properties": SCHEMA}
        return self.http.post(f"{API}/databases", json=body, headers=self.headers).json()["id"]

    def check(self) -> dict[str, Any]:
        r = self.http.get(f"{API}/databases/{self.database_id}", headers=self.headers).json()
        missing = [p for p in SCHEMA if p not in r.get("properties", {})]
        return {"ok": not missing, "missing_properties": missing}
