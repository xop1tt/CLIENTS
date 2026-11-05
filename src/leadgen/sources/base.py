"""Базовый класс источника. Каждый источник независим: свои настройки, лимиты, интервал, журнал."""
from __future__ import annotations

import re
from dataclasses import dataclass, field
from datetime import datetime
from typing import Any

from leadgen.core.http import SourceHttp
from leadgen.core.models import Lead
from leadgen.storage.sqlite_store import Store


@dataclass
class FetchResult:
    leads: list[Lead] = field(default_factory=list)
    cursor: dict[str, Any] = field(default_factory=dict)
    warnings: list[str] = field(default_factory=list)
    partial_errors: list[str] = field(default_factory=list)  # ошибки отдельных каналов/лент


class Source:
    type_name = "base"

    def __init__(self, name: str, cfg: dict[str, Any], store: Store, http: SourceHttp,
                 secrets: dict[str, str] | None = None):
        self.name = name
        self.cfg = cfg
        self.store = store
        self.http = http
        self.secrets = secrets or {}

    def is_configured(self) -> tuple[bool, str]:
        """(готов ли к работе, причина если нет)."""
        return True, ""

    def item_count(self) -> int:
        """Сколько независимых подзапросов (лент, каналов...) у источника — чтобы отличать
        частичный сбой от полного."""
        for key in ("feeds", "channels", "communities"):
            if key in self.cfg:
                return max(1, len(self.cfg[key] or []))
        return 1

    def fetch(self, since: datetime | None, cursor: dict[str, Any]) -> FetchResult:
        raise NotImplementedError


_EMAIL = re.compile(r"[\w.+-]+@[\w-]+\.[\w.-]+")
_PHONE = re.compile(r"(?:\+7|8)[\s(-]*\d{3}[\s)-]*\d{3}[\s-]*\d{2}[\s-]*\d{2}")
_TG = re.compile(r"(?<![\w/])@([A-Za-z][A-Za-z0-9_]{4,31})\b|t\.me/([A-Za-z][A-Za-z0-9_]{4,31})")


def extract_contacts(text: str) -> dict[str, str]:
    """Публично опубликованные в тексте контакты (ничего не додумываем)."""
    contacts: dict[str, str] = {}
    if m := _EMAIL.search(text or ""):
        contacts["email"] = m.group(0).rstrip(".")
    if m := _PHONE.search(text or ""):
        contacts["phone"] = re.sub(r"[^\d+]", "", m.group(0))
    if m := _TG.search(text or ""):
        contacts["telegram"] = "@" + (m.group(1) or m.group(2))
    return contacts


def keyword_prefilter(text: str, keywords: list[str]) -> bool:
    if not keywords:
        return True
    low = (text or "").lower().replace("ё", "е")
    return any(k.lower().replace("ё", "е") in low for k in keywords)
