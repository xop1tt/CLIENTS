"""Статический аудит GitHub Actions: закреплённые SHA, минимальные права, защита от параллельных запусков."""
import re
from pathlib import Path

import yaml

WF = Path(__file__).resolve().parents[1] / ".github" / "workflows"


def load(name):
    return yaml.safe_load((WF / name).read_text(encoding="utf-8"))


def test_actions_pinned_by_full_sha():
    for f in WF.glob("*.yml"):
        for line in f.read_text(encoding="utf-8").splitlines():
            if "uses:" in line:
                ref = line.split("uses:")[1].split("#")[0].strip()
                assert re.fullmatch(r"[\w./-]+@[0-9a-f]{40}", ref), f"{f.name}: {ref}"


def test_minimal_permissions_everywhere():
    for f in WF.glob("*.yml"):
        assert yaml.safe_load(f.read_text(encoding="utf-8"))["permissions"] == {"contents": "read"}, f.name


def test_search_is_manual_only_with_concurrency():
    wf = load("search.yml")
    on = wf[True]  # YAML 1.1: ключ "on" парсится как True
    # Расписание выключено: поиск идёт в приложении для macOS, Actions — только ручной запуск.
    assert "workflow_dispatch" in on and "schedule" not in on
    assert wf["concurrency"] == {"group": "lead-search", "cancel-in-progress": False}
    assert wf["jobs"]["search"]["timeout-minutes"] <= 30


def test_tests_workflow_has_no_secrets_and_no_pull_request_target():
    text = (WF / "tests.yml").read_text(encoding="utf-8")
    assert "secrets." not in text and "pull_request_target" not in text


def test_inputs_not_interpolated_into_shell():
    for f in WF.glob("*.yml"):
        wf = yaml.safe_load(f.read_text(encoding="utf-8"))
        for job in wf["jobs"].values():
            for step in job["steps"]:
                assert "${{ inputs." not in step.get("run", ""), f"{f.name}: inputs в run — риск инъекции"


def test_no_data_files_tracked():
    gi = (WF.parents[1] / ".gitignore").read_text()
    for pattern in ("state/", "*.db", "*.csv", ".env"):
        assert pattern in gi
