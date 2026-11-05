"""Экспорт базы в JSON/CSV для резервного копирования (файлы не коммитить в публичный репозиторий!)."""
from __future__ import annotations

import csv
import json
from pathlib import Path

from leadgen.storage.sqlite_store import Store

CSV_FIELDS = ["lead_id", "kind", "source", "title", "url", "relevance", "score", "budget", "currency", "region",
              "category", "project_type", "published_at", "discovered_at", "contacts", "address", "phone",
              "website", "facts", "assumptions"]


def export(store: Store, path: Path, fmt: str = "json") -> int:
    leads = [l for l in store.iter_leads("fingerprint NOT LIKE 'remote:%'")]
    path.parent.mkdir(parents=True, exist_ok=True)
    if fmt == "json":
        payload = []
        for l in leads:
            d = json.loads(l.to_json())
            d["lead_id"] = l.lead_id
            d["external_results"] = [json.loads(json.dumps(r.__dict__, default=str))
                                     for r in store.external_results(l.lead_id)]
            payload.append(d)
        path.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
    else:
        with path.open("w", newline="", encoding="utf-8") as fh:
            w = csv.DictWriter(fh, fieldnames=CSV_FIELDS)
            w.writeheader()
            for l in leads:
                w.writerow({
                    "lead_id": l.lead_id, "kind": l.kind.value, "source": l.source, "title": l.title, "url": l.url,
                    "relevance": l.relevance.value, "score": l.score, "budget": l.budget, "currency": l.currency,
                    "region": l.region, "category": l.category, "project_type": l.project_type,
                    "published_at": l.published_at.isoformat() if l.published_at else "",
                    "discovered_at": l.discovered_at.isoformat(),
                    "contacts": json.dumps(l.contacts, ensure_ascii=False), "address": l.address, "phone": l.phone,
                    "website": l.website, "facts": " | ".join(l.facts), "assumptions": " | ".join(l.assumptions)})
    return len(leads)
