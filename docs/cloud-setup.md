# Как включить облако Lead Generator: пошаговая инструкция

Инструкция для человека без опыта программирования. Займёт около часа. Всё бесплатно: платные
тарифы, домены и подписки не нужны. Технические подробности — в [cloud.md](cloud.md).

Пока облако не настроено, приложение работает как раньше, с локальными учётными записями.

> **Важно.** Облако Lead Generator — это **новый, отдельный проект** Supabase. Не открывайте и не
> меняйте другие свои проекты (например, «Mirada»): не запускайте в них SQL, не меняйте их настройки
> входа и не берите их ключи.

> **Секретные ключи** (Service Role / `sb_secret_…`, пароль базы, пароль приложения Gmail) никому не
> пересылайте, в том числе в чат. Они вводятся только в панели Supabase и в настройках GitHub.

Что понадобится:

- аккаунт на [supabase.com](https://supabase.com) (бесплатный);
- адрес Gmail, с которого будут уходить письма (можно завести отдельный);
- компьютер с macOS и браузер; для шага 5 — бесплатный [Node.js](https://nodejs.org) (кнопка «LTS»);
- доступ к репозиторию на GitHub (Settings).

---

## Шаг 1. Создать отдельный проект

1. Войдите на supabase.com → **New project**.
2. Организация: можно ту же, где уже есть другой проект (на бесплатном тарифе в организации можно
   держать 2 активных проекта), или создайте новую — **New organization**, тариф **Free**.
   Если Supabase предлагает перейти на платный тариф, откажитесь и создайте новую организацию с Free.
3. Имя проекта: `lead-generator`. Пароль базы: нажмите **Generate a password** и сохраните его в
   менеджере паролей (в чат не отправляйте). Регион: ближайший (например, Central EU / Frankfurt).
4. Нажмите **Create new project** и подождите 1–2 минуты.
5. Откройте **Project Settings → General** и запишите **Project ID** (например, `abcdxyzabcdxyzabcd`).
   Дальше он называется `REF`.

## Шаг 2. Создать таблицы (миграции)

1. В левом меню **SQL Editor** → **New query**.
2. Откройте в репозитории файл `supabase/migrations/20261106120000_sync_schema.sql`, нажмите **Raw**,
   скопируйте весь текст, вставьте в редактор и нажмите **Run**. Должно появиться `Success. No rows returned`.
3. То же самое для `supabase/migrations/20261106120100_email_limits.sql`.
4. Проверка: новый запрос `select public.email_quota_status();` → **Run**. Должна вернуться строка вида
   `{"sent": 0, "global_daily_max": 50, …}`. Если ошибка «function does not exist» — повторите пункты 2–3.

Запускайте эти файлы **только в проекте lead-generator** (название проекта видно вверху страницы).

## Шаг 3. Подготовить почту Gmail

1. В аккаунте Google включите двухэтапную аутентификацию: [myaccount.google.com/security](https://myaccount.google.com/security).
2. Откройте [myaccount.google.com/apppasswords](https://myaccount.google.com/apppasswords), имя — `Lead Generator`,
   нажмите **Create**. Появится пароль из 16 букв — это **пароль приложения**. Сохраните его в менеджере паролей.

Gmail бесплатно отправляет около 500 писем в сутки; приложение само ограничивает отправку 50 письмами.

## Шаг 4. Секреты для функций

1. В Supabase: **Edge Functions → Secrets** (или **Project Settings → Edge Functions**).
2. Добавьте по одному (Name → Value), затем **Save**:

| Name | Value |
|---|---|
| `SMTP_HOST` | `smtp.gmail.com` |
| `SMTP_PORT` | `465` |
| `SMTP_MODE` | `tls` |
| `SMTP_USER` | ваш адрес Gmail |
| `SMTP_PASS` | пароль приложения из шага 3 (без пробелов) |
| `SMTP_FROM` | `Lead Generator <ваш адрес Gmail>` |

`SEND_EMAIL_HOOK_SECRET` добавите на шаге 6. `SUPABASE_URL` и `SUPABASE_SERVICE_ROLE_KEY` Supabase
передаёт функциям сам — их добавлять не нужно.

## Шаг 5. Загрузить функции

1. Установите Node.js (LTS) с [nodejs.org](https://nodejs.org).
2. Скачайте репозиторий: на GitHub **Code → Download ZIP**, распакуйте.
3. Откройте **Терминал** (Программы → Утилиты), введите `cd ` (с пробелом), перетащите в окно
   распакованную папку и нажмите Enter.
4. Выполните по очереди (вместо `REF` — ваш Project ID):

```bash
npx supabase login
npx supabase functions deploy send-email --project-ref REF --no-verify-jwt
npx supabase functions deploy email-gate --project-ref REF --no-verify-jwt
npx supabase functions deploy delete-account --project-ref REF --no-verify-jwt
```

`login` откроет браузер — подтвердите вход. После каждой команды должно быть `Deployed Functions … send-email`
(и т. д.). В панели Supabase в **Edge Functions** появятся три функции.

## Шаг 6. Настроить вход по почте

**Authentication → Sign In / Providers → Email:**

- **Enable Email provider** — включено;
- **Confirm email** — включено;
- **Secure email change** — включено;
- **Email OTP Expiration** — `3600`; **Email OTP Length** — `6`;
- **Minimum password length** — `8`; **Password Requirements** — «Lowercase, uppercase letters and digits»;
- **Save**.

**Authentication → URL Configuration:**

- **Site URL**: `leadgenerator://auth/callback`;
- **Redirect URLs** → **Add URL**: `leadgenerator://auth/**` → **Save**.

**Authentication → Hooks → Add hook → Send Email hook:**

- тип **HTTPS**;
- URL: `https://REF.supabase.co/functions/v1/send-email`;
- нажмите **Generate secret**, скопируйте секрет (начинается с `v1,whsec_`);
- **Create** (включите хук, если есть переключатель).

Вернитесь в **Edge Functions → Secrets** и добавьте `SEND_EMAIL_HOOK_SECRET` = скопированный секрет целиком.

Свой SMTP в **Authentication → Emails → SMTP Settings** настраивать **не нужно**: письма отправляет функция.

## Шаг 7. Ключи для приложения

1. **Project Settings → API Keys**. Нужен **публичный** ключ: `Publishable key` (`sb_publishable_…`)
   или на вкладке Legacy — `anon public`. Ключ `service_role` / `Secret key` **не берите**.
2. Адрес проекта: `https://REF.supabase.co`.
3. На GitHub: репозиторий → **Settings → Secrets and variables → Actions → вкладка Variables →
   New repository variable**:
   - `SUPABASE_URL` = `https://REF.supabase.co`;
   - `SUPABASE_ANON_KEY` = публичный ключ.

   Это переменные, а не секреты: публичный ключ можно хранить открыто, он защищён правилами доступа (RLS).
4. Следующая сборка приложения (Actions → macOS app или релиз) уже будет с облаком.

## Шаг 8. Проверить

1. Установите новую сборку, откройте приложение → **Создать учётную запись** → почта и пароль.
2. Придёт письмо «Подтвердите адрес» с кодом. Введите код — откроется рабочее окно, внизу боковой
   панели — «Облако подключено» или «Синхронизировано …».
3. В Supabase **Authentication → Users** появится пользователь, в **Table Editor → leads** после поиска — его лиды.
4. Письмо не пришло: проверьте «Спам»; **Edge Functions → send-email → Logs**. Частые причины —
   опечатка в `SMTP_PASS` или `SEND_EMAIL_HOOK_SECRET`.

## Шаг 9. Проверить лимит по IP (один раз)

Запросите письмо (например, «Забыли пароль?») сначала через домашний Wi-Fi, потом через мобильный
интернет. В **SQL Editor** выполните:

```sql
select ip_hash, count(*) from private.email_requests group by ip_hash;
```

Должно быть **две разные** строки. Если строка одна, лимит по IP считает всех одним клиентом:
добавьте секрет `CLIENT_IP_HEADERS` = `x-forwarded-for` и проверьте снова.

## Шаг 10. Как менять лимиты

**SQL Editor** (проект lead-generator):

```sql
update private.email_limits set global_daily_max = 50;      -- писем в сутки на всё приложение
update private.email_limits set per_email_daily_max = 5;     -- на один адрес
select public.email_quota_status();                          -- сколько уже отправлено сегодня
```

Новая сборка приложения для этого не нужна.

## Шаг 11. Резервная копия облака (раз в месяц)

На бесплатном тарифе автоматических копий нет, но у каждого пользователя полная копия на его Mac
(и резервные копии в «Документы → Lead Generator Backups»). Дополнительно:

- **просто:** **Table Editor** → таблица `leads` (затем `exclusions`, `user_settings`) → **Export → CSV**;
- **полностью:** нужен бесплатный Docker Desktop. **Project Settings → Database → Connection string**
  (URI, режим Session), затем в Терминале:

```bash
npx supabase db dump --db-url "СТРОКА_ПОДКЛЮЧЕНИЯ" --data-only -f lead-generator-backup.sql
```

## Если проект «уснул»

Бесплатный проект засыпает после 7 дней без запросов. Приложение продолжает работать с данными на
Mac и пишет «Нет связи». Откройте проект в Supabase и нажмите **Restore project** — данные сохранятся,
синхронизация продолжится сама.

## Что не делать

- Не включайте платные дополнения (Compute, PITR, Custom domain) и не меняйте тариф.
- Не вставляйте ключ `service_role` / `Secret key` в GitHub-переменные, приложение и чат.
- Не запускайте SQL из этой инструкции в другом проекте.
