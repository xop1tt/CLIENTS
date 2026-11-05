"""Уведомления через Telegram Bot API (sendMessage). Постоянный сервер не нужен — отправка из запуска.

Защита от спама: лимит сообщений о заявках за запуск (остальное — одним дайджестом),
ошибки объединяются в одно сообщение, повтор одной и той же ошибки — не чаще cooldown.
dry-run: ничего не отправляется, тексты пишутся в лог и в outbox (для тестов и проверки).

Архитектура допускает будущие команды бота (/status, /stats, /pause...) — их можно реализовать
отдельным workflow, который читает getUpdates; сейчас не реализовано (вне первой версии).
"""
from __future__ import annotations

import html
import logging
import os
import time
from datetime import timedelta
from typing import Any, Callable

from leadgen.core.http import HttpError, SourceHttp
from leadgen.core.models import RELEVANCE_RU, Lead, LeadKind, utcnow
from leadgen.notifications.phrases import PhrasePicker
from leadgen.storage.sqlite_store import Store

log = logging.getLogger(__name__)
MAX_LEN = 4000


def esc(s: Any) -> str:
    return html.escape(str(s), quote=False)


def _short(text: str, n: int) -> str:
    text = " ".join((text or "").split())
    return text if len(text) <= n else text[: n - 1] + "…"


def format_lead(lead: Lead, headline: str, final_score: float | None = None) -> str:
    lines = [f"<b>{esc(headline)}</b>", "", f"📌 <b>{esc(_short(lead.title, 200))}</b>"]
    if lead.kind == LeadKind.ORGANIZATION:
        if lead.category:
            lines.append(f"🏷 {esc(lead.description or lead.category)}")
        if lead.address:
            lines.append(f"📍 {esc(lead.address)}")
        if lead.phone:
            lines.append(f"☎️ {esc(lead.phone)}")
        lines.append(f"🌐 {esc(lead.website) if lead.website else 'сайт не указан'}")
        if lead.facts:
            lines.append("✅ Факты: " + esc("; ".join(f for f in lead.facts if 'OpenStreetMap (ODbL)' not in f)[:600]))
        if lead.assumptions:
            lines.append("🤔 Предположения: " + esc("; ".join(lead.assumptions)[:300]))
    else:
        if lead.description:
            lines.append(esc(_short(lead.description, 400)))
        if lead.budget:
            lines.append(f"💰 Бюджет: {lead.budget:,.0f} {esc(lead.currency or '')}".replace(",", " "))
        else:
            lines.append("💰 Бюджет: не указан")
        if lead.contacts:
            lines.append("✉️ " + esc(", ".join(f"{k}: {v}" for k, v in lead.contacts.items())))
    when = lead.published_at or lead.discovered_at
    lines.append(f"🗂 Источник: {esc(lead.source)} · {when:%d.%m.%Y %H:%M} UTC")
    lines.append(f"📊 Оценка системы: {lead.score:.0f}/100 ({RELEVANCE_RU[lead.relevance]})")
    ext = [r for r in lead.external_results if r.ok]
    if ext:
        lines.append("🧪 Внешние сервисы: " + esc("; ".join(
            f"{r.service}: {r.label or ''}{f' {r.score:.0f}' if r.score is not None else ''}" for r in ext)))
        if final_score is not None and final_score != lead.score:
            lines.append(f"📈 Итоговая оценка: {final_score:.0f}/100")
    if lead.url:
        lines.append(f'🔗 <a href="{html.escape(lead.url, quote=True)}">Оригинал</a>')
    return "\n".join(lines)[:MAX_LEN]


