"""Логирование с вычисткой секретов."""
from __future__ import annotations

import logging
import re
import sys


class SecretFilter(logging.Filter):
    def __init__(self, secrets: list[str]):
        super().__init__()
        self._secrets = sorted(set(secrets), key=len, reverse=True)
        # токены Telegram-бота вида 123456:ABC... и Notion ntn_/secret_
        self._patterns = [
            re.compile(r"\d{6,}:[A-Za-z0-9_-]{30,}"),
            re.compile(r"\b(?:ntn|secret)_[A-Za-z0-9]{20,}"),
            re.compile(r"(api_key|access_token|token)=[^&\s]+", re.I),
        ]

    def scrub(self, text: str) -> str:
        for s in self._secrets:
            text = text.replace(s, "***")
        for p in self._patterns:
            text = p.sub(lambda m: (m.group(1) + "=***") if m.lastindex else "***", text)
        return text

    def filter(self, record: logging.LogRecord) -> bool:
        record.msg = self.scrub(record.getMessage())
        record.args = ()
        return True


def setup_logging(secrets: list[str], level: str = "INFO") -> SecretFilter:
    flt = SecretFilter(secrets)
    handler = logging.StreamHandler(sys.stdout)
    handler.setFormatter(logging.Formatter("%(asctime)s %(levelname)s %(name)s: %(message)s"))
    handler.addFilter(flt)
    root = logging.getLogger()
    root.handlers[:] = [handler]
    root.setLevel(level)
    # httpx логирует URL целиком (там может быть ключ) — глушим до WARNING
    logging.getLogger("httpx").setLevel(logging.WARNING)
    return flt
