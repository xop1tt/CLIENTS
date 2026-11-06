"""Тесты облачной части на локальном стенде (supabase/tests/stack/up.sh).

Стенд — одноразовая база PostgreSQL, настоящий Supabase Auth (GoTrue) и PostgREST в Docker,
функции из supabase/functions в Deno и тестовый SMTP-сервер. Облачные проекты Supabase
(в том числе другой ваш проект) тесты не трогают: все адреса — 127.0.0.1.
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import time
import uuid
from pathlib import Path

import httpx
import psycopg
import pytest

STACK = Path(__file__).parent / "stack"


def _env() -> dict[str, str]:
    out = subprocess.run(["bash", "-c", f"source {STACK}/env.sh && env"], capture_output=True, text=True, check=True)
    return dict(line.split("=", 1) for line in out.stdout.splitlines() if "=" in line)


ENV = _env()
URL = ENV["SUPABASE_URL"]
ANON = ENV["SUPABASE_ANON_KEY"]
SERVICE = ENV["SUPABASE_SERVICE_ROLE_KEY"]
MAIL_DIR = Path(ENV["STACK_MAIL_DIR"])
PASSWORD = "Str0ngPassw0rd"

assert URL.startswith("http://127.0.0.1"), "тесты работают только с локальным стендом"


def db() -> psycopg.Connection:
    return psycopg.connect(host=ENV["PGHOST"], port=ENV["PGPORT"], user=ENV["PGUSER"], password=ENV["PGPASSWORD"],
                           dbname=ENV["STACK_DB"], autocommit=True)


@pytest.fixture(scope="session", autouse=True)
def stack_ready():
    try:
        httpx.get(f"{URL}/auth/v1/health", headers={"apikey": ANON}, timeout=3).raise_for_status()
    except Exception as e:  # pragma: no cover
        pytest.exit(f"локальный стенд не запущен ({e}). Запустите: supabase/tests/stack/up.sh", returncode=2)


DEFAULT_LIMITS = dict(global_daily_max=50, per_email_daily_max=5, signup_initial_max=1,
                      signup_resend_cooldown="15 minutes", recovery_cooldown="30 minutes",
                      email_change_cooldown="30 minutes", device_hourly_max=3, device_daily_max=5,
                      ip_hourly_max=10, ip_daily_max=30, require_gate_ticket=True,
                      enabled_actions=["signup", "recovery", "email_change"], day_timezone="Europe/Moscow")


def set_limits(**kw) -> None:
    vals = {**DEFAULT_LIMITS, **kw}
    cols = ", ".join(f"{k} = %({k})s" for k in vals)
    with db() as c:
        c.execute(f"update private.email_limits set {cols} where id = 1", vals)


@pytest.fixture(autouse=True)
def clean_state():
    """Перед каждым тестом: лимиты по умолчанию, пустые журналы писем и почтовый ящик."""
    set_limits()
    with db() as c:
        c.execute("delete from private.email_sends; delete from private.email_tickets; delete from private.email_requests")
    MAIL_DIR.mkdir(parents=True, exist_ok=True)
    for f in MAIL_DIR.glob("*.json"):
        f.unlink()
    (MAIL_DIR / "FAIL").unlink(missing_ok=True)
    yield
    (MAIL_DIR / "FAIL").unlink(missing_ok=True)


def unique_email(prefix: str = "user") -> str:
    return f"{prefix}-{uuid.uuid4().hex[:10]}@example.com"


def unique_ip() -> str:
    n = uuid.uuid4().int
    return f"10.{n % 250}.{(n >> 8) % 250}.{(n >> 16) % 250 + 1}"


class Client:
    """Клиент как приложение: только anon-ключ, своё устройство и IP."""

    def __init__(self, device: str | None = None, ip: str | None = None):
        self.device = device or uuid.uuid4().hex
        self.ip = ip or unique_ip()
        self.http = httpx.Client(base_url=URL, timeout=15)
        self.access: str | None = None
        self.refresh: str | None = None

    def h(self, token: str | None = None) -> dict[str, str]:
        hd = {"apikey": ANON, "x-test-client-ip": self.ip}
        if token or self.access:
            hd["authorization"] = f"Bearer {token or self.access}"
        return hd

    def gate(self, action: str, email: str) -> httpx.Response:
        return self.http.post("/functions/v1/email-gate", headers=self.h(),
                              json={"action": action, "email": email, "device_id": self.device})

    def signup(self, email: str, password: str = PASSWORD, gate: bool = True) -> httpx.Response:
        if gate:
            assert self.gate("signup", email).status_code == 200
        return self.http.post("/auth/v1/signup", headers={"apikey": ANON, "x-test-client-ip": self.ip},
                              json={"email": email, "password": password,
                                    "options": {"email_redirect_to": "leadgenerator://auth/callback"}})

    def verify(self, email: str, token: str, type_: str) -> httpx.Response:
        r = self.http.post("/auth/v1/verify", headers={"apikey": ANON, "x-test-client-ip": self.ip},
                           json={"type": type_, "email": email, "token": token})
        if r.status_code == 200 and "access_token" in r.json():
            self._take(r.json())
        return r

    def login(self, email: str, password: str = PASSWORD) -> httpx.Response:
        r = self.http.post("/auth/v1/token?grant_type=password", headers={"apikey": ANON, "x-test-client-ip": self.ip},
                           json={"email": email, "password": password})
        if r.status_code == 200:
            self._take(r.json())
        return r

    def refresh_session(self) -> httpx.Response:
        r = self.http.post("/auth/v1/token?grant_type=refresh_token", headers={"apikey": ANON, "x-test-client-ip": self.ip},
                           json={"refresh_token": self.refresh})
        if r.status_code == 200:
            self._take(r.json())
        return r

    def _take(self, s: dict) -> None:
        self.access, self.refresh = s["access_token"], s["refresh_token"]

    def rpc(self, name: str, args: dict) -> httpx.Response:
        return self.http.post(f"/rest/v1/rpc/{name}", headers=self.h(), json=args)

    def rest(self, method: str, path: str, **kw) -> httpx.Response:
        headers = {**self.h(), **kw.pop("headers", {})}
        return self.http.request(method, f"/rest/v1/{path}", headers=headers, **kw)


def mails(to: str | None = None, wait: float = 0.0) -> list[dict]:
    deadline = time.time() + wait
    while True:
        out = []
        for f in sorted(MAIL_DIR.glob("*.json")):
            m = json.loads(f.read_text())
            if to is None or to in m["to"]:
                out.append(m)
        if out or time.time() >= deadline:
            return out
        time.sleep(0.1)


def code_from(mail: dict) -> str:
    return re.search(r"Код: (\d{6})", mail["text"]).group(1)


def link_from(mail: dict) -> str:
    return re.search(r"Ссылка: (\S+)", mail["text"]).group(1)


def confirmed_user(email: str | None = None) -> tuple[Client, str]:
    """Зарегистрированный и подтверждённый пользователь с активной сессией."""
    email = email or unique_email()
    c = Client()
    assert c.signup(email).status_code == 200
    m = mails(email, wait=3)
    assert m, "письмо подтверждения не пришло"
    assert c.verify(email, code_from(m[-1]), "signup").status_code == 200
    return c, email
