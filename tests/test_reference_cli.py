"""Эталонные проверки командной строки, настроек и вычистки секретов.

Дополняют прежние тесты и ничего в них не меняют. См. Wiki → «Разработка и сборка → Тесты и проверки как эталон».
"""
from __future__ import annotations

import argparse
import csv
import json
import logging

import pytest

from leadgen import cli
from leadgen.config.settings import Settings, load_settings
from leadgen.core.logging_setup import SecretFilter
from leadgen.core.models import Lead, LeadKind
from leadgen.storage.sqlite_store import Store


def settings(**secrets) -> Settings:
    return Settings(data={"sources": {}}, secrets=secrets, mode="dry-run")


def lead(eid="1", title="Нужен сайт") -> Lead:
    return Lead(kind=LeadKind.ORDER, source="a", external_id=eid, title=title, description="описание задачи")


# ---------- настройки ----------

def test_unknown_mode_falls_back_to_dry_run(tmp_path):
    cfg = tmp_path / "c.yaml"
    cfg.write_text("mode: live\nsources: {}\n", encoding="utf-8")
    assert load_settings(cfg, env={}).mode == "live"
    assert load_settings(cfg, env={"LEADGEN_MODE": "что-то"}).mode == "dry-run"
    assert load_settings(cfg, env={"LEADGEN_MODE": " NOTION-ONLY "}).mode == "notion-only"


def test_environment_mode_wins_over_file(tmp_path):
    cfg = tmp_path / "c.yaml"
    cfg.write_text("mode: live\n", encoding="utf-8")
    assert load_settings(cfg, env={"LEADGEN_MODE": "dry-run"}).mode == "dry-run"


def test_empty_config_file_is_allowed(tmp_path):
    cfg = tmp_path / "c.yaml"
    cfg.write_text("", encoding="utf-8")
    s = load_settings(cfg, env={})
    assert s.data == {} and s.mode == "dry-run"


def test_secrets_come_only_from_environment_and_are_trimmed(tmp_path):
    cfg = tmp_path / "c.yaml"
    cfg.write_text("NOTION_TOKEN: из-файла\n", encoding="utf-8")
    s = load_settings(cfg, env={"NOTION_TOKEN": "  ntn_abcdef  ", "ПОСТОРОННЯЯ": "x"})
    assert s.secret("NOTION_TOKEN") == "ntn_abcdef"
    assert s.secret("TELEGRAM_BOT_TOKEN") is None, "пустой секрет — это отсутствие секрета"
    assert "ПОСТОРОННЯЯ" not in s.secrets


def test_secret_values_skip_short_and_empty():
    s = settings(A="123456", B="12345", C="")
    assert s.secret_values() == ["123456"]


def test_mode_flags():
    assert not Settings(data={}, mode="dry-run").live and not Settings(data={}, mode="dry-run").notion_live
    assert Settings(data={}, mode="live").live and Settings(data={}, mode="live").notion_live
    assert not Settings(data={}, mode="notion-only").live and Settings(data={}, mode="notion-only").notion_live


def test_section_walks_nested_dicts_and_defaults():
    s = Settings(data={"a": {"b": {"c": 1}}, "x": 5})
    assert s.section("a", "b", "c") == 1
    assert s.section("a", "нет") == {}
    assert s.section("x", "y") == {}, "значение не словарь — вложенного раздела нет"
    assert s.section("a", "нет", default=7) == 7


# ---------- вычистка секретов из логов ----------

def test_scrub_removes_known_secrets_longest_first():
    f = SecretFilter(["abcdef", "abcdefghij"])
    assert f.scrub("ключ abcdefghij и abcdef") == "ключ *** и ***"


def test_scrub_removes_token_shapes():
    f = SecretFilter([])
    bot = "123456789:" + "A" * 35
    assert "A" * 10 not in f.scrub(f"https://api.telegram.org/bot{bot}/sendMessage")
    assert "ntn_" not in f.scrub("токен ntn_" + "x" * 30)
    assert "secret_" not in f.scrub("токен secret_" + "x" * 30)
    assert f.scrub("https://x/?api_key=ABC123&q=1") == "https://x/?api_key=***&q=1"
    assert f.scrub("access_token=zzz") == "access_token=***"
    assert f.scrub("обычный текст") == "обычный текст"


