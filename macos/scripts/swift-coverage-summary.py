#!/usr/bin/env python3
"""Сводка покрытия строк Swift по модулям из JSON, который пишет `swift test --enable-code-coverage`.

Печатает таблицу в формате Markdown (для GITHUB_STEP_SUMMARY). Тесты и сборочные файлы не считаются.
"""
import json
import re
import sys
from collections import defaultdict


def summarize(report: dict) -> list[tuple[str, int, int]]:
    modules: dict[str, list[int]] = defaultdict(lambda: [0, 0])
    for entry in report.get("data", []):
        for f in entry.get("files", []):
            m = re.search(r"/Sources/([^/]+)/", f["filename"])
            if not m:
                continue
            lines = f["summary"]["lines"]
            modules[m.group(1)][0] += lines["covered"]
            modules[m.group(1)][1] += lines["count"]
    return sorted((name, c, t) for name, (c, t) in modules.items())


def render(rows: list[tuple[str, int, int]]) -> str:
    out = ["### Покрытие строк (Swift)", "", "| Модуль | Покрыто | Всего | % |", "|---|---|---|---|"]
    covered = total = 0
    for name, c, t in rows:
        covered += c
        total += t
        out.append(f"| {name} | {c} | {t} | {100 * c / t if t else 0:.1f} |")
    out.append(f"| **Итого** | {covered} | {total} | {100 * covered / total if total else 0:.1f} |")
    return "\n".join(out) + "\n"


if __name__ == "__main__":
    with open(sys.argv[1], encoding="utf-8") as fh:
        print(render(summarize(json.load(fh))))
