// Модульные тесты общих частей функций: deno test supabase/functions
import { assert, assertEquals, assertRejects, assertThrows } from "jsr:@std/assert@1";
import { parseSecrets, sign, verifyWebhook, WebhookError } from "./webhook.ts";
import { planMails, safeRedirect } from "./plan.ts";
import { clientIp } from "./ip.ts";
import { render, verifyLink } from "./templates.ts";
import { buildMessage, SmtpError } from "./smtp.ts";
import { limitMessage } from "./messages.ts";

// Тестовый секрет собирается при запуске: готовый литерал "v1,whsec_…" secret scanning считает утечкой.
const SECRET = `v1,whsec_${btoa("test-hook-secret-1234567890abcdef")}`;

Deno.test("webhook: valid signature accepted, tampered body and old timestamp rejected", async () => {
  const [key] = parseSecrets(SECRET);
  const now = 1_800_000_000;
  const body = '{"a":1}';
  const sig = await sign(key, "msg_1", String(now), body);
  const h = new Headers({ "webhook-id": "msg_1", "webhook-timestamp": String(now), "webhook-signature": `v1,${sig}` });
  assertEquals((await verifyWebhook(h, body, [key], now)).id, "msg_1");
  await assertRejects(() => verifyWebhook(h, '{"a":2}', [key], now), WebhookError);
  await assertRejects(() => verifyWebhook(h, body, [key], now + 3600), WebhookError);
  await assertRejects(() => verifyWebhook(new Headers(), body, [key], now), WebhookError);
});

Deno.test("webhook: several secrets for rotation", async () => {
  const keys = parseSecrets(`v1,whsec_${btoa("old-secret")}|${SECRET}`);
  assertEquals(keys.length, 2);
  const sig = await sign(keys[1], "id", "100", "b");
  const h = new Headers({ "webhook-id": "id", "webhook-timestamp": "100", "webhook-signature": `v1,AAAA v1,${sig}` });
  await verifyWebhook(h, "b", keys, 100);
});

const data = (o: Record<string, string>) => ({
  token: "", token_hash: "", redirect_to: "", email_action_type: "signup", site_url: "", token_new: "", token_hash_new: "", ...o,
});

Deno.test("plan: secure email change sends two mails with swapped hash fields", () => {
  const p = planMails({
    user: { id: "u", email: "old@example.com", new_email: "new@example.com" },
    email_data: data({ email_action_type: "email_change", token: "111111", token_hash_new: "hcur", token_new: "222222", token_hash: "hnew" }),
  });
  assert(!p.skip);
  if (p.skip) return;
  assertEquals(p.owner, "old@example.com");
  assertEquals(p.mails.map((m) => [m.to, m.code, m.tokenHash]), [
    ["old@example.com", "111111", "hcur"],
    ["new@example.com", "222222", "hnew"],
  ]);
});

Deno.test("plan: non-secure email change sends one mail to new address", () => {
  const p = planMails({
    user: { id: "u", email: "old@example.com", new_email: "new@example.com" },
    email_data: data({ email_action_type: "email_change", token: "333333", token_hash: "h" }),
  });
  if (p.skip) throw new Error("skip");
  assertEquals(p.mails.length, 1);
  assertEquals(p.mails[0].to, "new@example.com");
});

Deno.test("plan: notifications skipped, header injection in address rejected", () => {
  assert(planMails({ user: { id: "u", email: "a@example.com" }, email_data: data({ email_action_type: "password_changed_notification" }) }).skip);
  assertThrows(() => planMails({ user: { id: "u", email: "a@example.com\r\nBcc: x@y.z" }, email_data: data({}) }));
});

Deno.test("redirect only into the app scheme", () => {
  assertEquals(safeRedirect("leadgenerator://auth/callback", "site", "leadgenerator://"), "leadgenerator://auth/callback");
  assertEquals(safeRedirect("https://evil.example", "site", "leadgenerator://"), "site");
});

Deno.test("client ip: trusted header first, last hop of x-forwarded-for", () => {
  assertEquals(clientIp(new Headers({ "cf-connecting-ip": "1.2.3.4", "x-forwarded-for": "6.6.6.6" })), "1.2.3.4");
  assertEquals(clientIp(new Headers({ "x-forwarded-for": "6.6.6.6, 5.5.5.5" })), "5.5.5.5");
  assertEquals(clientIp(new Headers({ "x-forwarded-for": "<script>" })), null);
  assertEquals(clientIp(new Headers()), null);
});

Deno.test("templates: escape html, contain code and link", () => {
  const r = render({ kind: "signup", code: "123456", link: verifyLink("https://x.supabase.co", "tok", "signup", "leadgenerator://auth/callback"),
    email: "<b>@example.com", minutesValid: 60 });
  assert(r.text.includes("123456") && r.html.includes("123456"));
  assert(r.html.includes("&lt;b&gt;") && !r.html.includes("<b>@"));
  assert(r.text.includes("https://x.supabase.co/auth/v1/verify?token=tok&type=signup"));
  for (const kind of ["recovery", "email_change_current", "email_change_new"] as const) {
    assert(render({ kind, code: "1", link: "l", email: "a@b.cc", minutesValid: 5 }).subject.startsWith("Lead Generator"));
  }
});

Deno.test("smtp message: utf-8 subject, base64 body, no header injection", () => {
  const m = buildMessage({ from: "Lead Generator <no-reply@x.ru>" }, { to: "a@b.ru", subject: "Привет", text: "текст", html: "<p>x</p>" });
  assert(m.includes("Subject: =?UTF-8?B?"));
  assert(m.includes("Content-Transfer-Encoding: base64"));
  assertThrows(() => buildMessage({ from: "x@y.z" }, { to: "a@b.ru\r\nBcc: c@d.ru", subject: "s", text: "", html: "" }), SmtpError);
});

Deno.test("limit messages are human readable", () => {
  assert(limitMessage({ allowed: false, reason: "cooldown", retry_after: 600 }).includes("10 мин"));
  assert(limitMessage({ allowed: false, reason: "global_daily", retry_after: 7200 }).includes("2 ч"));
});
