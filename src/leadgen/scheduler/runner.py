"""Оркестрация запуска: источники → фильтрация/scoring → дедупликация → внешние адаптеры →
Notion → Telegram. Сбой любого модуля не останавливает остальные."""
from __future__ import annotations

import hashlib
import logging
import time
import traceback
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from typing import Any, Callable

from leadgen.config.settings import Settings
from leadgen.core.logging_setup import SecretFilter
from leadgen.core.http import BudgetExceeded, HttpError, SourceHttp
from leadgen.core.models import Lead, Relevance, utcnow
from leadgen.integrations.base import Router
from leadgen.integrations.registry import ADAPTER_TYPES
from leadgen.notifications.telegram import TelegramNotifier
from leadgen.scoring.scorer import merge_external, score_lead
from leadgen.sources.osm_overpass import OsmOverpassSource
from leadgen.sources.registry import SOURCE_TYPES
from leadgen.storage.notion import NotionAdapter
from leadgen.storage.sqlite_store import Store

log = logging.getLogger(__name__)
HttpFactory = Callable[[str, dict[str, Any]], SourceHttp]


@dataclass
class RunReport:
    started_at: datetime = field(default_factory=utcnow)
    sources_run: list[str] = field(default_factory=list)
    sources_skipped: dict[str, str] = field(default_factory=dict)
    new_total: int = 0
    new_relevant: int = 0
    duplicates: int = 0
    notified: int = 0
    notion_synced: int = 0
    problems: list[dict[str, Any]] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)
    recovered: list[str] = field(default_factory=list)

    def as_dict(self) -> dict[str, Any]:
        return {"sources_run": len(self.sources_run), "new_total": self.new_total,
                "new_relevant": self.new_relevant}


def _sig(module: str, message: str) -> str:
    # сигнатура без цифр — одинаковые ошибки с разными таймингами объединяются
    norm = "".join(ch for ch in message if not ch.isdigit())[:200]
    return hashlib.sha1(f"{module}|{norm}".encode()).hexdigest()[:16]


def default_http_factory(store: Store, sleep: Callable[[float], None] = time.sleep) -> HttpFactory:
    def make(name: str, cfg: dict[str, Any]) -> SourceHttp:
        h = cfg.get("http", {})
        return SourceHttp(name, store, min_interval=float(h.get("min_interval_sec", 1.5)),
                          max_requests_per_run=int(h.get("max_requests_per_run", 30)),
                          max_requests_per_day=h.get("max_requests_per_day"),
                          max_attempts=int(h.get("max_attempts", 4)), base_delay=float(h.get("base_delay_sec", 2)),
                          timeout=float(h.get("timeout_sec", 20)), sleep=sleep)
    return make


def is_due(state: dict[str, Any], interval_hours: float, now: datetime) -> bool:
    last = state.get("last_success_at")
    if state.get("consecutive_failures"):
        # после сбоя пробуем снова на следующем запуске, но не чаще чем раз в час
        attempt = state.get("last_attempt_at")
        return attempt is None or now - attempt >= timedelta(minutes=55)
    # допуск 10 минут: cron GitHub может запуститься чуть раньше/позже
    return last is None or now - last >= timedelta(hours=interval_hours) - timedelta(minutes=10)


