"""Диагностика сообщает только, задан ли секрет, и никогда не печатает его значение
(code scanning: py/clear-text-logging-sensitive-data). Дополняет test_reference_cli.py."""
from __future__ import annotations

import argparse

from leadgen import cli
from leadgen.config.settings import ENV_VAR_NAMES, SECRET_NAMES, Settings


def _run(tmp_path, capsys, secrets):
    s = Settings(data={"sources": {}}, secrets=secrets, mode="dry-run")
    assert cli.cmd_diagnose(argparse.Namespace(db=str(tmp_path / "none.db"), ping=False), s) == 0
    return capsys.readouterr().out


def test_every_known_secret_is_listed_with_presence_only(tmp_path, capsys):
    values = {n: f"value-of-{n.lower()}-0123456789" for n in SECRET_NAMES}
    out = _run(tmp_path, capsys, values)
    line = next(l for l in out.splitlines() if l.startswith("Секреты:"))
    for n in SECRET_NAMES:
        assert f"{n}=есть" in line
    for v in values.values():
        assert v not in out
        assert v[:6] not in out, "даже начало значения не печатается"


def test_missing_and_empty_secrets_are_reported_as_absent(tmp_path, capsys):
    out = _run(tmp_path, capsys, {"NOTION_TOKEN": ""})
    for n in SECRET_NAMES:
        assert f"{n}=нет" in out


def test_unknown_keys_are_not_printed(tmp_path, capsys):
    out = _run(tmp_path, capsys, {"SOMETHING_ELSE": "very-secret-value-123"})
    assert "SOMETHING_ELSE" not in out and "very-secret-value-123" not in out


def test_is_set():
    s = Settings(data={}, secrets={"A": "1", "B": ""})
    assert s.is_set("A") and not s.is_set("B") and not s.is_set("C")


def test_diagnose_lists_the_same_names_that_are_loaded():
    assert ENV_VAR_NAMES is SECRET_NAMES
