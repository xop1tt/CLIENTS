// Send Email Hook: Supabase Auth вызывает эту функцию вместо собственной отправки писем.
//
// 1. Проверяет подпись вызова (Standard Webhooks, секрет SEND_EMAIL_HOOK_SECRET).
// 2. Атомарно резервирует квоту в базе (email_hook_reserve): общий суточный лимит, лимиты
//    адреса, интервалы, талон от email-gate. Повтор того же вызова квоту второй раз не тратит.
// 3. Отправляет письма через SMTP и отмечает в базе, какие ушли. Неотправленные не считаются.

import { env, hookError, json } from "../_shared/http.ts";
import { rpc, supabaseUrl } from "../_shared/db.ts";
import { limitMessage, type Verdict } from "../_shared/messages.ts";
import { type HookPayload, planMails, safeRedirect } from "../_shared/plan.ts";
import { type Mail, sendMail, smtpConfigFromEnv } from "../_shared/smtp.ts";
import { render, verifyLink } from "../_shared/templates.ts";
import { parseSecrets, verifyWebhook, WebhookError } from "../_shared/webhook.ts";

export async function handler(req: Request): Promise<Response> {
  if (req.method !== "POST") return hookError(405, "method not allowed");
  const body = await req.text();
  let webhookId: string;
  try {
    ({ id: webhookId } = await verifyWebhook(req.headers, body, parseSecrets(env("SEND_EMAIL_HOOK_SECRET"))));
  } catch (e) {
    console.warn("send-email: rejected unsigned call:", e instanceof WebhookError ? e.message : "error");
    return hookError(401, "invalid signature");
  }

  let plan;
  try {
    plan = planMails(JSON.parse(body) as HookPayload);
  } catch (e) {
    console.error("send-email: bad payload:", (e as Error).message);
    return hookError(400, "bad payload");
  }
  if (plan.skip) return json({});

  // Ошибки лимитов возвращаются без заголовка retry-after: Auth не повторяет вызов.
  let verdict: Verdict;
  try {
    verdict = await rpc<Verdict>("email_hook_reserve", {
      p_webhook_id: webhookId,
      p_action: plan.action,
      p_owner_email: plan.owner,
      p_recipients: plan.mails.map((m) => m.to),
    });
  } catch (e) {
    console.error("send-email: quota check failed:", (e as Error).message);
    return hookError(503, "Почтовый сервис временно недоступен. Попробуйте позже.", 500);
  }
  if (!verdict.allowed) {
    console.log(`send-email: denied action=${plan.action} reason=${verdict.reason}`);
    return hookError(429, limitMessage(verdict));
  }
  if (verdict.duplicate) return json({});

  const payload = JSON.parse(body) as HookPayload;
  const base = Deno.env.get("LEADGEN_PUBLIC_URL") || supabaseUrl();
  const redirect = safeRedirect(payload.email_data.redirect_to, payload.email_data.site_url,
    Deno.env.get("APP_REDIRECT_PREFIX") || "leadgenerator://");
  const minutes = Math.round(Number(Deno.env.get("OTP_EXPIRY_SECONDS") || 3600) / 60);
  const mails: Mail[] = plan.mails.map((m) => {
    const r = render({
      kind: m.kind, code: m.code, email: m.to, newEmail: payload.user.new_email, minutesValid: minutes,
      link: verifyLink(base, m.tokenHash, m.verifyType, redirect),
    });
    return { to: m.to, ...r };
  });

  // Заполняется по мере приёма писем сервером: при ошибке на втором письме (смена адреса)
  // первое учитывается как отправленное.
  const sent: string[] = [];
  let error: string | null = null;
  try {
    await sendMail(smtpConfigFromEnv(), mails, sent);
  } catch (e) {
    error = (e as Error).message;
  }
  const failed = mails.map((m) => m.to).filter((t) => !sent.includes(t));
  try {
    await rpc("email_hook_finish", { p_webhook_id: webhookId, p_sent: sent, p_failed: failed, p_error: error });
  } catch (e) {
    console.error("send-email: could not record result:", (e as Error).message);
  }
  if (failed.length > 0) {
    console.error(`send-email: smtp failed action=${plan.action} sent=${sent.length} failed=${failed.length}: ${error}`);
    return hookError(503, "Почтовый сервис временно недоступен, письмо не отправлено. Попробуйте позже.", 500);
  }
  console.log(`send-email: sent action=${plan.action} count=${sent.length}`);
  return json({});
}
