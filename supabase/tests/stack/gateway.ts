// Локальный аналог API-шлюза Supabase для тестового стенда (только для тестов!).
//   /auth/v1/*        → Supabase Auth (GoTrue)
//   /rest/v1/*        → PostgREST
//   /functions/v1/:fn → обработчики из supabase/functions/:fn/handler.ts
// Как и в облаке, требует заголовок apikey. IP клиента передаёт функциям в cf-connecting-ip;
// тесты могут подставить другой адрес заголовком x-test-client-ip, чтобы проверить лимиты IP.

import { handler as sendEmail } from "../../functions/send-email/handler.ts";
import { handler as emailGate } from "../../functions/email-gate/handler.ts";
import { handler as deleteAccount } from "../../functions/delete-account/handler.ts";

const AUTH = Deno.env.get("STACK_AUTH_URL") ?? "http://127.0.0.1:9999";
const REST = Deno.env.get("STACK_REST_URL") ?? "http://127.0.0.1:54330";
const KEYS = new Set([Deno.env.get("SUPABASE_ANON_KEY"), Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")]);
const PORT = Number(Deno.env.get("STACK_PORT") ?? 54321);

const functions: Record<string, (r: Request) => Promise<Response>> = {
  "send-email": sendEmail,
  "email-gate": emailGate,
  "delete-account": deleteAccount,
};

async function proxy(req: Request, target: string, ip: string): Promise<Response> {
  const headers = new Headers(req.headers);
  headers.delete("host");
  headers.set("x-forwarded-for", ip);
  const res = await fetch(target, {
    method: req.method,
    headers,
    body: ["GET", "HEAD"].includes(req.method) ? undefined : await req.arrayBuffer(),
    redirect: "manual",
  });
  return new Response(res.body, { status: res.status, headers: res.headers });
}

Deno.serve({ port: PORT, hostname: "127.0.0.1" }, async (req, info) => {
  const url = new URL(req.url);
  const peer = (info.remoteAddr as Deno.NetAddr).hostname;
  const ip = req.headers.get("x-test-client-ip") ?? peer;

  const fn = url.pathname.match(/^\/functions\/v1\/([a-z-]+)$/);
  if (fn) {
    const h = functions[fn[1]];
    if (!h) return new Response("not found", { status: 404 });
    // Хук Auth вызывает функцию без apikey, как и в облаке (verify_jwt = false).
    const headers = new Headers(req.headers);
    headers.set("cf-connecting-ip", ip);
    headers.delete("x-test-client-ip");
    return await h(new Request(req.url, { method: req.method, headers, body: req.body }));
  }

  // Ссылки из писем открываются в браузере без apikey, как и в облаке.
  const isVerifyLink = url.pathname === "/auth/v1/verify" && req.method === "GET";
  if (!isVerifyLink && !KEYS.has(req.headers.get("apikey") ?? "")) {
    return Response.json({ message: "Invalid API key" }, { status: 401 });
  }
  if (url.pathname.startsWith("/auth/v1/")) return await proxy(req, AUTH + url.pathname.slice(8) + url.search, ip);
  if (url.pathname.startsWith("/rest/v1/")) return await proxy(req, REST + url.pathname.slice(8) + url.search, ip);
  return new Response("not found", { status: 404 });
});
