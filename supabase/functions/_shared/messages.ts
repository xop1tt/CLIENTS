// Понятные сообщения о лимитах. Код причины (reason) клиент тоже получает и может показать своё.

export type Verdict = { allowed: boolean; reason?: string | null; retry_after?: number | null; duplicate?: boolean };

export function waitText(seconds: number | null | undefined): string {
  if (!seconds || seconds <= 0) return "";
  if (seconds < 60) return ` Повторите через ${seconds} с.`;
  const min = Math.ceil(seconds / 60);
  if (min < 120) return ` Повторите через ${min} мин.`;
  return ` Повторите через ${Math.ceil(min / 60)} ч.`;
}

export function limitMessage(v: Verdict): string {
  const wait = waitText(v.retry_after);
  switch (v.reason) {
    case "invalid_email": return "Проверьте адрес электронной почты.";
    case "cooldown": return "Письмо уже отправлено, проверьте почту и папку «Спам»." + wait;
    case "email_daily": return "На этот адрес сегодня отправлено максимум писем." + wait;
    case "device_hourly": case "device_daily": return "С этого устройства запрошено слишком много писем." + wait;
    case "ip_hourly": case "ip_daily": return "Из вашей сети запрошено слишком много писем." + wait;
    case "global_daily": return "Сегодня приложение уже отправило максимум писем. Отправка снова станет доступна после обновления суточного лимита." + wait;
    case "no_ticket": return "Письмо можно запросить только из приложения Lead Generator.";
    case "action_disabled": return "Эта операция с письмом отключена.";
    case "in_progress": return "Письмо уже отправляется, подождите несколько секунд.";
    default: return "Не удалось отправить письмо. Попробуйте позже.";
  }
}
