// Минимальный SMTP-клиент без внешних зависимостей (Deno.connect / Deno.connectTls).
//
// В Supabase Edge Functions исходящие соединения на порты 25 и 587 закрыты, поэтому для
// облака используется SMTPS на порту 465 (mode "tls"). Режимы "starttls" и "plain" —
// для других хостингов и локального тестового стенда.

export type SmtpConfig = {
  host: string;
  port: number;
  mode: "tls" | "starttls" | "plain";
  user?: string;
  pass?: string;
  from: string; // "Lead Generator <app@example.com>"
  timeoutMs: number;
};

export type Mail = { to: string; subject: string; text: string; html: string };

export class SmtpError extends Error {}

const enc = new TextEncoder();
const dec = new TextDecoder();

function b64(s: string): string {
  const bytes = enc.encode(s);
  let bin = "";
  for (const b of bytes) bin += String.fromCharCode(b);
  return btoa(bin);
}

function wrap76(s: string): string {
  return s.replace(/.{1,76}/g, (m) => m + "\r\n").trimEnd();
}

export function addressOf(from: string): string {
  const m = from.match(/<([^>]+)>/);
  return (m ? m[1] : from).trim();
}

function encodeHeader(s: string): string {
  return /^[\x20-\x7e]*$/.test(s) ? s : `=?UTF-8?B?${b64(s)}?=`;
}

function encodeFrom(from: string): string {
  const m = from.match(/^\s*(.*?)\s*<([^>]+)>\s*$/);
  if (!m || !m[1]) return addressOf(from);
  return `${encodeHeader(m[1].replace(/^"|"$/g, ""))} <${m[2]}>`;
}

/** Письмо в формате MIME: multipart/alternative (текст + HTML), UTF-8, base64. */
export function buildMessage(cfg: Pick<SmtpConfig, "from">, mail: Mail, now = new Date()): string {
  if (/[\r\n]/.test(mail.to + mail.subject + cfg.from)) throw new SmtpError("header injection");
  const boundary = `lg-${crypto.randomUUID()}`;
  const domain = addressOf(cfg.from).split("@")[1] ?? "localhost";
  const lines = [
    `From: ${encodeFrom(cfg.from)}`,
    `To: <${mail.to}>`,
    `Subject: ${encodeHeader(mail.subject)}`,
    `Date: ${now.toUTCString().replace("GMT", "+0000")}`,
    `Message-ID: <${crypto.randomUUID()}@${domain}>`,
    "MIME-Version: 1.0",
    "Auto-Submitted: auto-generated",
    `Content-Type: multipart/alternative; boundary="${boundary}"`,
    "",
    `--${boundary}`,
    "Content-Type: text/plain; charset=utf-8",
    "Content-Transfer-Encoding: base64",
    "",
    wrap76(b64(mail.text)),
    `--${boundary}`,
    "Content-Type: text/html; charset=utf-8",
    "Content-Transfer-Encoding: base64",
    "",
    wrap76(b64(mail.html)),
    `--${boundary}--`,
    "",
  ];
  return lines.join("\r\n");
}

class Conn {
  private buf = "";
  constructor(public conn: Deno.Conn) {}

  async write(line: string) {
    await this.conn.write(enc.encode(line));
  }

  /** Читает ответ сервера (в том числе многострочный "250-..."), возвращает код и текст. */
  async read(): Promise<{ code: number; text: string }> {
    const lines: string[] = [];
    while (true) {
      let idx: number;
      while ((idx = this.buf.indexOf("\r\n")) === -1) {
        const chunk = new Uint8Array(4096);
        const n = await this.conn.read(chunk);
        if (n === null) throw new SmtpError("connection closed by server");
        this.buf += dec.decode(chunk.subarray(0, n));
      }
      const line = this.buf.slice(0, idx);
      this.buf = this.buf.slice(idx + 2);
      lines.push(line);
      if (/^\d{3} /.test(line) || /^\d{3}$/.test(line)) {
        return { code: Number(line.slice(0, 3)), text: lines.join("\n") };
      }
    }
  }

