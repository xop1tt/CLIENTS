"""Публичные Telegram-каналы через официальное веб-превью https://t.me/s/<channel>.

Bot API НЕ умеет читать чужие каналы (бот видит только каналы, где он администратор).
Веб-превью доступно без авторизации только для публичных каналов с включённым предпросмотром.
Приватные каналы и чаты не поддерживаются — это осознанное ограничение.
"""
from __future__ import annotations

import re
from datetime import datetime
from typing import Any

from bs4 import BeautifulSoup

from leadgen.core.http import HttpError
from leadgen.core.models import Lead, LeadKind
from leadgen.sources.base import FetchResult, Source, extract_contacts, keyword_prefilter

CHANNEL_RE = re.compile(r"^[A-Za-z][A-Za-z0-9_]{3,31}$")


def parse_channel_page(html: str) -> list[dict[str, Any]]:
    soup = BeautifulSoup(html, "html.parser")
    posts = []
    for node in soup.select("div.tgme_widget_message[data-post]"):
        data_post = node.get("data-post", "")
        try:
            channel, msg_id = data_post.rsplit("/", 1)
            msg_id_i = int(msg_id)
        except ValueError:
            continue
        text_node = node.select_one(".tgme_widget_message_text")
        text = text_node.get_text("\n", strip=True) if text_node else ""
        time_node = node.select_one(".tgme_widget_message_date time[datetime]")
        published = None
        if time_node:
            try:
                published = datetime.fromisoformat(time_node["datetime"])
            except ValueError:
                published = None
        posts.append({"channel": channel, "id": msg_id_i, "text": text, "published": published,
                      "url": f"https://t.me/{channel}/{msg_id_i}"})
    return posts


class TelegramWebSource(Source):
    type_name = "telegram_web"

    def is_configured(self) -> tuple[bool, str]:
        chans = [c for c in self.cfg.get("channels", []) if c]
        if not chans:
            return False, "список каналов пуст (channels)"
        bad = [c for c in chans if not CHANNEL_RE.match(str(c))]
        if bad:
            return False, f"некорректные имена каналов: {bad}"
        return True, ""

    def fetch(self, since: datetime | None, cursor: dict[str, Any]) -> FetchResult:
        res = FetchResult(cursor=dict(cursor))
        keywords = self.cfg.get("prefilter_keywords", [])
        max_pages = int(self.cfg.get("max_pages_per_channel", 3))
        for channel in self.cfg.get("channels", []):
            channel = str(channel)
            last_id = int(res.cursor.get(channel, 0))
            newest = last_id
            before: int | None = None
            reached = last_id == 0  # первый запуск: берём только первую страницу
            for page in range(max_pages):
                url = f"https://t.me/s/{channel}" + (f"?before={before}" if before else "")
                try:
                    resp = self.http.get(url)
                except HttpError as e:
                    res.partial_errors.append(f"{channel}: {e}")
                    break
                posts = parse_channel_page(resp.text)
                if not posts:
                    if page == 0:
                        res.partial_errors.append(f"{channel}: нет публичного превью или канал не найден")
                    break
                for p in posts:
                    if p["id"] <= last_id:
                        reached = True
                        continue
                    newest = max(newest, p["id"])
                    if not p["text"] or not keyword_prefilter(p["text"], keywords):
                        continue
                    first_line = p["text"].split("\n", 1)[0][:200]
                    res.leads.append(Lead(
                        kind=LeadKind.ORDER, source=self.name, external_id=f"{channel}/{p['id']}", title=first_line,
                        url=p["url"], description=p["text"][:4000], published_at=p["published"],
                        contacts=extract_contacts(p["text"]), raw={"channel": channel},
                    ))
                min_id = min(p["id"] for p in posts)
                if reached or min_id <= last_id + 1:
                    reached = True
                    break
                before = min_id
            if not reached:
                res.warnings.append(f"{channel}: за {max_pages} стр. не дошли до последнего обработанного поста"
                                    " — возможен пропуск (увеличьте max_pages_per_channel)")
            res.cursor[channel] = newest
        return res
