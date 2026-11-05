"""Общие фикстуры. Любой немокнутый HTTP-запрос падает — тесты физически не ходят в сеть."""
from __future__ import annotations

import copy
from datetime import timedelta
from email.utils import format_datetime
from pathlib import Path

import pytest
import respx

from leadgen.config.settings import ROOT, Settings, load_settings
from leadgen.core.http import SourceHttp
from leadgen.core.models import utcnow
from leadgen.scheduler.runner import Pipeline
from leadgen.storage.sqlite_store import Store

FIX = Path(__file__).parent / "fixtures"


def load_fixture(name: str, age: timedelta = timedelta(hours=1)) -> str:
    now = utcnow() - age
    text = (FIX / name).read_text(encoding="utf-8")
    return (text.replace("{NOW_RFC822}", format_datetime(now)).replace("{DT}", now.isoformat())
            .replace("{NOW_TS}", str(int(now.timestamp()))))


@pytest.fixture(autouse=True)
def no_network():
    with respx.mock(assert_all_called=False, assert_all_mocked=True) as mock:
        yield mock


@pytest.fixture
def store():
    s = Store(":memory:")
    yield s
    s.close()


@pytest.fixture
def base_settings() -> Settings:
    return load_settings(ROOT / "config.example.yaml", env={})


def make_settings(mode: str = "dry-run", secrets: dict | None = None, patch=None) -> Settings:
    s = load_settings(ROOT / "config.example.yaml", env={})
    data = copy.deepcopy(s.data)
    if patch:
        patch(data)
    sec = dict(s.secrets)
    sec.update(secrets or {})
    return Settings(data=data, secrets=sec, mode=mode)


def http_factory(store: Store):
    def make(name, cfg):
        h = cfg.get("http", {})
        return SourceHttp(name, store, min_interval=0, max_requests_per_run=int(h.get("max_requests_per_run", 50)),
                          max_requests_per_day=h.get("max_requests_per_day"), max_attempts=int(h.get("max_attempts", 3)),
                          base_delay=0, sleep=lambda s: None)
    return make


def make_pipeline(settings: Settings, store: Store) -> Pipeline:
    return Pipeline(settings, store, http_factory=http_factory(store), sleep=lambda s: None)
