"""Командная строка: python -m leadgen <команда>."""
from __future__ import annotations

import argparse
import json
import logging
import os
import sys
from pathlib import Path

from leadgen.config.settings import ROOT, load_settings
from leadgen.core.logging_setup import setup_logging
from leadgen.scheduler.runner import Pipeline, parse_commit_date, restore_from_notion
from leadgen.storage import export as export_mod
from leadgen.storage.state_crypto import decrypt_file, encrypt_file
from leadgen.storage.sqlite_store import Store

log = logging.getLogger("leadgen")
DEFAULT_DB = ROOT / "state" / "leadgen.db"
DEFAULT_ENC = ROOT / "state" / "leadgen.db.enc"


def cmd_run(args, settings) -> int:
    db = Path(args.db)
    fresh = not db.exists()
    store = Store(db)
    pipe = Pipeline(settings, store)
    if fresh:
        days = int(settings.section("storage").get("restore_days", 30))
        try:
            n = restore_from_notion(pipe, days)
            log.info("Локального состояния нет — восстановлено из Notion ключей: %d", n)
        except Exception as e:  # noqa: BLE001
            log.warning("Восстановление из Notion не удалось: %s (продолжаем с пустым состоянием)", e)
    only = [s.strip() for s in args.sources.split(",")] if args.sources else None
    report = pipe.run(only=only, force=args.force, last_commit_at=parse_commit_date(os.environ.get("LAST_COMMIT_AT")))
    summary = {
        "mode": settings.mode, "sources_run": report.sources_run, "skipped": report.sources_skipped,
        "new_total": report.new_total, "new_relevant": report.new_relevant, "duplicates": report.duplicates,
        "notified": report.notified, "notion_synced": report.notion_synced,
        "problems": [p["module"] + ": " + p["message"] for p in report.problems],
        "warnings": report.warnings, "requests_7d": store.request_stats(7),
    }
    print(json.dumps(summary, ensure_ascii=False, indent=2, default=str))
    _write_step_summary(summary)
    store.close()
    if any(p["scope"] == "system" for p in report.problems):
        # уведомление о критическом сбое уже отправлено изнутри — аварийный шаг workflow не дублирует его
        (db.parent / "critical_notified").write_text("1")
        return 1
    return 0


def _write_step_summary(summary: dict) -> None:
    """Сводка в интерфейсе GitHub Actions. Только агрегаты — без содержимого лидов и контактов."""
    path = os.environ.get("GITHUB_STEP_SUMMARY")
    if not path:
        return
    lines = [f"## Lead Generator ({summary['mode']})", "",
             f"- Источники: {', '.join(summary['sources_run']) or '—'}",
             f"- Новых: {summary['new_total']}, подходящих: {summary['new_relevant']}, дублей: {summary['duplicates']}",
             f"- Уведомлений: {summary['notified']}, в Notion: {summary['notion_synced']}", ""]
    if summary["skipped"]:
        lines += ["### Пропущены", *[f"- {k}: {v}" for k, v in summary["skipped"].items()], ""]
    if summary["problems"]:
        lines += ["### Проблемы", *[f"- {p}" for p in summary["problems"]], ""]
    if summary["warnings"]:
        lines += ["### Предупреждения", *[f"- {w}" for w in summary["warnings"]], ""]
    lines += ["### Запросы за 7 дней", "| Источник | Запросов | Ошибок |", "|---|---|---|",
              *[f"| {r['source']} | {r['requests']} | {r['errors']} |" for r in summary["requests_7d"]]]
    with open(path, "a", encoding="utf-8") as fh:
        fh.write("\n".join(lines) + "\n")


def cmd_state(args, settings) -> int:
    key = settings.secret("STATE_ENCRYPTION_KEY")
    if not key:
        print("STATE_ENCRYPTION_KEY не задан — состояние между запусками будет восстанавливаться только из Notion")
        return 0
    db, enc = Path(args.db), Path(args.enc)
    if args.action == "pack":
        if db.exists():
            encrypt_file(db, enc, key)
            print(f"Состояние зашифровано: {enc}")
        return 0
    if enc.exists():
        ok = decrypt_file(enc, db, key)
        print("Состояние восстановлено из кэша" if ok else "Не удалось расшифровать кэш (сменился ключ?) — начнём с Notion")
    else:
        print("Кэша состояния нет — первый запуск или кэш вытеснен")
    return 0


