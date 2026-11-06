"""Почтовые лимиты: проверяются в базе (атомарно), а не в приложении."""

import base64
import hashlib
import hmac
import json
import threading
import time
import uuid

import httpx

from conftest import ANON, ENV, MAIL_DIR, SERVICE, URL, Client, confirmed_user, db, mails, set_limits, unique_email


def sent_count(status: str = "sent") -> int:
    with db() as c:
        return c.execute("select count(*) from private.email_sends where status = %s", (status,)).fetchone()[0]


def recover(c: Client, email: str) -> httpx.Response:
    return c.http.post("/auth/v1/recover", headers={"apikey": ANON, "x-test-client-ip": c.ip}, json={"email": email})


def test_resend_confirmation_before_cooldown_is_refused():
    c = Client()
    email = unique_email()
    assert c.signup(email).status_code == 200
    assert len(mails(email, wait=3)) == 1
    # Повтор через 0 минут: шлюз отказывает и говорит, сколько ждать.
    r = c.gate("signup", email)
    assert r.status_code == 429
    body = r.json()
    assert body["reason"] == "cooldown" and 0 < body["retry_after"] <= 15 * 60
    assert "Повторите через" in body["message"]
    # Прямой вызов /resend в обход приложения письма тоже не отправит.
    r = c.http.post("/auth/v1/resend", headers={"apikey": ANON}, json={"type": "signup", "email": email})
    assert r.status_code >= 400
    assert len(mails(email)) == 1


def test_resend_allowed_after_cooldown():
    c = Client()
    email = unique_email()
    c.signup(email)
    mails(email, wait=3)
    with db() as d:  # «прошло 16 минут»
        d.execute("update private.email_sends set created_at = now() - interval '16 minutes'")
        d.execute("update private.email_tickets set created_at = now() - interval '16 minutes'")
    assert c.gate("signup", email).status_code == 200
    time.sleep(1.1)  # стенд: GOTRUE_SMTP_MAX_FREQUENCY=1s (в облаке по умолчанию 60 с)
    r = c.http.post("/auth/v1/resend", headers={"apikey": ANON}, json={"type": "signup", "email": email})
    assert r.status_code == 200, r.text
    assert len(mails(email, wait=3)) == 2


def test_recovery_cooldown_30_minutes():
    _, email = confirmed_user()
    c = Client()
    assert c.gate("recovery", email).status_code == 200
    assert recover(c, email).status_code == 200
    r = c.gate("recovery", email)
    assert r.status_code == 429 and r.json()["reason"] == "cooldown"
    assert 25 * 60 < r.json()["retry_after"] <= 30 * 60


def test_per_email_daily_limit():
    set_limits(recovery_cooldown="0", device_hourly_max=100, device_daily_max=100)
    _, email = confirmed_user()  # 1 письмо (регистрация)
    c = Client()
    for _ in range(4):
        time.sleep(1.1)  # стенд: GOTRUE_SMTP_MAX_FREQUENCY=1s
        assert c.gate("recovery", email).status_code == 200
        assert recover(c, email).status_code == 200
    assert sent_count() == 5
    r = c.gate("recovery", email)
    assert r.status_code == 429 and r.json()["reason"] == "email_daily"


def test_device_hourly_and_daily_limits():
    dev = Client()
    for _ in range(3):
        assert dev.gate("recovery", unique_email()).status_code == 200
    r = dev.gate("recovery", unique_email())
    assert r.status_code == 429 and r.json()["reason"] == "device_hourly"
    # Через час лимит часа снова пускает, но действует суточный (5).
    with db() as d:
        d.execute("update private.email_requests set created_at = greatest(created_at - interval '61 minutes', "
                  "private.day_start('Europe/Moscow') + interval '1 second')")
    assert dev.gate("recovery", unique_email()).status_code == 200
    assert dev.gate("recovery", unique_email()).status_code == 200
    r = dev.gate("recovery", unique_email())
    assert r.status_code == 429 and r.json()["reason"] in ("device_daily", "device_hourly")


def test_device_id_spoofing_still_hits_ip_limit():
    ip = "10.200.0.1"
    codes = []
    for _ in range(12):
        c = Client(ip=ip)  # каждый раз «новое устройство»
        r = c.gate("recovery", unique_email())
        codes.append((r.status_code, r.json().get("reason")))
    assert codes[:10] == [(200, None)] * 10
    assert codes[10] == (429, "ip_hourly")


def test_global_daily_limit_blocks_everyone():
    set_limits(global_daily_max=3)
    for _ in range(3):
        c = Client()
        e = unique_email()
        assert c.signup(e).status_code == 200
    assert sent_count() == 3
    c = Client()
    r = c.gate("signup", unique_email())
    assert r.status_code == 429 and r.json()["reason"] == "global_daily"
    assert "обновления суточного лимита" in r.json()["message"]
    assert r.json()["retry_after"] > 0


