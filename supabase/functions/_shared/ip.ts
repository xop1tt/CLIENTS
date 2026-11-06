// IP клиента. Заголовки, которые выставляет инфраструктура (Cloudflare перед Supabase),
// клиент подменить не может; X-Forwarded-For может прийти и от клиента, поэтому из него
// берётся последний адрес — тот, что добавил ближайший доверенный прокси.
// Порядок заголовков настраивается переменной CLIENT_IP_HEADERS.

export const DEFAULT_IP_HEADERS = "cf-connecting-ip,x-real-ip,x-forwarded-for";

export function clientIp(headers: Headers, order = DEFAULT_IP_HEADERS): string | null {
  for (const name of order.split(",").map((s) => s.trim().toLowerCase()).filter(Boolean)) {
    const raw = headers.get(name);
    if (!raw) continue;
    const parts = raw.split(",").map((s) => s.trim()).filter(Boolean);
    const ip = name === "x-forwarded-for" ? parts[parts.length - 1] : parts[0];
    if (ip && /^[0-9a-fA-F:.]{3,45}$/.test(ip)) return ip;
  }
  return null;
}
