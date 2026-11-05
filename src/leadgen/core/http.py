"""HTTP-клиент: лимит частоты, бюджет запросов на запуск, ретраи с экспоненциальной задержкой."""
from __future__ import annotations

import logging
import random
import re
import time
from typing import Any, Callable

import httpx

from leadgen.storage.sqlite_store import Store

log = logging.getLogger(__name__)

USER_AGENT = "LeadGeneratorBot/0.1 (+https://github.com; personal non-commercial research)"
RETRY_STATUSES = {429, 500, 502, 503, 504}


class BudgetExceeded(Exception):
    """Исчерпан лимит запросов источника на этот запуск/сутки."""


class HttpError(Exception):
    def __init__(self, message: str, status: int | None = None, transient: bool = False):
        super().__init__(message)
        self.status = status
        self.transient = transient


class SourceHttp:
    """HTTP-обёртка для одного источника/адаптера."""

    def __init__(self, name: str, store: Store, *, min_interval: float = 1.0, max_requests_per_run: int = 50,
                 max_requests_per_day: int | None = None, max_attempts: int = 4, base_delay: float = 2.0,
                 timeout: float = 20.0, client: httpx.Client | None = None,
                 sleep: Callable[[float], None] = time.sleep, headers: dict[str, str] | None = None):
        self.name = name
        self.store = store
        self.min_interval = min_interval
        self.max_requests_per_run = max_requests_per_run
        self.max_requests_per_day = max_requests_per_day
        self.max_attempts = max_attempts
        self.base_delay = base_delay
        self.sleep = sleep
        self.requests_made = 0
        self._last = 0.0
        self.client = client or httpx.Client(timeout=timeout, follow_redirects=True,
                                             headers={"User-Agent": USER_AGENT, **(headers or {})})

    def _check_budget(self) -> None:
        if self.requests_made >= self.max_requests_per_run:
            raise BudgetExceeded(f"{self.name}: лимит {self.max_requests_per_run} запросов на запуск")
        if self.max_requests_per_day is not None and self.store.requests_today(self.name) >= self.max_requests_per_day:
            raise BudgetExceeded(f"{self.name}: суточный лимит {self.max_requests_per_day} запросов")

    def _throttle(self) -> None:
        wait = self.min_interval - (time.monotonic() - self._last)
        if wait > 0:
            self.sleep(wait)
        self._last = time.monotonic()

    def request(self, method: str, url: str, **kw: Any) -> httpx.Response:
        last_exc: Exception | None = None
        for attempt in range(1, self.max_attempts + 1):
            self._check_budget()
            self._throttle()
            self.requests_made += 1
            try:
                resp = self.client.request(method, url, **kw)
            except (httpx.TimeoutException, httpx.TransportError) as e:
                self.store.count_request(self.name, error=True)
                last_exc = HttpError(f"{type(e).__name__}: {e}", transient=True)
            else:
                ok = resp.status_code < 400
                self.store.count_request(self.name, error=not ok)
                if ok:
                    return resp
                if resp.status_code not in RETRY_STATUSES:
                    raise HttpError(f"HTTP {resp.status_code} для {_safe_url(url)}", status=resp.status_code)
                last_exc = HttpError(f"HTTP {resp.status_code} для {_safe_url(url)}", status=resp.status_code,
                                     transient=True)
                retry_after = resp.headers.get("Retry-After")
                if retry_after and retry_after.isdigit() and attempt < self.max_attempts:
                    self.sleep(min(float(retry_after), 120.0))
                    continue
            if attempt < self.max_attempts:
                delay = self.base_delay * (2 ** (attempt - 1)) + random.uniform(0, 0.5)
                log.info("%s: временная ошибка, попытка %d/%d через %.1fс", self.name, attempt, self.max_attempts, delay)
                self.sleep(delay)
        assert last_exc is not None
        raise last_exc

    def get(self, url: str, **kw: Any) -> httpx.Response:
        return self.request("GET", url, **kw)

    def post(self, url: str, **kw: Any) -> httpx.Response:
        return self.request("POST", url, **kw)


def _safe_url(url: str) -> str:
    """URL без query-параметров (там бывают ключи) и без токена бота в пути."""
    return re.sub(r"/bot[^/]+/", "/bot***/", url.split("?")[0])
