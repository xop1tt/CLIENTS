"""Регистрация, вход, восстановление и смена пароля, смена адреса — через настоящий Supabase Auth."""

import time
import uuid
from urllib.parse import parse_qs, urlparse

import httpx

from conftest import ANON, PASSWORD, Client, code_from, confirmed_user, db, link_from, mails, set_limits, unique_email


def test_signup_sends_one_confirmation_and_confirm_by_code():
    email = unique_email()
    c = Client()
    r = c.signup(email)
    assert r.status_code == 200, r.text
    assert r.json()["email"] == email
    m = mails(email, wait=3)
    assert len(m) == 1
    assert "подтвердите адрес" in m[0]["subject"]
    # До подтверждения войти нельзя.
    r = c.login(email)
    assert r.status_code == 400 and r.json()["error_code"] == "email_not_confirmed"
    r = c.verify(email, code_from(m[0]), "signup")
    assert r.status_code == 200 and r.json()["user"]["email_confirmed_at"]
    assert c.login(email).status_code == 200


def test_confirm_by_link_redirects_into_app_once():
    email = unique_email()
    c = Client()
    c.signup(email)
    link = link_from(mails(email, wait=3)[0])
    r = httpx.get(link, follow_redirects=False)
    assert r.status_code in (302, 303)
    loc = r.headers["location"]
    assert loc.startswith("leadgenerator://auth/callback")
    frag = parse_qs(urlparse(loc).fragment)
    assert frag.get("access_token") and frag.get("refresh_token") and frag["type"] == ["signup"]
    # Повторно ссылка не срабатывает.
    loc2 = httpx.get(link, follow_redirects=False).headers["location"]
    assert "error" in loc2 and "access_token" not in loc2


def test_signup_existing_confirmed_email_does_not_reveal_or_send():
    _, email = confirmed_user()
    before = len(mails(email))
    set_limits(signup_resend_cooldown="0")  # чтобы шлюз не остановил повтор раньше Auth
    c = Client()
    r = c.signup(email, "An0therPassword")
    # Ответ как при новой регистрации (без признаков существующего аккаунта), письмо не уходит.
    assert r.status_code == 200
    assert r.json().get("identities") == []
    time.sleep(0.5)
    assert len(mails(email)) == before
    # И войти с чужим паролем нельзя.
    assert c.login(email, "An0therPassword").status_code == 400


def test_invalid_email_rejected_by_gate_and_auth():
    c = Client()
    for bad in ["no-at-sign", "a@b", "a b@example.com", "x@example.com\r\nBcc: y@example.com"]:
        assert c.gate("signup", bad).status_code == 400
    r = c.signup("not-an-email", gate=False)
    assert r.status_code in (400, 422)
    assert mails() == []


def test_weak_password_rejected():
    c = Client()
    for pw in ["short1A", "alllowercase1", "NoDigitsHere"]:
        r = c.signup(unique_email(), pw)
        assert r.status_code == 422, (pw, r.text)
        assert r.json()["error_code"] == "weak_password"


def test_wrong_password_and_unknown_user_same_error():
    _, email = confirmed_user()
    c = Client()
    r1 = c.login(email, "Wr0ngPassword")
    r2 = c.login(unique_email(), "Wr0ngPassword")
    assert r1.status_code == r2.status_code == 400
    assert r1.json()["error_code"] == r2.json()["error_code"] == "invalid_credentials"
    assert r1.json()["msg"] == r2.json()["msg"]


def test_logout_revokes_refresh_and_session():
    c, _ = confirmed_user()
    access, refresh = c.access, c.refresh
    assert c.http.get("/auth/v1/user", headers=c.h()).status_code == 200
    assert c.http.post("/auth/v1/logout", headers=c.h()).status_code == 204
    r = c.http.post("/auth/v1/token?grant_type=refresh_token", headers={"apikey": ANON}, json={"refresh_token": refresh})
    assert r.status_code == 400
    # Access token ещё не истёк, но сессия удалена — Auth его не принимает.
    r = c.http.get("/auth/v1/user", headers={"apikey": ANON, "authorization": f"Bearer {access}"})
    assert r.status_code == 403


def test_refresh_rotation_and_reuse_detection():
    c, _ = confirmed_user()
    old = c.refresh
    assert c.refresh_session().status_code == 200
    assert c.refresh != old
    assert c.refresh_session().status_code == 200
    # Повторное использование старого refresh-токена (признак кражи) — отказ,
    # и Auth отзывает всю цепочку: текущий токен тоже перестаёт работать.
    r = c.http.post("/auth/v1/token?grant_type=refresh_token", headers={"apikey": ANON}, json={"refresh_token": old})
    assert r.status_code == 400 and r.json()["error_code"] == "refresh_token_already_used"
    assert c.refresh_session().status_code == 400


def test_password_recovery_full_flow_and_link_single_use():
    c, email = confirmed_user()
    other = Client()
    assert other.login(email).status_code == 200  # вторая сессия на другом устройстве

    r = Client()
    assert r.gate("recovery", email).status_code == 200
    assert r.http.post("/auth/v1/recover", headers={"apikey": ANON}, json={"email": email}).status_code == 200
    m = [x for x in mails(email, wait=3) if "восстановление" in x["subject"]]
    assert len(m) == 1
    code = code_from(m[0])
    assert r.verify(email, code, "recovery").status_code == 200
    # Код одноразовый.
    assert Client().verify(email, code, "recovery").status_code in (400, 403)

    new = "N3wPassword!"
    assert r.http.put("/auth/v1/user", headers=r.h(), json={"password": new}).status_code == 200
    # Политика: после смены пароля завершаем все остальные сессии.
    assert r.http.post("/auth/v1/logout?scope=others", headers=r.h()).status_code == 204
    assert other.refresh_session().status_code == 400
    assert Client().login(email, PASSWORD).status_code == 400
    assert Client().login(email, new).status_code == 200


