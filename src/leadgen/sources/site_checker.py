"""Проверка сайта организации. Возвращает только то, что реально проверено (факты),
и отдельно — предположения. Один GET на сайт, результат кэшируется по домену."""
from __future__ import annotations

import re
from dataclasses import dataclass, field
from datetime import datetime
from urllib.parse import urlparse

from bs4 import BeautifulSoup

from leadgen.core.http import BudgetExceeded, HttpError, SourceHttp

BOOKING_MARKERS = ("онлайн-запис", "онлайн запис", "записаться", "запись онлайн", "yclients", "dikidi",
                   "sonline", "booking", "забронировать", "бронирование", "arnica", "altegio")
YEAR_RE = re.compile(r"(?:©|&copy;|copyright)\s*(?:\d{4}\s*[-–—]\s*)?(20\d{2}|19\d{2})", re.I)


@dataclass
class SiteCheck:
    url: str
    reachable: bool
    checked_at: datetime
    status: int | None = None
    https: bool = False
    viewport: bool = False
    copyright_year: int | None = None
    has_booking: bool = False
    error: str | None = None
    facts: list[str] = field(default_factory=list)


def normalize_url(url: str) -> str:
    url = url.strip()
    if not re.match(r"^https?://", url, re.I):
        url = "http://" + url
    return url


def is_public_http_url(url: str) -> bool:
    """Валидация внешних данных: только http(s) и не локальные адреса."""
    try:
        p = urlparse(url)
    except ValueError:
        return False
    host = (p.hostname or "").lower()
    if p.scheme not in ("http", "https") or not host or "." not in host:
        return False
    if host in ("localhost",) or host.endswith(".local") or re.match(r"^(127|10|192\.168|169\.254|0)\.", host):
        return False
    if re.match(r"^172\.(1[6-9]|2\d|3[01])\.", host):
        return False
    return True


def check_site(http: SourceHttp, url: str, now: datetime) -> SiteCheck:
    url = normalize_url(url)
    if not is_public_http_url(url):
        return SiteCheck(url=url, reachable=False, checked_at=now, error="некорректный адрес",
                         facts=["В источнике указан некорректный адрес сайта"])
    try:
        resp = http.get(url)
    except BudgetExceeded:
        raise
    except HttpError as e:
        return SiteCheck(url=url, reachable=False, checked_at=now, status=e.status, error=str(e),
                         facts=[f"Сайт не открылся при проверке {now:%d.%m.%Y}: {e}"])
    final = str(resp.url)
    html = resp.text[:500_000]
    soup = BeautifulSoup(html, "html.parser")
    chk = SiteCheck(url=final, reachable=True, checked_at=now, status=resp.status_code,
                    https=final.lower().startswith("https://"),
                    viewport=soup.find("meta", attrs={"name": re.compile("^viewport$", re.I)}) is not None)
    years = [int(y) for y in YEAR_RE.findall(html)]
    chk.copyright_year = max(years) if years else None
    low = html.lower()
    chk.has_booking = any(m in low for m in BOOKING_MARKERS)
    chk.facts.append(f"Сайт открылся ({resp.status_code}) при проверке {now:%d.%m.%Y}")
    if not chk.https:
        chk.facts.append("Сайт работает без HTTPS")
    if not chk.viewport:
        chk.facts.append("На главной нет meta viewport — мобильная вёрстка вероятно не адаптивна")
    if chk.copyright_year:
        chk.facts.append(f"Последний год в копирайте: {chk.copyright_year}")
    if not chk.has_booking:
        chk.facts.append("На главной не найдено признаков онлайн-записи/бронирования")
    return chk
