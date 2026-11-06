// Проверка подписи Standard Webhooks (https://www.standardwebhooks.com), которой Supabase Auth
// подписывает вызовы HTTP-хуков. Без зависимостей: только WebCrypto.

const encoder = new TextEncoder();

function b64decode(s: string): Uint8Array<ArrayBuffer> {
  const bin = atob(s);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

function b64encode(bytes: Uint8Array): string {
  let bin = "";
  for (const b of bytes) bin += String.fromCharCode(b);
  return btoa(bin);
}

function timingSafeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

/** Секрет хука в формате Supabase: "v1,whsec_<base64>". Несколько секретов — через "|". */
export function parseSecrets(raw: string): Uint8Array<ArrayBuffer>[] {
  return raw.split("|").map((s) => s.trim()).filter(Boolean).map((s) => {
    const v = s.replace(/^v1,/, "").replace(/^whsec_/, "");
    return b64decode(v);
  });
}

export async function sign(secret: Uint8Array<ArrayBuffer>, id: string, timestamp: string, body: string): Promise<string> {
  const key = await crypto.subtle.importKey("raw", secret, { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const mac = await crypto.subtle.sign("HMAC", key, encoder.encode(`${id}.${timestamp}.${body}`));
  return b64encode(new Uint8Array(mac));
}

export class WebhookError extends Error {}

/**
 * Проверяет заголовки webhook-id, webhook-timestamp, webhook-signature.
 * Отклоняет подписи старше или новее `toleranceSec` секунд (защита от повторного воспроизведения).
 */
export async function verifyWebhook(
  headers: Headers,
  body: string,
  secrets: Uint8Array<ArrayBuffer>[],
  nowSec = Math.floor(Date.now() / 1000),
  toleranceSec = 300,
): Promise<{ id: string; timestamp: number }> {
  const id = headers.get("webhook-id");
  const ts = headers.get("webhook-timestamp");
  const sigHeader = headers.get("webhook-signature");
  if (!id || !ts || !sigHeader) throw new WebhookError("missing webhook headers");
  const timestamp = Number(ts);
  if (!Number.isInteger(timestamp)) throw new WebhookError("bad timestamp");
  if (Math.abs(nowSec - timestamp) > toleranceSec) throw new WebhookError("timestamp out of tolerance");
  const provided = sigHeader.split(" ").map((p) => p.trim()).filter((p) => p.startsWith("v1,")).map((p) => p.slice(3));
  for (const secret of secrets) {
    const expected = await sign(secret, id, ts, body);
    if (provided.some((p) => timingSafeEqual(p, expected))) return { id, timestamp };
  }
  throw new WebhookError("signature mismatch");
}