def test_global_limit_holds_without_gate_tickets():
    """Даже если владелец отключит талоны, общий лимит действует в самом хуке."""
    set_limits(global_daily_max=2, require_gate_ticket=False)
    ok = 0
    for _ in range(4):
        r = Client().signup(unique_email(), gate=False)
        ok += r.status_code == 200
    assert ok == 2 and sent_count() == 2


def test_parallel_requests_cannot_exceed_global_limit():
    set_limits(global_daily_max=5, require_gate_ticket=False)
    results = []

    def reserve(i):
        r = httpx.post(f"{URL}/rest/v1/rpc/email_hook_reserve",
                       headers={"apikey": SERVICE, "authorization": f"Bearer {SERVICE}"},
                       json={"p_webhook_id": f"wh-{uuid.uuid4()}", "p_action": "recovery",
                             "p_owner_email": f"p{i}@example.com", "p_recipients": [f"p{i}@example.com"]}, timeout=30)
        results.append(r.json()["allowed"])

    threads = [threading.Thread(target=reserve, args=(i,)) for i in range(30)]
    [t.start() for t in threads]
    [t.join() for t in threads]
    assert results.count(True) == 5
    assert sent_count("reserved") == 5


def test_parallel_signups_full_flow():
    set_limits(global_daily_max=4, device_hourly_max=100, device_daily_max=100, ip_hourly_max=100, ip_daily_max=100)
    out = []

    def go():
        c = Client()
        e = unique_email()
        g = c.gate("signup", e)
        if g.status_code == 200:
            out.append(c.signup(e, gate=False).status_code)
        else:
            out.append(g.json()["reason"])

    threads = [threading.Thread(target=go) for _ in range(12)]
    [t.start() for t in threads]
    [t.join() for t in threads]
    assert sent_count() == 4
    assert len(mails(wait=2)) == 4


def test_direct_auth_api_without_ticket_sends_nothing():
    email = unique_email()
    r = Client().signup(email, gate=False)
    assert r.status_code == 500
    with db() as d:
        assert d.execute("select count(*) from auth.users where email=%s", (email,)).fetchone()[0] == 0
    assert mails(email) == []
    # magic link (не используется приложением) тоже не отправляется.
    r = httpx.post(f"{URL}/auth/v1/otp", headers={"apikey": ANON}, json={"email": email, "create_user": True})
    assert r.status_code >= 400
    assert mails(email) == []


def test_ticket_is_single_use_and_bound_to_address():
    _, email = confirmed_user()
    set_limits(recovery_cooldown="0")
    c = Client()
    assert c.gate("recovery", email).status_code == 200
    assert recover(c, email).status_code == 200
    assert recover(c, email).status_code >= 400  # талон уже израсходован
    other = unique_email()
    assert c.gate("recovery", other).status_code == 200
    assert recover(c, email).status_code >= 400  # талон выдан на другой адрес


def test_quota_rpcs_not_callable_by_clients():
    c, _ = confirmed_user()
    for name, args in [("email_gate_request", {"p_action": "signup", "p_email": "x@example.com", "p_device": "d", "p_ip": "1.1.1.1"}),
                       ("email_hook_reserve", {"p_webhook_id": "w", "p_action": "signup", "p_owner_email": "x@example.com",
                                               "p_recipients": ["x@example.com"]}),
                       ("email_hook_finish", {"p_webhook_id": "w", "p_sent": [], "p_failed": [], "p_error": None})]:
        assert Client().rpc(name, args).status_code in (401, 403, 404), name
        assert c.rpc(name, args).status_code in (401, 403, 404), name
    # Настройки лимитов в схеме private недоступны через API.
    assert c.rest("GET", "email_limits").status_code in (401, 403, 404)


def _sign(secret: str, wid: str, ts: str, body: str) -> str:
    key = base64.b64decode(secret.replace("v1,whsec_", ""))
    return base64.b64encode(hmac.new(key, f"{wid}.{ts}.{body}".encode(), hashlib.sha256).digest()).decode()


def _payload(email: str) -> str:
    return json.dumps({"user": {"id": str(uuid.uuid4()), "email": email}, "email_data": {
        "token": "123456", "token_hash": "abc", "redirect_to": "leadgenerator://auth/callback",
        "email_action_type": "recovery", "site_url": "leadgenerator://auth/callback", "token_new": "", "token_hash_new": ""}})


