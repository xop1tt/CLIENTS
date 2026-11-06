"""Организации из OpenStreetMap через Overpass API (бесплатно, данные под лицензией ODbL —
хранение разрешено с указанием «© участники OpenStreetMap»).

Это бесплатная замена Яндекс Картам и 2ГИС: их бесплатные условия запрещают сохранять данные
(Яндекс) или дают только месячный демо-ключ (2ГИС).

Экономия запросов:
1. История запросов: одинаковый (регион, категория) не повторяется чаще refresh_days.
2. Уже известные объекты не обрабатываются повторно; проверка сайта — не чаще recheck_days.
3. Один Overpass-запрос на пару регион×категория, без географического дробления.
"""
from __future__ import annotations

import hashlib
from datetime import datetime, timedelta
from typing import Any

from leadgen.core.http import BudgetExceeded, HttpError, SourceHttp
from leadgen.core.models import Lead, LeadKind, utcnow
from leadgen.sources.base import FetchResult, Source
from leadgen.sources.site_checker import check_site

DEFAULT_ENDPOINT = "https://overpass-api.de/api/interpreter"
NEEDS_BOOKING = {"beauty", "dance", "fitness", "medical", "education", "restaurant"}


def build_query(area: dict[str, Any], tag_filters: list[str], timeout: int = 60) -> str:
    name = str(area["name"]).replace('"', "")
    admin = area.get("admin_level")
    admin_part = f'["admin_level"="{int(admin)}"]' if admin else ""
    body = "".join(f"nwr{flt}(area.a);" for flt in tag_filters)
    # Название города в OSM часто на местном языке (Ереван — «Երևան»), поэтому ищем и по name:ru/name:en
    alt = "".join(f'area["{k}"="{name}"]["boundary"="administrative"]{admin_part}->.a{i};'
                  for i, k in enumerate(("name", "name:ru", "name:en")))
    return (f"[out:json][timeout:{timeout}];{alt}(.a0;.a1;.a2;)->.a;"
            f"({body});out center tags;")


def _address(tags: dict[str, str]) -> str | None:
    parts = [tags.get("addr:city"), tags.get("addr:street"), tags.get("addr:housenumber")]
    s = ", ".join(p for p in parts if p)
    return s or None


class OsmOverpassSource(Source):
    type_name = "osm_overpass"

    def __init__(self, *a: Any, site_http: SourceHttp | None = None, **kw: Any):
        super().__init__(*a, **kw)
        self.site_http = site_http

    def is_configured(self) -> tuple[bool, str]:
        if not self.cfg.get("regions") or not self.cfg.get("categories"):
            return False, "не заданы regions/categories"
        return True, ""

    def item_count(self) -> int:
        return max(1, len(self.cfg.get("regions", [])) * len(self.cfg.get("categories", {})))

    def fetch(self, since: datetime | None, cursor: dict[str, Any]) -> FetchResult:
        res = FetchResult(cursor=dict(cursor))
        now = utcnow()
        endpoint = self.cfg.get("endpoint", DEFAULT_ENDPOINT)
        refresh = timedelta(days=float(self.cfg.get("refresh_days", 7)))
        recheck = timedelta(days=float(self.cfg.get("recheck_days", 60)))
        max_new = int(self.cfg.get("max_new_per_run", 40))
        added = 0
        for region in self.cfg["regions"]:
            for cat, spec in self.cfg["categories"].items():
                query = build_query(region, spec["filters"], int(self.cfg.get("timeout", 60)))
                qhash = hashlib.sha256(query.encode()).hexdigest()[:24]
                last = self.store.query_last_run(qhash)
                if last and now - last < refresh:
                    continue  # идентичный запрос уже выполнялся недавно — не тратим квоту
                try:
                    data = self.http.post(endpoint, data={"data": query}).json()
                except BudgetExceeded as e:
                    res.warnings.append(str(e))
                    return res
                except (HttpError, ValueError) as e:
                    res.partial_errors.append(f"{region['name']}/{cat}: {e}")
                    continue
                elements = data.get("elements", [])
                self.store.record_query(qhash, self.name, f"{region['name']}|{cat}", len(elements))
                for el in elements:
                    if added >= max_new:
                        res.warnings.append(f"достигнут лимит {max_new} новых организаций за запуск, остальные — в следующий раз")
                        # запрос обработан частично — забываем его, чтобы дочитать при следующем запуске
                        # (уже обработанные объекты отсекутся по seen_objects без повторных проверок сайтов)
                        self.store.forget_query(qhash)
                        return res
                    lead = self._to_lead(el, cat, spec, region, now, recheck)
                    if lead:
                        res.leads.append(lead)
                        added += 1
        return res

    def _to_lead(self, el: dict[str, Any], cat: str, spec: dict[str, Any], region: dict[str, Any],
                 now: datetime, recheck: timedelta) -> Lead | None:
        tags = el.get("tags", {})
        name = tags.get("name")
        if not name:
            return None
        oid = f"{el.get('type')}/{el.get('id')}"
        checked = self.store.object_checked_at(self.name, oid)
        if checked and now - checked < recheck:
            return None  # уже обработан и не пора перепроверять
        website = tags.get("website") or tags.get("contact:website") or tags.get("url")
        phone = tags.get("phone") or tags.get("contact:phone")
        email = tags.get("email") or tags.get("contact:email")
        contacts = {k: v for k, v in (("phone", phone), ("email", email),
                                       ("vk", tags.get("contact:vk")), ("telegram", tags.get("contact:telegram")))
                    if v}
        signals: dict[str, bool] = {}
        facts = ["Данные © участники OpenStreetMap (ODbL)"]
        assumptions: list[str] = []
        if not website:
            signals["no_website"] = True
            facts.append("В OpenStreetMap у организации не указан сайт (сам сайт при этом может существовать)")
        elif self.site_http is not None:
            try:
                chk = check_site(self.site_http, website, now)
            except BudgetExceeded:
                chk = None
                assumptions.append("Сайт не проверен: исчерпан лимит проверок на этот запуск")
            if chk:
                facts.extend(chk.facts)
                signals["site_unreachable"] = not chk.reachable
                if chk.reachable:
                    signals["no_https"] = not chk.https
                    signals["no_viewport"] = not chk.viewport
                    if chk.copyright_year and chk.copyright_year <= now.year - 4:
                        signals["outdated"] = True
                    if not chk.has_booking and spec.get("group") in NEEDS_BOOKING:
                        signals["no_booking"] = True
                        assumptions.append("Возможно, нужна онлайн-запись (на сайте её признаков не найдено)")
        if signals.get("no_website") and spec.get("group") in NEEDS_BOOKING:
            assumptions.append("Возможно, пригодится сайт с онлайн-записью")
        self.store.mark_object_checked(self.name, oid)
        center = el.get("center") or {"lat": el.get("lat"), "lon": el.get("lon")}
        return Lead(
            kind=LeadKind.ORGANIZATION, source=self.name, external_id=oid, title=name, category=cat,
            url=f"https://www.openstreetmap.org/{oid}", region=region.get("name"),
            address=_address(tags), phone=phone, website=website, contacts=contacts,
            customer_name=name, facts=facts, assumptions=assumptions,
            description=f"{spec.get('label', cat)} · {region.get('name')}",
            raw={"signals": signals, "lat": center.get("lat"), "lon": center.get("lon")},
        )