def cmd_diagnose(args, settings) -> int:
    from leadgen.scheduler.runner import is_due
    from leadgen.core.models import utcnow
    store = Store(args.db) if Path(args.db).exists() else Store(":memory:")
    pipe = Pipeline(settings, store)
    print(f"Режим: {settings.mode}")
    print("Секреты:", ", ".join(f"{k}={'есть' if v else 'нет'}" for k, v in settings.secrets.items()))
    print("\nИсточники:")
    for src in pipe.build_sources(list(settings.section("sources").keys())):
        st = store.source_state(src.name)
        ok, why = src.is_configured()
        enabled = settings.section("sources", src.name).get("enabled", False)
        due = is_due(st, float(src.cfg.get("interval_hours", 2)), utcnow())
        print(f"  - {src.name} [{src.type_name}] {'ВКЛ' if enabled else 'выкл'}; "
              f"{'готов' if ok else 'не настроен: ' + why}; последний успех: {st['last_success_at'] or '—'}; "
              f"сбоев подряд: {st['consecutive_failures']}; пора: {'да' if due else 'нет'}")
    print(f"\nЛидов в локальной базе: {store.count_leads()}")
    print("Запросы за 7 дней:", json.dumps(store.request_stats(7), ensure_ascii=False))
    errs = store.recent_errors(48)
    print(f"Ошибок за 48ч: {len(errs)}")
    for e in errs[-10:]:
        print(f"  {e['at']} {e['module']}: {e['message'][:200]}")
    if args.ping:
        if not settings.live:
            print("\n--ping работает только при LEADGEN_MODE=live")
        else:
            na = pipe.notion()
            if na:
                print("Notion:", na.check())
            if pipe.notifier.configured:
                print("Telegram:", pipe.notifier.send("🔧 Тестовое сообщение Lead Generator: связь есть."))
    return 0


def cmd_export(args, settings) -> int:
    store = Store(args.db)
    n = export_mod.export(store, Path(args.out), args.format)
    print(f"Экспортировано {n} записей в {args.out}. Не коммитьте этот файл в публичный репозиторий!")
    return 0


def cmd_notion_init(args, settings) -> int:
    from leadgen.storage.notion import NotionAdapter
    from leadgen.core.http import SourceHttp
    token = settings.secret("NOTION_TOKEN")
    if not token:
        print("Нужен NOTION_TOKEN")
        return 2
    na = NotionAdapter(SourceHttp("notion", Store(":memory:"), min_interval=0.4), token, "")
    print("ID новой базы (положите в секрет NOTION_DATABASE_ID):", na.init_database(args.parent))
    return 0


def main(argv: list[str] | None = None) -> int:
    settings = load_settings()
    setup_logging(settings.secret_values(), os.environ.get("LOG_LEVEL", "INFO"))
    p = argparse.ArgumentParser(prog="leadgen")
    p.add_argument("--db", default=str(DEFAULT_DB))
    sub = p.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("run", help="запуск поиска")
    r.add_argument("--sources", help="через запятую; по умолчанию — все включённые")
    r.add_argument("--force", action="store_true", help="игнорировать интервалы")
    s = sub.add_parser("state", help="шифрование состояния для кэша")
    s.add_argument("action", choices=["pack", "unpack"])
    s.add_argument("--enc", default=str(DEFAULT_ENC))
    d = sub.add_parser("diagnose", help="состояние системы")
    d.add_argument("--ping", action="store_true", help="проверить Notion и Telegram (только live)")
    e = sub.add_parser("export", help="резервная копия")
    e.add_argument("--format", choices=["json", "csv"], default="json")
    e.add_argument("--out", default=str(ROOT / "backup" / "leads.json"))
    n = sub.add_parser("notion-init", help="создать базу Notion с нужными полями")
    n.add_argument("--parent", required=True, help="ID страницы Notion, к которой подключена интеграция")
    args = p.parse_args(argv)
    handler = {"run": cmd_run, "state": cmd_state, "diagnose": cmd_diagnose, "export": cmd_export,
               "notion-init": cmd_notion_init}[args.cmd]
    return handler(args, settings)


if __name__ == "__main__":
    sys.exit(main())
