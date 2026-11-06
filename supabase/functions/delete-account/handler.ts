// delete-account: удаление учётной записи и всех её данных в облаке.
//
// Клиент передаёт свой JWT. Функция проверяет его через Supabase Auth (сессия должна быть
// действующей) и требует, чтобы пароль был введён не раньше 10 минут назад (claim amr).
// Удаление пользователя каскадно удаляет его лиды, исключения и настройки (on delete cascade).
// Ключ service_role есть только у функции.

import { json } from "../_shared/http.ts";
import { authAdmin } from "../_shared/db.ts";

const MAX_AUTH_AGE_SEC = 600;

export function decodeJwtPayload(token: string): Record<string, unknown> | null {
  const part = token.split(".")[1];
  if (!part) return null;
  try {
    const b64 = part.replace(/-/g, "+").replace(/_/g, "/").padEnd(Math.ceil(part.length / 4) * 4, "=");
    return JSON.parse(new TextDecoder().decode(Uint8Array.from(atob(b64), (c) => c.charCodeAt(0))));
  } catch {
    return null;
  }
}

/** Время последнего входа по паролю из claim amr, в секундах. */
export function passwordAuthTime(claims: Record<string, unknown>): number | null {
  const amr = claims.amr;
  if (!Array.isArray(amr)) return null;
  const times = amr
    .filter((e) => e && typeof e === "object" && (e as { method?: string }).method === "password")
    .map((e) => Number((e as { timestamp?: number }).timestamp))
    .filter((t) => Number.isFinite(t));
  return times.length ? Math.max(...times) : null;
}

export async function handler(req: Request): Promise<Response> {
  if (req.method !== "POST") return json({ ok: false, reason: "method_not_allowed" }, 405);
  const token = (req.headers.get("authorization") ?? "").replace(/^Bearer\s+/i, "");
  if (!token) return json({ ok: false, reason: "unauthorized", message: "Войдите в учётную запись." }, 401);

  // Проверка подписи, срока и отзыва сессии — на стороне Supabase Auth.
  const me = await authAdmin("/user", { headers: { authorization: `Bearer ${token}` } });
  if (!me.ok) return json({ ok: false, reason: "unauthorized", message: "Сессия недействительна, войдите снова." }, 401);
  const user = await me.json() as { id?: string };
  const claims = decodeJwtPayload(token);
  if (!user.id || !claims || claims.sub !== user.id) {
    return json({ ok: false, reason: "unauthorized", message: "Сессия недействительна, войдите снова." }, 401);
  }
  const at = passwordAuthTime(claims);
  if (at === null || Date.now() / 1000 - at > MAX_AUTH_AGE_SEC) {
    return json({ ok: false, reason: "reauth_required", message: "Для удаления учётной записи введите пароль ещё раз." }, 403);
  }

  const del = await authAdmin(`/admin/users/${encodeURIComponent(user.id)}`, { method: "DELETE" });
  if (!del.ok) {
    console.error(`delete-account: admin delete failed: HTTP ${del.status}`);
    return json({ ok: false, reason: "unavailable", message: "Не удалось удалить учётную запись. Попробуйте позже." }, 502);
  }
  console.log("delete-account: user deleted");
  return json({ ok: true });
}