class TelegramNotifier:
    def __init__(self, store: Store, http: SourceHttp | None, token: str | None, chat_id: str | None,
                 cfg: dict[str, Any], live: bool, picker: PhrasePicker | None = None,
                 sleep: Callable[[float], None] = time.sleep):
        self.store = store
        self.http = http
        self.token = token
        self.chat_id = chat_id
        self.cfg = cfg
        self.live = live and bool(token and chat_id) and http is not None
        self.picker = picker or PhrasePicker(store)
        self.sleep = sleep
        self.outbox: list[str] = []

    @property
    def configured(self) -> bool:
        return bool(self.token and self.chat_id)

    def send(self, text: str) -> bool:
        self.outbox.append(text)
        if not self.live:
            # Логи GitHub Actions публичного репозитория видны всем — содержимое лидов в лог не пишем.
            if os.environ.get("LEADGEN_SHOW_MESSAGES") == "1":
                log.info("[dry-run] Telegram:\n%s", text)
            else:
                log.info("[dry-run] Telegram: сообщение «%s» (%d символов) не отправлено",
                         text.split("\n", 1)[0][:80], len(text))
            return True
        url = f"https://api.telegram.org/bot{self.token}/sendMessage"
        body = {"chat_id": self.chat_id, "text": text[:MAX_LEN], "parse_mode": "HTML",
                "disable_web_page_preview": True}
        try:
            self.http.post(url, json=body)
            return True
        except HttpError as e:
            log.error("Telegram: не удалось отправить сообщение: %s", e)
            return False

    # ---------- заявки ----------
    def notify_leads(self, leads: list[tuple[Lead, float]]) -> int:
        """leads: (лид, итоговая оценка). Возвращает число отправленных."""
        min_rel = self.cfg.get("notify_min_relevance", ["high", "medium"])
        fresh = [(l, s) for l, s in leads if l.relevance.value in min_rel and not self.store.is_notified(l.lead_id)]
        fresh.sort(key=lambda x: x[1], reverse=True)
        limit = int(self.cfg.get("max_lead_messages_per_run", 8))
        sent = 0
        for lead, final in fresh[:limit]:
            if self.send(format_lead(lead, self.picker.pick("new_leads"), final)):
                self.store.mark_notified(lead.lead_id)
                sent += 1
        rest = fresh[limit:]
        if rest:
            lines = [f"<b>{esc(self.picker.pick('new_leads'))}</b>", f"И ещё {len(rest)} шт. одним списком:"]
            included: list[Lead] = []
            for lead, final in rest:
                link = f' — <a href="{html.escape(lead.url, quote=True)}">ссылка</a>' if lead.url else ""
                line = f"• {esc(_short(lead.title, 90))} ({final:.0f}){link}"
                if sum(len(x) + 1 for x in lines) + len(line) > MAX_LEN - 100:
                    lines.append(f"…остальные {len(rest) - len(included)} — в Notion")
                    break  # режем по целым строкам, чтобы не сломать HTML-разметку
                lines.append(line)
                included.append(lead)
            if self.send("\n".join(lines)):
                for lead in included:
                    self.store.mark_notified(lead.lead_id)
                sent += 1
        return sent

    # ---------- сводка запуска ----------
    def notify_summary(self, stats: dict[str, Any]) -> None:
        """Сводка — не чаще раза в сутки (запуски ежечасные, иначе это спам)."""
        if not self.cfg.get("send_daily_summary", True):
            return
        if self.store.notification_sent_since("summary", "daily", utcnow() - timedelta(hours=20)):
            return
        since = (utcnow() - timedelta(hours=24)).isoformat()
        row = self.store.conn.execute(
            "SELECT COUNT(*) total, SUM(relevance IN ('high','medium')) good FROM leads"
            " WHERE discovered_at>=? AND fingerprint NOT LIKE 'remote:%'", (since,)).fetchone()
        total, good = row["total"] or 0, row["good"] or 0
        cat = "success" if good else "no_leads"
        text = (f"<b>{esc(self.picker.pick(cat))}</b>\nЗа сутки: новых записей {total}, подходящих {good}."
                f"\nИсточников в этом запуске: {stats.get('sources_run', 0)}")
        if self.send(text):
            self.store.log_notification("summary", "daily")

    # ---------- ошибки ----------
    def notify_problems(self, problems: list[dict[str, Any]]) -> None:
        """problems: {module, message, scope: source|system|integration, retry: str, signature}.
        Все проблемы одного запуска — одним сообщением; повтор той же сигнатуры — не чаще cooldown."""
        cooldown = timedelta(hours=float(self.cfg.get("error_cooldown_hours", 6)))
        since = utcnow() - cooldown
        todo = [p for p in problems if not self.store.notification_sent_since("error", p["signature"], since)]
        if not todo:
            return
        critical = any(p["scope"] == "system" for p in todo)
        head = self.picker.pick("critical" if critical else "error")
        lines = [f"<b>{esc(head)}</b>", f"🕒 {utcnow():%d.%m.%Y %H:%M} UTC"]
        for p in todo[:15]:
            scope = {"system": "❗ влияет на всю систему", "source": "затронут только этот источник",
                     "integration": "затронута только интеграция, поиск работает"}.get(p["scope"], "")
            lines.append(f"• <b>{esc(p['module'])}</b>: {esc(_short(p['message'], 300))}\n"
                         f"  {esc(scope)}. Повтор: {esc(p.get('retry', 'при следующем запуске'))}")
        if len(todo) > 15:
            lines.append(f"…и ещё {len(todo) - 15}")
        if self.send("\n".join(lines)[:MAX_LEN]):
            for p in todo:
                self.store.log_notification("error", p["signature"])

    def notify_recovery(self, modules: list[str]) -> None:
        if not modules:
            return
        self.send(f"<b>{esc(self.picker.pick('recovery'))}</b>\nСнова работают: {esc(', '.join(modules))}")

    def notify_warning(self, key: str, text: str, cooldown_hours: float = 24) -> None:
        if self.store.notification_sent_since("warning", key, utcnow() - timedelta(hours=cooldown_hours)):
            return
        if self.send(f"<b>{esc(self.picker.pick('warning'))}</b>\n{esc(text)}"):
            self.store.log_notification("warning", key)