def test_filter_scrubs_formatted_message_and_drops_args():
    rec = logging.LogRecord("t", logging.INFO, __file__, 1, "ключ %s", ("supersecret",), None)
    assert SecretFilter(["supersecret"]).filter(rec) is True
    assert rec.getMessage() == "ключ ***" and rec.args == ()


# ---------- команды ----------

def test_state_without_key_does_nothing(tmp_path, capsys):
    args = argparse.Namespace(db=str(tmp_path / "a.db"), enc=str(tmp_path / "a.enc"), action="pack")
    assert cli.cmd_state(args, settings()) == 0
    assert "STATE_ENCRYPTION_KEY не задан" in capsys.readouterr().out
    assert not (tmp_path / "a.enc").exists()


def test_state_pack_and_unpack_roundtrip(tmp_path, capsys):
    db, enc = tmp_path / "a.db", tmp_path / "a.enc"
    db.write_bytes("данные".encode())
    s = settings(STATE_ENCRYPTION_KEY="k" * 12)
    assert cli.cmd_state(argparse.Namespace(db=str(db), enc=str(enc), action="pack"), s) == 0
    assert enc.exists() and "данные".encode() not in enc.read_bytes(), "в кэше только шифртекст"
    db.unlink()
    assert cli.cmd_state(argparse.Namespace(db=str(db), enc=str(enc), action="unpack"), s) == 0
    assert db.read_bytes() == "данные".encode()
    assert "восстановлено из кэша" in capsys.readouterr().out


def test_state_unpack_with_wrong_key_or_without_cache(tmp_path, capsys):
    db, enc = tmp_path / "a.db", tmp_path / "a.enc"
    db.write_bytes(b"x")
    cli.cmd_state(argparse.Namespace(db=str(db), enc=str(enc), action="pack"), settings(STATE_ENCRYPTION_KEY="k" * 12))
    db.unlink()
    capsys.readouterr()
    assert cli.cmd_state(argparse.Namespace(db=str(db), enc=str(enc), action="unpack"), settings(STATE_ENCRYPTION_KEY="другой ключ")) == 0
    assert "Не удалось расшифровать" in capsys.readouterr().out and not db.exists()
    enc.unlink()
    assert cli.cmd_state(argparse.Namespace(db=str(db), enc=str(enc), action="unpack"), settings(STATE_ENCRYPTION_KEY="k" * 12)) == 0
    assert "Кэша состояния нет" in capsys.readouterr().out


def test_state_pack_without_database_is_harmless(tmp_path):
    args = argparse.Namespace(db=str(tmp_path / "нет.db"), enc=str(tmp_path / "a.enc"), action="pack")
    assert cli.cmd_state(args, settings(STATE_ENCRYPTION_KEY="k" * 12)) == 0
    assert not (tmp_path / "a.enc").exists()


def test_export_json_and_csv(tmp_path, capsys):
    db = tmp_path / "a.db"
    st = Store(db)
    st.insert_lead(lead("1", "Первый"))
    st.insert_lead(lead("2", "Второй, с запятой"))
    st.close()
    out_json = tmp_path / "out" / "l.json"
    assert cli.cmd_export(argparse.Namespace(db=str(db), out=str(out_json), format="json"), settings()) == 0
    rows = json.loads(out_json.read_text(encoding="utf-8"))
    assert {r["title"] for r in rows} == {"Первый", "Второй, с запятой"} and all("lead_id" in r for r in rows)
    out_csv = tmp_path / "out" / "l.csv"
    assert cli.cmd_export(argparse.Namespace(db=str(db), out=str(out_csv), format="csv"), settings()) == 0
    parsed = list(csv.DictReader(out_csv.read_text(encoding="utf-8-sig").splitlines()))
    assert {r["title"] for r in parsed} == {"Первый", "Второй, с запятой"}
    assert "Не коммитьте" in capsys.readouterr().out


