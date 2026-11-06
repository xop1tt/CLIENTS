"""Загрузка конфигурации (YAML) и секретов (только из переменных окружения)."""
from __future__ import annotations

import os
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import yaml

ROOT = Path(__file__).resolve().parents[3]

SECRET_NAMES = (
    "TELEGRAM_BOT_TOKEN",
    "TELEGRAM_CHAT_ID",
    "NOTION_TOKEN",
    "NOTION_DATABASE_ID",
    "STATE_ENCRYPTION_KEY",
    "VK_SERVICE_TOKEN",
    "HUNTER_API_KEY",
    "WEBHOOK_URL",
    "WEBHOOK_SECRET",
)


@dataclass
class Settings:
    data: dict[str, Any]
    secrets: dict[str, str] = field(default_factory=dict)
    # dry-run: ничего не отправляем наружу; live: боевой режим;
    # notion-only: пишем только в Notion (проверочный запуск), Telegram и адаптеры — как в dry-run
    mode: str = "dry-run"

    @property
    def live(self) -> bool:
        return self.mode == "live"

    @property
    def notion_live(self) -> bool:
        return self.mode in ("live", "notion-only")

    def section(self, *path: str, default: Any = None) -> Any:
        node: Any = self.data
        for p in path:
            if not isinstance(node, dict) or p not in node:
                return {} if default is None else default
            node = node[p]
        return node

    def secret(self, name: str) -> str | None:
        v = self.secrets.get(name)
        return v or None

    def secret_values(self) -> list[str]:
        """Значения секретов — для вычистки из логов."""
        return [v for v in self.secrets.values() if v and len(v) >= 6]


def load_settings(path: str | os.PathLike | None = None, env: dict[str, str] | None = None) -> Settings:
    env = dict(os.environ if env is None else env)
    if path is None:
        path = env.get("LEADGEN_CONFIG")
    if path is None:
        cfg = ROOT / "config.yaml"
        path = cfg if cfg.exists() else ROOT / "config.example.yaml"
    with open(path, encoding="utf-8") as fh:
        data = yaml.safe_load(fh) or {}
    mode = (env.get("LEADGEN_MODE") or data.get("mode") or "dry-run").strip().lower()
    if mode not in ("dry-run", "live", "notion-only"):
        mode = "dry-run"
    secrets = {n: env.get(n, "").strip() for n in SECRET_NAMES}
    return Settings(data=data, secrets=secrets, mode=mode)
