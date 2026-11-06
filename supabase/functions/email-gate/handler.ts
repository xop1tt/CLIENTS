// email-gate: приложение спрашивает разрешение перед каждым запросом письма
// (регистрация, повторное подтверждение, восстановление пароля, смена адреса).
//
// Функция проверяет лимиты устройства, IP, адреса и общий суточный лимит, и при успехе
// выдаёт одноразовый талон. Send Email Hook отправит письмо, только если талон есть.
// Ответ не зависит от того, существует ли аккаунт с таким адресом.

import { json } from "../_shared/http.ts";
import { rpc } from "../_shared/db.ts";
import { clientIp, DEFAULT_IP_HEADERS } from "../_shared/ip.ts";
import { limitMessage, type Verdict } from "../_shared/messages.ts";

const ACTIONS = new Set(["signup", "recovery", "email_change"]);

export async function handler(req: Request): Promise<Response> {
  if (req.method !== "POST") return json({ allowed: false, reason: "method_not_allowed" }, 405);
  let body: { action?: unknown; email?: unknown; device_id?: unknown };
  try {
    body = await req.json();
  } catch {
    return json({ allowed: false, reason: "bad_request", message: "Некорректный запрос." }, 400);
  }
  const action = typeof body.action === "string" ? body.action : "";
  const email = typeof body.email === "string" ? body.email.trim().toLowerCase() : "";
  const device = typeof body.device_id === "string" ? body.device_id.slice(0, 100) : "";
  if (!ACTIONS.has(action)) return json({ allowed: false, reason: "bad_request", message: "Неизвестная операция." }, 400);

  const ip = clientIp(req.headers, Deno.env.get("CLIENT_IP_HEADERS") || DEFAULT_IP_HEADERS);
  let v: Verdict;
  try {
    v = await rpc<Verdict>("email_gate_request", { p_action: action, p_email: email, p_device: device, p_ip: ip });
  } catch (e) {
    console.error("email-gate: rpc failed:", (e as Error).message);
    return json({ allowed: false, reason: "unavailable", message: "Сервер временно недоступен. Попробуйте позже." }, 503);
  }
  if (!v.allowed) {
    console.log(`email-gate: denied action=${action} reason=${v.reason} ip_known=${ip !== null}`);
    const status = v.reason === "invalid_email" ? 400 : 429;
    return json({ allowed: false, reason: v.reason, retry_after: v.retry_after ?? null, message: limitMessage(v) }, status);
  }
  return json({ allowed: true });
}