def test_export_of_empty_database(tmp_path):
    db = tmp_path / "a.db"
    Store(db).close()
    out = tmp_path / "e.json"
    assert cli.cmd_export(argparse.Namespace(db=str(db), out=str(out), format="json"), settings()) == 0
    assert json.loads(out.read_text(encoding="utf-8")) == []


def test_step_summary_contains_only_aggregates(tmp_path, monkeypatch):
    path = tmp_path / "summary.md"
    monkeypatch.setenv("GITHUB_STEP_SUMMARY", str(path))
    cli._write_step_summary({
        "mode": "dry-run", "sources_run": ["rss"], "skipped": {"vk": "выключен"}, "new_total": 3, "new_relevant": 2,
        "duplicates": 1, "notified": 0, "notion_synced": 0, "problems": ["rss: таймаут"], "warnings": ["мало данных"],
        "requests_7d": [{"source": "rss", "requests": 5, "errors": 1}]})
    text = path.read_text(encoding="utf-8")
    for expected in ("## Lead Generator (dry-run)", "Новых: 3, подходящих: 2, дублей: 1", "### Пропущены", "- vk: выключен",
                     "### Проблемы", "rss: таймаут", "### Предупреждения", "| rss | 5 | 1 |"):
        assert expected in text
    monkeypatch.delenv("GITHUB_STEP_SUMMARY")
    cli._write_step_summary({})  # без переменной окружения ничего не делает и не падает


def test_step_summary_omits_empty_sections(tmp_path, monkeypatch):
    path = tmp_path / "s.md"
    monkeypatch.setenv("GITHUB_STEP_SUMMARY", str(path))
    cli._write_step_summary({"mode": "live", "sources_run": [], "skipped": {}, "new_total": 0, "new_relevant": 0,
                             "duplicates": 0, "notified": 0, "notion_synced": 0, "problems": [], "warnings": [],
                             "requests_7d": []})
    text = path.read_text(encoding="utf-8")
    assert "Источники: —" in text
    assert "Пропущены" not in text and "Проблемы" not in text and "Предупреждения" not in text


def test_diagnose_prints_state_without_network(tmp_path, capsys):
    db = tmp_path / "a.db"
    st = Store(db)
    st.insert_lead(lead())
    st.close()
    s = Settings(data={"sources": {}}, secrets={"NOTION_TOKEN": "x" * 10, "TELEGRAM_BOT_TOKEN": ""}, mode="dry-run")
    assert cli.cmd_diagnose(argparse.Namespace(db=str(db), ping=False), s) == 0
    out = capsys.readouterr().out
    assert "Режим: dry-run" in out and "NOTION_TOKEN=есть" in out and "TELEGRAM_BOT_TOKEN=нет" in out
    assert "x" * 10 not in out, "значения секретов не печатаются"
    assert "Лидов в локальной базе: 1" in out


def test_diagnose_ping_refuses_outside_live_mode(tmp_path, capsys):
    s = Settings(data={"sources": {}}, secrets={}, mode="dry-run")
    assert cli.cmd_diagnose(argparse.Namespace(db=str(tmp_path / "нет.db"), ping=True), s) == 0
    assert "только при LEADGEN_MODE=live" in capsys.readouterr().out


def test_notion_init_requires_token(capsys):
    assert cli.cmd_notion_init(argparse.Namespace(parent="p"), settings()) == 2
    assert "NOTION_TOKEN" in capsys.readouterr().out


def test_main_rejects_missing_or_unknown_command(monkeypatch):
    monkeypatch.setattr(cli, "load_settings", lambda: settings())
    for argv in ([], ["нет-такой-команды"], ["state"], ["state", "weird"], ["export", "--format", "xml"]):
        with pytest.raises(SystemExit) as e:
            cli.main(argv)
        assert e.value.code == 2, argv


def test_main_dispatches_export(tmp_path, monkeypatch, capsys):
    db = tmp_path / "a.db"
    Store(db).close()
    monkeypatch.setattr(cli, "load_settings", lambda: settings())
    out = tmp_path / "m.json"
    assert cli.main(["--db", str(db), "export", "--out", str(out)]) == 0
    assert out.exists()
    capsys.readouterr()