def test_send_email_hook_rejects_forged_and_replayed_calls():
    set_limits(require_gate_ticket=False)
    body = _payload(unique_email())
    url = f"{URL}/functions/v1/send-email"
    ts = str(int(time.time()))
    assert httpx.post(url, content=body).status_code == 401
    bad = {"webhook-id": "x", "webhook-timestamp": ts, "webhook-signature": "v1,AAAA"}
    assert httpx.post(url, content=body, headers=bad).status_code == 401
    old = str(int(time.time()) - 3600)
    replay = {"webhook-id": "x", "webhook-timestamp": old,
              "webhook-signature": "v1," + _sign(ENV["SEND_EMAIL_HOOK_SECRET"], "x", old, body)}
    assert httpx.post(url, content=body, headers=replay).status_code == 401
    assert mails() == [] and sent_count("reserved") == 0


def test_hook_retry_with_same_webhook_id_counts_once():
    set_limits(require_gate_ticket=False)
    email = unique_email()
    body = _payload(email)
    ts = str(int(time.time()))
    wid = f"msg_{uuid.uuid4().hex}"
    h = {"webhook-id": wid, "webhook-timestamp": ts, "webhook-signature": "v1," + _sign(ENV["SEND_EMAIL_HOOK_SECRET"], wid, ts, body),
         "content-type": "application/json"}
    assert httpx.post(f"{URL}/functions/v1/send-email", content=body, headers=h).status_code == 200
    assert httpx.post(f"{URL}/functions/v1/send-email", content=body, headers=h).status_code == 200
    assert len(mails(email, wait=2)) == 1 and sent_count() == 1


def test_daily_quota_resets_at_day_boundary():
    set_limits(global_daily_max=2)
    with db() as d:  # вчера отправлено 2 письма — сегодня это не мешает
        d.execute("insert into private.email_sends (webhook_id, action, email_hash, status, created_at) "
                  "select 'old-' || g, 'signup', md5(g::text), 'sent', private.day_start('Europe/Moscow') - interval '1 minute' "
                  "from generate_series(1, 2) g")
    assert Client().signup(unique_email()).status_code == 200
    assert Client().signup(unique_email()).status_code == 200
    r = Client().gate("signup", unique_email())
    assert r.status_code == 429 and r.json()["reason"] == "global_daily"


def test_smtp_failure_does_not_consume_quota():
    c = Client()
    email = unique_email()
    assert c.gate("signup", email).status_code == 200
    (MAIL_DIR / "FAIL").write_text("1")
    r = c.signup(email, gate=False)
    assert r.status_code == 500
    assert sent_count() == 0 and sent_count("failed") == 1
    (MAIL_DIR / "FAIL").unlink()
    # Талон вернулся: повтор той же регистрации проходит без нового запроса в шлюз.
    r = c.signup(email, gate=False)
    assert r.status_code == 200, r.text
    assert len(mails(email, wait=3)) == 1 and sent_count() == 1


def test_limits_are_configurable_without_release():
    set_limits(enabled_actions=["signup", "email_change"])
    _, email = confirmed_user()
    r = Client().gate("recovery", email)
    assert r.status_code == 429 and r.json()["reason"] == "action_disabled"


def test_addresses_stored_only_as_hashes():
    c = Client()
    email = unique_email("privacy")
    c.signup(email)
    mails(email, wait=3)
    with db() as d:
        dump = json.dumps([list(map(str, r)) for t in ("email_sends", "email_tickets", "email_requests")
                           for r in d.execute(f"select * from private.{t}").fetchall()])
    assert email not in dump and c.device not in dump and c.ip not in dump


def test_gate_does_not_reveal_whether_account_exists():
    """Ответы шлюза одинаковы для существующего и несуществующего адреса."""
    set_limits(device_hourly_max=100, device_daily_max=100)
    _, existing = confirmed_user()
    missing = unique_email("missing")
    answers = {}
    for email in (existing, missing):
        c = Client()
        first = c.gate("recovery", email)
        assert first.status_code == 200
        assert recover(c, email).status_code == 200   # Auth отвечает одинаково
        second = c.gate("recovery", email)
        answers[email] = (second.status_code, second.json().get("reason"))
    assert answers[existing] == answers[missing] == (429, "cooldown")


def test_partial_smtp_failure_counts_the_delivered_mail():
    c, email = confirmed_user()
    new = unique_email("partial")
    assert c.gate("email_change", email).status_code == 200
    (MAIL_DIR / "FAIL").write_text(new)
    try:
        r = c.http.put("/auth/v1/user", headers=c.h(), json={"email": new})
        assert r.status_code >= 500
    finally:
        (MAIL_DIR / "FAIL").unlink()
    assert any("смену адреса" in m["subject"] for m in mails(email, wait=3))
    with db() as d:
        rows = dict(d.execute("select status, count(*) from private.email_sends where action = 'email_change' "
                              "group by status").fetchall())
        refunded = d.execute("select bool_or(refunded) from private.email_tickets where action = 'email_change'").fetchone()[0]
    assert rows.get("sent") == 1 and rows.get("failed") == 1
    assert refunded is False  # первое письмо ушло: талон не возвращается, повтор — через интервал
