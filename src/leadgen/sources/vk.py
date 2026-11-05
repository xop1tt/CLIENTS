"""Открытые сообщества ВКонтакте через официальный VK API (wall.get) с сервисным ключом приложения.

Сервисный ключ бесплатен (создаётся в своём приложении на dev.vk.com). Поиск по всем постам
(newsfeed.search) сервисным ключом недоступен, поэтому читаем стены заданных сообществ.
"""
from __future__ import annotations

from datetime import datetime, timezone
from typing import Any

from leadgen.core.http import HttpError
from leadgen.core.models import Lead, LeadKind
from leadgen.sources.base import FetchResult, Source, extract_contacts, keyword_prefilter

API = "https://api.vk.com/method/wall.get"
API_VERSION = "5.199"


class VkWallSource(Source):
    type_name = "vk_wall"

    def is_configured(self) -> tuple[bool, str]:
        if not self.secrets.get("VK_SERVICE_TOKEN"):
            return False, "нет секрета VK_SERVICE_TOKEN"
        if not self.cfg.get("communities"):
            return False, "список сообществ пуст (communities)"
        return True, ""

    def fetch(self, since: datetime | None, cursor: dict[str, Any]) -> FetchResult:
        res = FetchResult(cursor=dict(cursor))
        token = self.secrets["VK_SERVICE_TOKEN"]
        keywords = self.cfg.get("prefilter_keywords", [])
        page_size = int(self.cfg.get("page_size", 50))
        max_pages = int(self.cfg.get("max_pages", 2))
        for domain in self.cfg.get("communities", []):
            last_id = int(res.cursor.get(domain, 0))
            newest = last_id
            reached = last_id == 0
            for page in range(max_pages):
                params = {"domain": domain, "count": page_size, "offset": page * page_size,
                          "access_token": token, "v": API_VERSION}
                try:
                    data = self.http.get(API, params=params).json()
                except (HttpError, ValueError) as e:
                    res.partial_errors.append(f"{domain}: {e}")
                    break
                if "error" in data:
                    res.partial_errors.append(f"{domain}: VK API {data['error'].get('error_code')}:"
                                              f" {data['error'].get('error_msg')}")
                    break
                items = data.get("response", {}).get("items", [])
                if not items:
                    break
                for it in items:
                    pid = int(it["id"])
                    if pid <= last_id:
                        if not it.get("is_pinned"):
                            reached = True
                        continue
                    newest = max(newest, pid)
                    text = it.get("text", "")
                    if not text or not keyword_prefilter(text, keywords):
                        continue
                    owner = it.get("owner_id")
                    res.leads.append(Lead(
                        kind=LeadKind.ORDER, source=self.name, external_id=f"{owner}_{pid}",
                        title=text.split("\n", 1)[0][:200], description=text[:4000],
                        url=f"https://vk.com/wall{owner}_{pid}",
                        published_at=datetime.fromtimestamp(int(it.get("date", 0)), tz=timezone.utc),
                        contacts=extract_contacts(text), raw={"community": domain},
                    ))
                if reached or page_size * (page + 1) >= data.get("response", {}).get("count", 0):
                    reached = True
                    break
            if not reached:
                res.warnings.append(f"{domain}: возможен пропуск постов (увеличьте max_pages)")
            res.cursor[domain] = newest
        return res