class Pipeline:
    def __init__(self, settings: Settings, store: Store, http_factory: HttpFactory | None = None,
                 sleep: Callable[[float], None] = time.sleep):
        self.s = settings
        self.store = store
        self.http_factory = http_factory or default_http_factory(store, sleep)
        ncfg = settings.section("notifications")
        tg_http = self.http_factory("telegram", {"http": {"min_interval_sec": 1.1, "max_requests_per_run": 40}})
        self._scrubber = SecretFilter(settings.secret_values())
        self.notifier = TelegramNotifier(store, tg_http, settings.secret("TELEGRAM_BOT_TOKEN"),
                                         settings.secret("TELEGRAM_CHAT_ID"), ncfg, live=settings.live, sleep=sleep)

    # ---------------- источники ----------------
    def build_sources(self, only: list[str] | None = None) -> list[Any]:
        out = []
        for name, cfg in (self.s.section("sources") or {}).items():
            if only and name not in only:
                continue
            if not cfg.get("enabled", False) and not only:
                continue
            cls = SOURCE_TYPES.get(cfg.get("type", ""))
            if cls is None:
                log.warning("Источник %s: неизвестный тип %s", name, cfg.get("type"))
                continue
            kw: dict[str, Any] = {}
            if cls is OsmOverpassSource and cfg.get("check_websites", True):
                kw["site_http"] = self.http_factory(f"{name}:sites", {"http": cfg.get("site_http", {
                    "min_interval_sec": 1.0, "max_requests_per_run": 40, "max_attempts": 2, "timeout_sec": 12})})
            out.append(cls(name, cfg, self.store, self.http_factory(name, cfg), self.s.secrets, **kw))
        return out

    def run_sources(self, report: RunReport, only: list[str] | None, force: bool) -> list[Lead]:
        now = utcnow()
        new_leads: list[Lead] = []
        threshold = int(self.s.section("notifications").get("notify_after_failures", 2))
        scoring_cfg = self.s.section("scoring")
        for src in self.build_sources(only):
            st = self.store.source_state(src.name)
            ok, why = src.is_configured()
            if not ok:
                report.sources_skipped[src.name] = f"не настроен: {why}"
                continue
            if not force and not is_due(st, float(src.cfg.get("interval_hours", 2)), now):
                report.sources_skipped[src.name] = "ещё не пора по расписанию"
                continue
            report.sources_run.append(src.name)
            try:
                res = src.fetch(st["last_success_at"], st["cursor"])
                if res.partial_errors and len(res.partial_errors) >= src.item_count():
                    raise HttpError("все подзапросы источника завершились ошибкой: " + "; ".join(res.partial_errors[:3]))
            except BudgetExceeded as e:
                report.warnings.append(str(e))
                continue
            except Exception as e:  # noqa: BLE001 — источник не должен ронять запуск
                msg = self._scrubber.scrub(f"{type(e).__name__}: {e}")
                n = self.store.mark_source_failure(src.name, msg)
                self.store.log_error(src.name, _sig(src.name, msg), msg)
                log.error("Источник %s упал (%d подряд): %s", src.name, n, msg)
                if n >= threshold:
                    report.problems.append({"module": src.name, "message": msg, "scope": "source",
                                            "retry": "автоматически при следующем запуске",
                                            "signature": _sig(src.name, msg)})
                continue
            for pe in res.partial_errors:
                pe = self._scrubber.scrub(pe)
                self.store.log_error(src.name, _sig(src.name, pe), pe)
                log.warning("%s: %s", src.name, pe)
            report.warnings.extend(f"{src.name}: {w}" for w in res.warnings)
            if st["consecutive_failures"] >= threshold:
                report.recovered.append(src.name)
            for lead in res.leads:
                score_lead(lead, scoring_cfg)
                if self.store.insert_lead(lead):
                    report.new_total += 1
                    if lead.relevance != Relevance.REJECTED:
                        new_leads.append(lead)
                else:
                    report.duplicates += 1
            # Курсор сохраняем только после успешного сохранения лидов — при падении повторим период.
            self.store.mark_source_success(src.name, res.cursor)
        report.new_relevant = len(new_leads)
        return new_leads

    # ---------------- внешние сервисы ----------------
    def run_adapters(self, leads: list[Lead], report: RunReport) -> None:
        adapters = []
        for name, cfg in (self.s.section("integrations") or {}).items():
            if name == "notion" or not cfg.get("enabled", False):
                continue
            cls = ADAPTER_TYPES.get(cfg.get("type", name))
            if cls is None:
                continue
            ad = cls(cfg, self.store, self.http_factory(name, cfg), self.s.secrets)
            if ad.missing_secrets():
                report.warnings.append(f"{name}: нет секретов {ad.missing_secrets()}, адаптер пропущен")
                continue
            if not self.s.live:
                report.warnings.append(f"{name}: dry-run — во внешний сервис ничего не отправлено")
                continue
            adapters.append(ad)
        if adapters and leads:
            for p in Router(adapters).run(leads):
                p = self._scrubber.scrub(p)
                report.problems.append({"module": "integrations", "message": p, "scope": "integration",
                                        "retry": "при следующем запуске", "signature": _sig("integrations", p)})
        for lead in leads:
            if lead.external_results:
                self.store.update_lead(lead)

    # ---------------- Notion ----------------
    def notion(self) -> NotionAdapter | None:
        cfg = self.s.section("integrations", "notion")
        token, db = self.s.secret("NOTION_TOKEN"), self.s.secret("NOTION_DATABASE_ID")
        if not cfg.get("enabled", True) or not token or not db:
            return None
        http = self.http_factory("notion", {"http": {"min_interval_sec": 0.4, "max_requests_per_run": 300}})
        return NotionAdapter(http, token, db)

    def sync_notion(self, report: RunReport) -> None:
        na = self.notion()
        if na is None:
            report.warnings.append("Notion не настроен — лиды сохранены только в локальном состоянии")
            return
        if not self.s.notion_live:
            pending = len(self.store.leads_pending_notion(1000))
            report.warnings.append(f"Notion: dry-run, к синхронизации ожидает {pending}")
            return
        threshold = int(self.s.section("notifications").get("notify_after_failures", 2))
        prev = self.store.source_state("notion")["consecutive_failures"]
        limit = int(self.s.section("integrations", "notion").get("max_per_run", 60))
        for lead in self.store.leads_pending_notion(limit):
            lead.external_results = self.store.external_results(lead.lead_id)
            try:
                pid = na.upsert(lead, self.store.notion_page_id(lead.lead_id), merge_external(lead, self.s.section("scoring")))
            except (HttpError, BudgetExceeded, KeyError, ValueError) as e:
                e = RuntimeError(self._scrubber.scrub(str(e)))  # type: ignore[assignment]
                # Notion недоступен — не долбим его остальными лидами, они подождут следующего запуска
                self.store.set_notion(lead.lead_id, "error")
                n = self.store.mark_source_failure("notion", str(e))
                self.store.log_error("notion", _sig("notion", str(e)), str(e))
                if n >= threshold:
                    msg = f"Notion недоступен ({e}). Лиды сохранены локально и будут синхронизированы позже"
                    report.problems.append({"module": "notion", "message": msg, "scope": "integration",
                                            "retry": "автоматически при следующем запуске",
                                            "signature": _sig("notion", "unavailable")})
                return
            self.store.set_notion(lead.lead_id, "synced", pid)
            report.notion_synced += 1
        if report.notion_synced or prev:
            self.store.mark_source_success("notion", {})
            if prev >= threshold:
                report.recovered.append("notion")

    # ---------------- диагностика ----------------
    def diagnostics(self, report: RunReport, last_commit_at: datetime | None) -> None:
        now = utcnow()
        if last_commit_at:
            idle = (now - last_commit_at).days
            warn_after = int(self.s.section("diagnostics").get("inactivity_warn_days", 50))
            if idle >= warn_after:
                self.notifier.notify_warning(
                    "inactivity", f"В репозитории нет коммитов {idle} дн. GitHub отключает расписание публичных "
                    f"репозиториев после 60 дней без активности. Зайди в Actions и нажми «Enable workflow», "
                    f"если расписание выключится, или сделай осмысленный коммит (например, обнови настройки).")
        for name, cfg in (self.s.section("sources") or {}).items():
            if not cfg.get("enabled"):
                continue
            st = self.store.source_state(name)
            last = st.get("last_success_at")
            limit = timedelta(hours=float(cfg.get("interval_hours", 2)) * 3 + 6)
            if last and now - last > limit:
                report.warnings.append(f"{name}: последняя успешная проверка {last:%d.%m %H:%M} — дольше 3 интервалов")

    # ---------------- полный запуск ----------------
    def run(self, only: list[str] | None = None, force: bool = False,
            last_commit_at: datetime | None = None) -> RunReport:
        report = RunReport()
        try:
            leads = self.run_sources(report, only, force)
            self.run_adapters(leads, report)
            self.sync_notion(report)
            scoring_cfg = self.s.section("scoring")
            report.notified = self.notifier.notify_leads([(l, merge_external(l, scoring_cfg)) for l in leads])
            self.diagnostics(report, last_commit_at)
        except Exception as e:  # noqa: BLE001 — критический сбой ядра
            msg = self._scrubber.scrub(f"{type(e).__name__}: {e}")
            log.error("Критический сбой: %s\n%s", msg, traceback.format_exc())
            self.store.log_error("core", _sig("core", msg), msg)
            report.problems.append({"module": "ядро", "message": msg, "scope": "system",
                                    "retry": "при следующем запуске по расписанию", "signature": _sig("core", msg)})
        self.notifier.notify_problems(report.problems)
        self.notifier.notify_recovery(report.recovered)
        self.notifier.notify_summary(report.as_dict())
        self.store.prune(int(self.s.section("storage").get("keep_log_days", 90)))
        return report


def restore_from_notion(pipeline: Pipeline, days: int) -> int:
    """Если локального состояния нет — восстанавливаем «уже виденные» ID из Notion за последние N дней."""
    na = pipeline.notion()
    if na is None:
        return 0
    since = utcnow() - timedelta(days=days)
    n = 0
    for key, src, page_id in na.iter_recent_keys(since):
        pipeline.store.register_remote_key(key, src, page_id)
        n += 1
    return n


def parse_commit_date(value: str | None) -> datetime | None:
    if not value:
        return None
    try:
        dt = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    return dt if dt.tzinfo else dt.replace(tzinfo=timezone.utc)
