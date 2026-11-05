"""RSS/Atom-ленты (FL.ru и любые другие публичные ленты заказов).

Экономия: условные запросы (ETag / If-Modified-Since), запоминание ID обработанных записей.
"""
from __future__ import annotations

import calendar
from datetime import datetime, timezone
from typing import Any

import feedparser
from bs4 import BeautifulSoup

from leadgen.core.http import HttpError
from leadgen.core.models import Lead, LeadKind
from leadgen.sources.base import FetchResult, Source, extract_contacts, keyword_prefilter

MAX_SEEN = 500


def _entry_dt(entry: Any) -> datetime | None:
    for key in ("published_parsed", "updated_parsed"):
        t = entry.get(key)
        if t:
            return datetime.fromtimestamp(calendar.timegm(t), tz=timezone.utc)
    return None


def html_to_text(html: str) -> str:
    return BeautifulSoup(html or "", "html.parser").get_text(" ", strip=True)


class RssSource(Source):
    type_name = "rss"

    def is_configured(self) -> tuple[bool, str]:
        if not self.cfg.get("feeds"):
            return False, "не задан список лент (feeds)"
        return True, ""

    def fetch(self, since: datetime | None, cursor: dict[str, Any]) -> FetchResult:
        res = FetchResult(cursor=dict(cursor))
        keywords = self.cfg.get("prefilter_keywords", [])
        del since  # новизна определяется по ID записей, а не по времени
        for feed in self.cfg.get("feeds", []):
            url = feed["url"] if isinstance(feed, dict) else str(feed)
            fc = dict(res.cursor.get(url, {}))
            headers = {}
            if fc.get("etag"):
                headers["If-None-Match"] = fc["etag"]
            if fc.get("last_modified"):
                headers["If-Modified-Since"] = fc["last_modified"]
            try:
                resp = self.http.get(url, headers=headers)
            except HttpError as e:
                res.partial_errors.append(f"{url}: {e}")
                continue
            if resp.status_code == 304:
                continue
            parsed = feedparser.parse(resp.content)
            if parsed.bozo and not parsed.entries:
                res.partial_errors.append(f"{url}: не удалось разобрать ленту")
                continue
            seen = set(fc.get("seen", []))
            new_ids: list[str] = []
            for entry in parsed.entries:
                eid = entry.get("id") or entry.get("link") or entry.get("title", "")
                published = _entry_dt(entry)
                if not eid or eid in seen:
                    continue
                new_ids.append(eid)
                title = html_to_text(entry.get("title", ""))[:300]
                desc = html_to_text(entry.get("summary", "") or entry.get("description", ""))
                if not keyword_prefilter(f"{title} {desc}", keywords):
                    continue
                res.leads.append(Lead(
                    kind=LeadKind.ORDER, source=self.name, external_id=eid, title=title, url=entry.get("link", ""),
                    description=desc[:4000], published_at=published, contacts=extract_contacts(desc),
                    category=(entry.get("tags") or [{}])[0].get("term") if entry.get("tags") else None,
                ))
            # Признак пропуска: в ленте нет ни одной уже виденной записи — лента короче пропущенного периода.
            entry_ids = {e.get("id") or e.get("link") for e in parsed.entries}
            if seen and parsed.entries and not (seen & entry_ids):
                res.warnings.append(f"{url}: лента короче пропущенного периода, часть заявок могла не попасть")
            fc["seen"] = (new_ids + [s for s in fc.get("seen", []) if s not in new_ids])[:MAX_SEEN]
            fc["etag"] = resp.headers.get("ETag")
            fc["last_modified"] = resp.headers.get("Last-Modified")
            res.cursor[url] = fc
        return res
