// Какие письма отправить по событию Send Email Hook. Чистая функция — покрыта тестами.

import type { Kind } from "./templates.ts";

export type HookPayload = {
  user: { id: string; email?: string; new_email?: string };
  email_data: {
    token: string;
    token_hash: string;
    redirect_to: string;
    email_action_type: string;
    site_url: string;
    token_new: string;
    token_hash_new: string;
  };
};

export type PlannedMail = { to: string; kind: Kind; code: string; tokenHash: string; verifyType: string };

export type Plan =
  | { skip: true; reason: string }
  | { skip: false; action: string; owner: string; mails: PlannedMail[] };

const EMAIL_RX = /^[^@\s<>()",;:\r\n]+@[^@\s<>()",;:\r\n]+\.[^@\s<>()",;:.\r\n]{2,}$/;

export function validRecipient(s: string | undefined): s is string {
  return !!s && s.length <= 254 && EMAIL_RX.test(s);
}

export function planMails(p: HookPayload): Plan {
  const action = p?.email_data?.email_action_type ?? "";
  const d = p.email_data;
  const email = p.user?.email ?? "";
  // Уведомления (пароль изменён и т. п.) не обязательны: не тратим на них почтовую квоту.
  if (action.endsWith("_notification")) return { skip: true, reason: "notification" };
  if (!validRecipient(email) && action !== "email_change") throw new Error("payload has no valid user email");

  switch (action) {
    case "signup":
    case "recovery":
      return { skip: false, action, owner: email, mails: [{ to: email, kind: action, code: d.token, tokenHash: d.token_hash, verifyType: action }] };
    case "email_change": {
      const newEmail = p.user?.new_email ?? "";
      if (!validRecipient(newEmail)) throw new Error("email_change without valid new_email");
      // Поля названы наоборот по историческим причинам (см. документацию Supabase):
      // текущий адрес — token + token_hash_new, новый адрес — token_new + token_hash.
      if (d.token_hash_new && d.token_new && validRecipient(email)) {
        return {
          skip: false, action, owner: email, mails: [
            { to: email, kind: "email_change_current", code: d.token, tokenHash: d.token_hash_new, verifyType: "email_change" },
            { to: newEmail, kind: "email_change_new", code: d.token_new, tokenHash: d.token_hash, verifyType: "email_change" },
          ],
        };
      }
      return {
        skip: false, action, owner: validRecipient(email) ? email : newEmail, mails: [
          { to: newEmail, kind: "email_change_new", code: d.token || d.token_new, tokenHash: d.token_hash, verifyType: "email_change" },
        ],
      };
    }
    default:
      // magiclink, invite, email, reauthentication: приложение их не использует.
      // Квоту проверит база (по умолчанию эти операции выключены в email_limits).
      return { skip: false, action, owner: email, mails: [{ to: email, kind: "other", code: d.token, tokenHash: d.token_hash, verifyType: action }] };
  }
}

/** Куда вернуть пользователя после ссылки: только наша схема приложения, иначе site_url. */
export function safeRedirect(redirectTo: string, siteUrl: string, allowedPrefix: string): string {
  if (redirectTo && redirectTo.startsWith(allowedPrefix)) return redirectTo;
  return siteUrl;
}