def test_recovery_for_unknown_email_looks_the_same():
    r = Client()
    email = unique_email("nobody")
    assert r.gate("recovery", email).status_code == 200
    resp = r.http.post("/auth/v1/recover", headers={"apikey": ANON}, json={"email": email})
    assert resp.status_code == 200
    time.sleep(0.5)
    assert mails(email) == []


def test_change_password_requires_current_password_check():
    c, email = confirmed_user()
    # Приложение сначала проверяет текущий пароль обычным входом — неверный не проходит.
    assert Client().login(email, "Wr0ngCurrent1").status_code == 400
    assert c.login(email, PASSWORD).status_code == 200
    weak = c.http.put("/auth/v1/user", headers=c.h(), json={"password": "weak"})
    assert weak.status_code == 422
    assert c.http.put("/auth/v1/user", headers=c.h(), json={"password": "Ch4ngedPassword"}).status_code == 200
    assert Client().login(email, "Ch4ngedPassword").status_code == 200


def test_email_change_needs_both_confirmations():
    c, email = confirmed_user()
    new = unique_email("new")
    assert c.gate("email_change", email).status_code == 200
    r = c.http.put("/auth/v1/user", headers=c.h(), json={"email": new})
    assert r.status_code == 200, r.text
    cur_mail = [m for m in mails(email, wait=3) if "смену адреса" in m["subject"]]
    new_mail = mails(new, wait=3)
    assert len(cur_mail) == 1 and len(new_mail) == 1
    # Подтвердить только новый адрес мало: адрес не меняется (защита от захвата).
    assert c.verify(new, code_from(new_mail[0]), "email_change").status_code == 200
    user = c.http.get("/auth/v1/user", headers=c.h()).json()
    assert user["email"] == email
    assert c.verify(email, code_from(cur_mail[0]), "email_change").status_code == 200
    user = c.http.get("/auth/v1/user", headers=c.h()).json()
    assert user["email"] == new
    assert Client().login(new).status_code == 200
    assert Client().login(email).status_code == 400


def test_email_change_unconfirmed_keeps_old_email():
    c, email = confirmed_user()
    new = unique_email("pending")
    c.gate("email_change", email)
    assert c.http.put("/auth/v1/user", headers=c.h(), json={"email": new}).status_code == 200
    user = c.http.get("/auth/v1/user", headers=c.h()).json()
    assert user["email"] == email and user.get("new_email") == new
    assert Client().login(email).status_code == 200
    assert Client().login(new).status_code == 400


def test_email_change_to_taken_address_rejected():
    c, email = confirmed_user()
    _, taken = confirmed_user()
    c.gate("email_change", email)
    r = c.http.put("/auth/v1/user", headers=c.h(), json={"email": taken})
    assert r.status_code == 422 and r.json()["error_code"] == "email_exists"
    assert mails(taken) == [m for m in mails(taken) if "подтвердите адрес" in m["subject"]]


def test_expired_access_token_rejected_and_refresh_works():
    c, _ = confirmed_user()
    # Подменённый токен с истёкшим сроком (подписан чужим ключом) не принимается.
    head, _, _ = c.access.split(".")
    forged = head + ".eyJzdWIiOiJ4Iiwicm9sZSI6ImF1dGhlbnRpY2F0ZWQiLCJleHAiOjF9.c2ln"
    assert c.rest("GET", "leads", headers={"authorization": f"Bearer {forged}"}).status_code == 401
    assert c.refresh_session().status_code == 200
    assert c.rest("GET", "leads").status_code == 200


def test_password_bruteforce_is_rate_limited_per_ip():
    _, email = confirmed_user()
    attacker = Client()
    codes = [attacker.login(email, f"Guess{uuid.uuid4().hex[:6]}1").status_code for _ in range(40)]
    assert 429 in codes, codes
    # Другой IP (другой пользователь за другим адресом) не заблокирован.
    assert Client().login(email).status_code == 200


def test_delete_account_requires_recent_password_and_cascades():
    c, email = confirmed_user()
    uid = c.http.get("/auth/v1/user", headers=c.h()).json()["id"]
    assert c.rpc("sync_push", {"p_device": "d1", "p_changes": {"settings": [
        {"key": "draft.signature", "value": "x", "changed_at": "2026-01-01T00:00:00Z"}]}}).status_code == 200
    with db() as d:
        assert d.execute("select count(*) from public.user_settings where user_id=%s", (uid,)).fetchone()[0] == 1
    assert c.http.post("/functions/v1/delete-account", headers={"x-test-client-ip": c.ip}).status_code == 401
    # Сессия получена по коду из письма, а не по паролю: нужно ввести пароль ещё раз.
    r = c.http.post("/functions/v1/delete-account", headers=c.h())
    assert r.status_code == 403 and r.json()["reason"] == "reauth_required"
    assert c.login(email).status_code == 200
    r = c.http.post("/functions/v1/delete-account", headers=c.h())
    assert r.status_code == 200, r.text
    with db() as d:
        assert d.execute("select count(*) from auth.users where id=%s", (uid,)).fetchone()[0] == 0
        assert d.execute("select count(*) from public.user_settings where user_id=%s", (uid,)).fetchone()[0] == 0
    assert Client().login(email).status_code == 400
