// Вызов SQL-функций через PostgREST с ключом service_role. Ключ доступен только серверной
// функции (переменная окружения Supabase), в приложение он не попадает.

import { env } from "./http.ts";

function serviceKey(): string {
  return Deno.env.get("LEADGEN_SERVICE_ROLE_KEY") || env("SUPABASE_SERVICE_ROLE_KEY");
}

export function supabaseUrl(): string {
  return (Deno.env.get("LEADGEN_INTERNAL_URL") || env("SUPABASE_URL")).replace(/\/$/, "");
}

export async function rpc<T>(name: string, args: Record<string, unknown>): Promise<T> {
  const key = serviceKey();
  const res = await fetch(`${supabaseUrl()}/rest/v1/rpc/${name}`, {
    method: "POST",
    headers: { "content-type": "application/json", apikey: key, authorization: `Bearer ${key}` },
    body: JSON.stringify(args),
  });
  const text = await res.text();
  if (!res.ok) throw new Error(`rpc ${name} failed: HTTP ${res.status} ${text.slice(0, 300)}`);
  return (text ? JSON.parse(text) : null) as T;
}

export async function authAdmin(path: string, init: RequestInit = {}): Promise<Response> {
  const key = serviceKey();
  return await fetch(`${supabaseUrl()}/auth/v1${path}`, {
    ...init,
    headers: { "content-type": "application/json", apikey: key, authorization: `Bearer ${key}`, ...(init.headers ?? {}) },
  });
}
