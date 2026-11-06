// Шаблоны писем: подтверждение регистрации, восстановление пароля, смена адреса.
// В каждом письме — код для ввода в приложении и ссылка подтверждения.
// Код работает всегда; ссылка открывает страницу Supabase, которая проверяет её и
// возвращает пользователя в приложение (leadgenerator://auth/callback).

export const APP_NAME = "Lead Generator";

export type Kind = "signup" | "recovery" | "email_change_current" | "email_change_new" | "other";

export type TemplateInput = {
  kind: Kind;
  code: string;
  link: string;
  email: string;
  newEmail?: string;
  minutesValid: number;
};

function esc(s: string): string {
  return s.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]!));
}

type Copy = { subject: string; title: string; lead: string; button: string; ignore: string };

function copy(i: TemplateInput): Copy {
  switch (i.kind) {
    case "signup":
      return {
        subject: `${APP_NAME}: подтвердите адрес почты`,
        title: "Подтвердите адрес почты",
        lead: `Вы создаёте учётную запись ${APP_NAME} для адреса ${i.email}. Введите код в приложении или нажмите кнопку.`,
        button: "Подтвердить адрес",
        ignore: "Если вы не регистрировались, просто удалите это письмо: без подтверждения учётная запись не заработает.",
      };
    case "recovery":
      return {
        subject: `${APP_NAME}: восстановление пароля`,
        title: "Восстановление пароля",
        lead: `Кто-то (возможно, вы) запросил смену пароля для ${i.email}. Введите код в приложении или нажмите кнопку, затем задайте новый пароль.`,
        button: "Задать новый пароль",
        ignore: "Если вы не запрашивали восстановление, ничего не делайте: пароль останется прежним.",
      };
    case "email_change_current":
      return {
        subject: `${APP_NAME}: подтвердите смену адреса почты`,
        title: "Смена адреса почты",
        lead: `Для учётной записи ${i.email} запрошена смена адреса на ${i.newEmail ?? "новый"}. Подтвердите, что это вы: введите код в приложении или нажмите кнопку.`,
        button: "Подтвердить смену адреса",
        ignore: "Если это были не вы, не подтверждайте смену и смените пароль в приложении: «Настройки → Учётная запись».",
      };
    case "email_change_new":
      return {
        subject: `${APP_NAME}: подтвердите новый адрес почты`,
        title: "Подтвердите новый адрес",
        lead: `Этот адрес (${i.email}) указан как новый для учётной записи ${APP_NAME}. Введите код в приложении или нажмите кнопку.`,
        button: "Подтвердить новый адрес",
        ignore: "Если вы не меняли адрес, просто удалите это письмо.",
      };
    default:
      return {
        subject: `${APP_NAME}: код подтверждения`,
        title: "Код подтверждения",
        lead: `Код для ${i.email}.`,
        button: "Подтвердить",
        ignore: "Если вы ничего не запрашивали, удалите это письмо.",
      };
  }
}

export function render(i: TemplateInput): { subject: string; text: string; html: string } {
  const c = copy(i);
  const valid = `Код и ссылка действуют ${i.minutesValid} мин и срабатывают один раз.`;
  const text = [
    c.title,
    "",
    c.lead,
    "",
    `Код: ${i.code}`,
    "",
    `Ссылка: ${i.link}`,
    "",
    valid,
    c.ignore,
    "",
    `— ${APP_NAME}. Письмо отправлено автоматически, отвечать на него не нужно.`,
  ].join("\n");
  const html = `<!doctype html><html lang="ru"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width">
<title>${esc(c.subject)}</title></head>
<body style="margin:0;padding:24px;background:#f5f5f7;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;color:#1d1d1f">
<table role="presentation" width="100%" cellspacing="0" cellpadding="0"><tr><td align="center">
<table role="presentation" width="100%" cellspacing="0" cellpadding="0" style="max-width:520px;background:#ffffff;border-radius:14px;padding:32px">
<tr><td style="font-size:13px;color:#6e6e73;font-weight:600;letter-spacing:.02em">${esc(APP_NAME)}</td></tr>
<tr><td style="padding-top:8px;font-size:22px;font-weight:700">${esc(c.title)}</td></tr>
<tr><td style="padding-top:12px;font-size:15px;line-height:1.5">${esc(c.lead)}</td></tr>
<tr><td style="padding-top:20px"><div style="font-size:30px;font-weight:700;letter-spacing:.3em;font-family:ui-monospace,Menlo,monospace;background:#f5f5f7;border-radius:10px;padding:14px 18px;text-align:center">${esc(i.code)}</div></td></tr>
<tr><td style="padding-top:20px" align="center"><a href="${esc(i.link)}" style="display:inline-block;background:#29b354;color:#ffffff;text-decoration:none;font-weight:600;font-size:15px;padding:12px 22px;border-radius:22px">${esc(c.button)}</a></td></tr>
<tr><td style="padding-top:20px;font-size:13px;line-height:1.5;color:#6e6e73">${esc(valid)}<br>${esc(c.ignore)}</td></tr>
<tr><td style="padding-top:20px;font-size:12px;color:#86868b">Письмо отправлено автоматически, отвечать на него не нужно.</td></tr>
</table></td></tr></table></body></html>`;
  return { subject: c.subject, text, html };
}

/**
 * Ссылка подтверждения через стандартный эндпоинт Supabase Auth /verify. Он проверяет токен
 * (одноразовый, со сроком действия) и перенаправляет на redirect_to из списка разрешённых.
 */
export function verifyLink(supabaseUrl: string, tokenHash: string, type: string, redirectTo: string): string {
  const u = new URL(`${supabaseUrl.replace(/\/$/, "")}/auth/v1/verify`);
  u.searchParams.set("token", tokenHash);
  u.searchParams.set("type", type);
  if (redirectTo) u.searchParams.set("redirect_to", redirectTo);
  return u.toString();
}
