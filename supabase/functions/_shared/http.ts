// Общие ответы функций. Все ответы — JSON (этого требует Supabase Auth для HTTP-хуков).

export function json(body: unknown, status = 200, headers: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json; charset=utf-8", "cache-control": "no-store", ...headers },
  });
}

/** Ошибка в формате, который Supabase Auth передаёт клиенту: {error: {http_code, message}}. */
export function hookError(httpCode: number, message: string, status = httpCode): Response {
  return json({ error: { http_code: httpCode, message } }, status);
}

export function env(name: string, fallback?: string): string {
  const v = Deno.env.get(name);
  if (v === undefined || v === "") {
    if (fallback !== undefined) return fallback;
    throw new Error(`environment variable ${name} is not set`);
  }
  return v;
}