  /** `label` — что написать в ошибке вместо команды (логин и пароль в текст ошибки не попадают). */
  async cmd(line: string, expect: number[], label = line.split(" ")[0]): Promise<string> {
    await this.write(line + "\r\n");
    const r = await this.read();
    if (!expect.includes(r.code)) {
      throw new SmtpError(`${label}: ${r.code} ${r.text.slice(0, 200)}`);
    }
    return r.text;
  }
}

async function withTimeout<T>(ms: number, p: Promise<T>, onTimeout: () => void): Promise<T> {
  let t: number | undefined;
  const timer = new Promise<never>((_, reject) => {
    t = setTimeout(() => {
      onTimeout();
      reject(new SmtpError(`timeout after ${ms} ms`));
    }, ms);
  });
  try {
    return await Promise.race([p, timer]);
  } finally {
    clearTimeout(t);
  }
}

/** Отправляет письма одним соединением. Возвращает адреса, которые сервер принял. */
/** Отправляет письма по одному соединению. Принятые сервером адреса добавляются в `sent`
 *  сразу, поэтому при ошибке на втором письме вызывающий знает, что первое уже ушло. */
export async function sendMail(cfg: SmtpConfig, mails: Mail[], sent: string[] = []): Promise<string[]> {
  let raw: Deno.Conn | undefined;
  const run = async () => {
    raw = cfg.mode === "tls"
      ? await Deno.connectTls({ hostname: cfg.host, port: cfg.port })
      : await Deno.connect({ hostname: cfg.host, port: cfg.port });
    let c = new Conn(raw);
    const greet = await c.read();
    if (greet.code !== 220) throw new SmtpError(`greeting: ${greet.code}`);
    const helo = "lead-generator";
    let caps = await c.cmd(`EHLO ${helo}`, [250]);
    if (cfg.mode === "starttls") {
      await c.cmd("STARTTLS", [220]);
      raw = await Deno.startTls(raw as Deno.TcpConn, { hostname: cfg.host });
      c = new Conn(raw);
      caps = await c.cmd(`EHLO ${helo}`, [250]);
    }
    if (cfg.user) {
      if (/AUTH[^\n]*PLAIN/i.test(caps)) {
        await c.cmd(`AUTH PLAIN ${b64(`\u0000${cfg.user}\u0000${cfg.pass ?? ""}`)}`, [235], "AUTH");
      } else {
        await c.cmd("AUTH LOGIN", [334]);
        await c.cmd(b64(cfg.user), [334], "AUTH");
        await c.cmd(b64(cfg.pass ?? ""), [235], "AUTH");
      }
    }
    for (const mail of mails) {
      await c.cmd(`MAIL FROM:<${addressOf(cfg.from)}>`, [250]);
      await c.cmd(`RCPT TO:<${mail.to}>`, [250, 251]);
      await c.cmd("DATA", [354]);
      const body = buildMessage(cfg, mail).replace(/\r\n\./g, "\r\n..");
      await c.cmd(body + "\r\n.", [250], "DATA");
      sent.push(mail.to);
    }
    try {
      await c.cmd("QUIT", [221]);
    } catch { /* сервер мог закрыть соединение сам */ }
  };
  try {
    await withTimeout(cfg.timeoutMs, run(), () => {
      try { raw?.close(); } catch { /* уже закрыто */ }
    });
  } finally {
    try { raw?.close(); } catch { /* уже закрыто */ }
  }
  return sent;
}

export function smtpConfigFromEnv(get: (k: string) => string | undefined = (k) => Deno.env.get(k)): SmtpConfig {
  const host = get("SMTP_HOST");
  const from = get("SMTP_FROM") || get("SMTP_USER");
  if (!host || !from) throw new SmtpError("SMTP_HOST and SMTP_FROM must be set");
  const mode = (get("SMTP_MODE") || "tls") as SmtpConfig["mode"];
  if (!["tls", "starttls", "plain"].includes(mode)) throw new SmtpError("SMTP_MODE must be tls, starttls or plain");
  return {
    host,
    port: Number(get("SMTP_PORT") || (mode === "tls" ? 465 : 587)),
    mode,
    user: get("SMTP_USER"),
    pass: get("SMTP_PASS"),
    from,
    timeoutMs: Number(get("SMTP_TIMEOUT_MS") || 3500),
  };
}
