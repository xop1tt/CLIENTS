-- Lead Generator: жёсткие лимиты на отправку писем авторизации.
--
-- Почту отправляет не Supabase Auth, а функция send-email (Send Email Hook). Перед каждой
-- отправкой она атомарно резервирует квоту здесь, в базе, и учитывает только реально
-- отправленные письма. Запрос письма из приложения сначала проходит функцию email-gate,
-- которая проверяет лимиты устройства и IP и выдаёт одноразовый «талон» на письмо.
-- Прямой вызов публичных эндпоинтов Auth без талона письмо не отправит.
--
-- Все лимиты лежат в одной строке private.email_limits и меняются без выпуска приложения
-- (Dashboard → Table Editor → схема private → email_limits).
--
-- Адреса, идентификаторы устройств и IP хранятся только как SHA-256, записи старше 8 дней
-- удаляются автоматически.

create schema if not exists private;
revoke all on schema private from public;

create table if not exists private.email_limits (
    id smallint primary key default 1 check (id = 1),
    enabled_actions text[] not null default array['signup', 'recovery', 'email_change'],
    global_daily_max int not null default 50 check (global_daily_max >= 0),
    per_email_daily_max int not null default 5 check (per_email_daily_max >= 0),
    signup_initial_max int not null default 1 check (signup_initial_max >= 0),
    signup_resend_cooldown interval not null default interval '15 minutes',
    recovery_cooldown interval not null default interval '30 minutes',
    email_change_cooldown interval not null default interval '30 minutes',
    device_hourly_max int not null default 3 check (device_hourly_max >= 0),
    device_daily_max int not null default 5 check (device_daily_max >= 0),
    -- Через один NAT могут ходить несколько пользователей, поэтому лимит IP мягче.
    ip_hourly_max int not null default 10 check (ip_hourly_max >= 0),
    ip_daily_max int not null default 30 check (ip_daily_max >= 0),
    ticket_ttl interval not null default interval '10 minutes',
    -- false — письма можно отправлять и без талона email-gate (например, из Dashboard).
    -- Тогда лимиты устройства и IP не действуют, остальные лимиты — да.
    require_gate_ticket boolean not null default true,
    -- Граница «суток» для суточных лимитов.
    day_timezone text not null default 'Europe/Moscow',
    updated_at timestamptz not null default now()
);
insert into private.email_limits (id) values (1) on conflict (id) do nothing;

-- Запросы писем из приложения (через email-gate): для лимитов устройства и IP.
create table if not exists private.email_requests (
    id bigint generated always as identity primary key,
    created_at timestamptz not null default now(),
    action text not null,
    email_hash text not null,
    device_hash text,
    ip_hash text,
    allowed boolean not null,
    reason text
);
create index if not exists email_requests_device_idx on private.email_requests (device_hash, created_at) where allowed;
create index if not exists email_requests_ip_idx on private.email_requests (ip_hash, created_at) where allowed;

-- Талоны: разрешение email-gate на одно письмо для адреса и типа операции.
create table if not exists private.email_tickets (
    id uuid primary key default gen_random_uuid(),
    created_at timestamptz not null default now(),
    expires_at timestamptz not null,
    action text not null,
    email_hash text not null,
    consumed_at timestamptz,
    consumed_by text,
    -- Письмо по талону не ушло (ошибка SMTP): талон не учитывается в интервалах и лимите адреса.
    refunded boolean not null default false
);
create index if not exists email_tickets_lookup_idx on private.email_tickets (email_hash, action, expires_at) where consumed_at is null;

-- Письма: резерв → отправлено / ошибка. В лимиты идут reserved и sent; failed — нет.
create table if not exists private.email_sends (
    id bigint generated always as identity primary key,
    created_at timestamptz not null default now(),
    webhook_id text not null,
    action text not null,
    email_hash text not null,
    status text not null default 'reserved' check (status in ('reserved', 'sent', 'failed')),
    finished_at timestamptz,
    error text,
    ticket_id uuid
);
create unique index if not exists email_sends_webhook_recipient_idx on private.email_sends (webhook_id, email_hash);
create index if not exists email_sends_email_idx on private.email_sends (email_hash, action, created_at);
create index if not exists email_sends_day_idx on private.email_sends (created_at) where status <> 'failed';

alter table private.email_limits enable row level security;
alter table private.email_requests enable row level security;
alter table private.email_tickets enable row level security;
alter table private.email_sends enable row level security;
revoke all on all tables in schema private from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Вспомогательные функции
-- ---------------------------------------------------------------------------

create or replace function private.sha(p text)
returns text
language sql
immutable
set search_path = ''
as $$ select case when p is null or p = '' then null else encode(sha256(convert_to(p, 'UTF8')), 'hex') end $$;

create or replace function private.normalize_email(p text)
returns text
language sql
immutable
set search_path = ''
as $$ select lower(btrim(coalesce(p, ''))) $$;

-- Простая проверка формата: одна @, точка в домене, без пробелов, не длиннее 254 символов.
create or replace function private.valid_email(p text)
returns boolean
language sql
immutable
set search_path = ''
as $$
    select p is not null and char_length(p) <= 254
       and p ~ '^[^@\s<>()",;:]+@[^@\s<>()",;:]+\.[^@\s<>()",;:.]{2,}$'
$$;

create or replace function private.day_start(p_tz text)
returns timestamptz
language sql
stable
set search_path = ''
as $$ select (date_trunc('day', now() at time zone p_tz)) at time zone p_tz $$;

-- Секунды до следующей границы суток.
create or replace function private.seconds_to_next_day(p_tz text)
returns int
language sql
stable
set search_path = ''
as $$ select ceil(extract(epoch from (private.day_start(p_tz) + interval '1 day' - now())))::int $$;

-- Одна глобальная блокировка на все операции с квотой: проверка и резервирование
-- выполняются строго по очереди, параллельные запросы не могут потратить одно и то же место.
create or replace function private.lock_quota()
returns void
language sql
set search_path = ''
as $$ select pg_advisory_xact_lock(hashtextextended('leadgen-email-quota', 0)) $$;

create or replace function private.cooldown_for(cfg private.email_limits, p_action text)
returns interval
language sql
immutable
set search_path = ''
as $$
    select case p_action
        when 'signup' then cfg.signup_resend_cooldown
        when 'recovery' then cfg.recovery_cooldown
        when 'email_change' then cfg.email_change_cooldown
        else interval '0'
    end
$$;

-- Проверка лимитов адреса и общего лимита. Возвращает null, если отправить можно,
-- иначе {reason, retry_after}.
create or replace function private.check_email_limits(cfg private.email_limits, p_action text,
                                                      p_email_hash text, p_recipients text[],
                                                      p_skip_cooldown boolean default false)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
    day0 timestamptz := private.day_start(cfg.day_timezone);
    last_at timestamptz;
    prev_count int;
    used int;
    r text;
    cd interval := private.cooldown_for(cfg, p_action);
begin
    if not (p_action = any (cfg.enabled_actions)) then
        return jsonb_build_object('reason', 'action_disabled', 'retry_after', null);
    end if;

    -- Интервал между письмами одной операции для одного адреса.
    select max(created_at), count(*) into last_at, prev_count
    from private.email_sends
    where email_hash = p_email_hash and action = p_action and status <> 'failed';
    if p_skip_cooldown then
        null;  -- интервал уже проверил email-gate по выданным талонам
    elsif p_action = 'signup' and prev_count < cfg.signup_initial_max then
        null;  -- первое письмо регистрации отправляется сразу
    elsif last_at is not null and last_at + cd > now() then
        return jsonb_build_object('reason', 'cooldown',
                                  'retry_after', ceil(extract(epoch from (last_at + cd - now())))::int);
    end if;

    -- Не больше N писем за сутки на один адрес (все операции вместе).
    foreach r in array p_recipients loop
        select count(*) into used from private.email_sends
        where email_hash = r and status <> 'failed' and created_at >= day0;
        if used + 1 > cfg.per_email_daily_max then
            return jsonb_build_object('reason', 'email_daily', 'retry_after', private.seconds_to_next_day(cfg.day_timezone));
        end if;
    end loop;

    -- Общий лимит приложения.
    select count(*) into used from private.email_sends where status <> 'failed' and created_at >= day0;
    if used + coalesce(array_length(p_recipients, 1), 0) > cfg.global_daily_max then
        return jsonb_build_object('reason', 'global_daily', 'retry_after', private.seconds_to_next_day(cfg.day_timezone));
    end if;
    return null;
end;
$$;

-- Лимиты адреса для email-gate. Считаются по выданным талонам, а не по отправленным письмам:
-- Auth не отправляет письмо несуществующему (или уже подтверждённому) адресу, и подсчёт по
-- отправкам позволил бы через шлюз узнать, есть ли такой аккаунт. Талоны выдаются одинаково
-- для любых адресов. Талон, письмо по которому не ушло из-за ошибки SMTP, не учитывается.
create or replace function private.check_address_limits(cfg private.email_limits, p_action text, p_email_hash text)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
    day0 timestamptz := private.day_start(cfg.day_timezone);
    last_at timestamptz;
    prev_count int;
    used int;
    cd interval := private.cooldown_for(cfg, p_action);
begin
    if not (p_action = any (cfg.enabled_actions)) then
        return jsonb_build_object('reason', 'action_disabled', 'retry_after', null);
    end if;
    select max(created_at), count(*) into last_at, prev_count
    from private.email_tickets
    where email_hash = p_email_hash and action = p_action and not refunded;
    if p_action = 'signup' and prev_count < cfg.signup_initial_max then
        null;
    elsif last_at is not null and last_at + cd > now() then
        return jsonb_build_object('reason', 'cooldown',
                                  'retry_after', ceil(extract(epoch from (last_at + cd - now())))::int);
    end if;
    select count(*) into used from private.email_tickets
    where email_hash = p_email_hash and not refunded and created_at >= day0;
    if used + 1 > cfg.per_email_daily_max then
        return jsonb_build_object('reason', 'email_daily', 'retry_after', private.seconds_to_next_day(cfg.day_timezone));
    end if;
    select count(*) into used from private.email_sends where status <> 'failed' and created_at >= day0;
    if used + 1 > cfg.global_daily_max then
        return jsonb_build_object('reason', 'global_daily', 'retry_after', private.seconds_to_next_day(cfg.day_timezone));
    end if;
    return null;
end;
$$;

create or replace function private.cleanup_email_logs()
returns void
language sql
set search_path = ''
as $$
    delete from private.email_requests where created_at < now() - interval '8 days';
    delete from private.email_tickets where created_at < now() - interval '8 days';
    delete from private.email_sends where created_at < now() - interval '8 days';
$$;

-- ---------------------------------------------------------------------------
-- email_gate_request: запрос письма из приложения (вызывает функция email-gate)
-- ---------------------------------------------------------------------------
-- Ответ: {"allowed": bool, "reason": text|null, "retry_after": seconds|null}
-- Ответ одинаковый для существующих и несуществующих адресов: функция не знает об аккаунтах.

create or replace function public.email_gate_request(p_action text, p_email text, p_device text, p_ip text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
    cfg private.email_limits;
    email text := private.normalize_email(p_email);
    eh text;
    dh text := private.sha(nullif(btrim(coalesce(p_device, '')), ''));
    ih text := private.sha(nullif(btrim(coalesce(p_ip, '')), ''));
    verdict jsonb;
    n int;
    oldest timestamptz;
    day0 timestamptz;
begin
    if not private.valid_email(email) then
        return jsonb_build_object('allowed', false, 'reason', 'invalid_email', 'retry_after', null);
    end if;
    eh := private.sha(email);
    perform private.lock_quota();
    select * into cfg from private.email_limits where id = 1;
    day0 := private.day_start(cfg.day_timezone);
    perform private.cleanup_email_logs();

    -- Устройство (идентификатор приходит от клиента и может быть подменён: это
    -- дополнительный слой, а не основная защита).
    if dh is not null then
        select count(*), min(created_at) into n, oldest from private.email_requests
        where device_hash = dh and allowed and created_at > now() - interval '1 hour';
        if n >= cfg.device_hourly_max then
            verdict := jsonb_build_object('reason', 'device_hourly',
                'retry_after', greatest(1, ceil(extract(epoch from (oldest + interval '1 hour' - now())))::int));
        end if;
        if verdict is null then
            select count(*) into n from private.email_requests
            where device_hash = dh and allowed and created_at >= day0;
            if n >= cfg.device_daily_max then
                verdict := jsonb_build_object('reason', 'device_daily', 'retry_after', private.seconds_to_next_day(cfg.day_timezone));
            end if;
        end if;
    end if;

    -- IP (адрес определяет инфраструктура Supabase, а не клиент).
    if verdict is null and ih is not null then
        select count(*), min(created_at) into n, oldest from private.email_requests
        where ip_hash = ih and allowed and created_at > now() - interval '1 hour';
        if n >= cfg.ip_hourly_max then
            verdict := jsonb_build_object('reason', 'ip_hourly',
                'retry_after', greatest(1, ceil(extract(epoch from (oldest + interval '1 hour' - now())))::int));
        end if;
        if verdict is null then
            select count(*) into n from private.email_requests where ip_hash = ih and allowed and created_at >= day0;
            if n >= cfg.ip_daily_max then
                verdict := jsonb_build_object('reason', 'ip_daily', 'retry_after', private.seconds_to_next_day(cfg.day_timezone));
            end if;
        end if;
    end if;

    -- Лимиты адреса (по талонам, одинаково для любых адресов) и общий лимит
    -- (предварительно; окончательно — при отправке).
    if verdict is null then
        verdict := private.check_address_limits(cfg, p_action, eh);
    end if;

    insert into private.email_requests (action, email_hash, device_hash, ip_hash, allowed, reason)
    values (left(coalesce(p_action, ''), 40), eh, dh, ih, verdict is null, verdict ->> 'reason');

    if verdict is not null then
        return jsonb_build_object('allowed', false) || verdict;
    end if;

    insert into private.email_tickets (expires_at, action, email_hash)
    values (now() + cfg.ticket_ttl, p_action, eh);
    return jsonb_build_object('allowed', true, 'reason', null, 'retry_after', null);
end;
$$;

-- ---------------------------------------------------------------------------
-- email_hook_reserve: резерв квоты перед отправкой (вызывает функция send-email)
-- ---------------------------------------------------------------------------
-- p_webhook_id — идентификатор вызова хука. Повторы того же вызова не списывают квоту
-- второй раз. p_owner_email — адрес аккаунта (по нему ищется талон и считается интервал),
-- p_recipients — все адреса, на которые уйдут письма (при смене адреса их может быть два).
-- Ответ: {"allowed": true, "duplicate": bool} или {"allowed": false, "reason", "retry_after"}.

create or replace function public.email_hook_reserve(p_webhook_id text, p_action text,
                                                     p_owner_email text, p_recipients text[])
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
    cfg private.email_limits;
    owner_hash text := private.sha(private.normalize_email(p_owner_email));
    hashes text[];
    verdict jsonb;
    ticket uuid;
    existing text;
begin
    if p_webhook_id is null or p_webhook_id = '' then
        raise exception 'webhook id required' using errcode = '22023';
    end if;
    select array_agg(distinct private.sha(private.normalize_email(x))) into hashes
    from unnest(p_recipients) x where coalesce(x, '') <> '';
    if owner_hash is null or hashes is null then
        return jsonb_build_object('allowed', false, 'reason', 'invalid_email', 'retry_after', null);
    end if;

    perform private.lock_quota();
    select * into cfg from private.email_limits where id = 1;

    -- Повтор того же вызова хука.
    select string_agg(distinct status, ',') into existing from private.email_sends where webhook_id = p_webhook_id;
    if existing = 'sent' then
        return jsonb_build_object('allowed', true, 'duplicate', true);
    elsif existing is not null and existing <> 'failed' then
        -- Предыдущая попытка ещё не завершилась: второе письмо не отправляем.
        return jsonb_build_object('allowed', false, 'reason', 'in_progress', 'retry_after', 5);
    end if;
    delete from private.email_sends where webhook_id = p_webhook_id and status = 'failed';

    if cfg.require_gate_ticket then
        select id into ticket from private.email_tickets
        where email_hash = owner_hash and action = p_action and consumed_at is null and expires_at > now()
        order by created_at
        limit 1
        for update;
        if ticket is null then
            return jsonb_build_object('allowed', false, 'reason', 'no_ticket', 'retry_after', null);
        end if;
    end if;

    verdict := private.check_email_limits(cfg, p_action, owner_hash, hashes, p_skip_cooldown => ticket is not null);
    if verdict is not null then
        return jsonb_build_object('allowed', false) || verdict;
    end if;

    insert into private.email_sends (webhook_id, action, email_hash, ticket_id)
    select p_webhook_id, p_action, h, ticket from unnest(hashes) h;
    if ticket is not null then
        update private.email_tickets set consumed_at = now(), consumed_by = p_webhook_id, refunded = false where id = ticket;
    end if;
    return jsonb_build_object('allowed', true, 'duplicate', false);
end;
$$;

-- После отправки: какие адреса приняли письмо (sent), какие нет (failed). Неудачная отправка
-- не расходует квоту; если не ушло ни одно письмо, талон возвращается.
create or replace function public.email_hook_finish(p_webhook_id text, p_sent text[], p_failed text[],
                                                    p_error text default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
    perform private.lock_quota();
    update private.email_sends
    set status = 'sent', finished_at = now()
    where webhook_id = p_webhook_id and status = 'reserved'
      and email_hash in (select private.sha(private.normalize_email(x)) from unnest(coalesce(p_sent, '{}')) x);
    update private.email_sends
    set status = 'failed', finished_at = now(), error = left(p_error, 500)
    where webhook_id = p_webhook_id and status = 'reserved'
      and email_hash in (select private.sha(private.normalize_email(x)) from unnest(coalesce(p_failed, '{}')) x);
    if not exists (select 1 from private.email_sends where webhook_id = p_webhook_id and status <> 'failed') then
        update private.email_tickets set consumed_at = null, consumed_by = null, refunded = true where consumed_by = p_webhook_id;
    end if;
end;
$$;

-- Сводка за текущие сутки — для владельца проекта (SQL Editor: select public.email_quota_status();).
create or replace function public.email_quota_status()
returns jsonb
language sql
security definer
stable
set search_path = ''
as $$
    select jsonb_build_object(
        'day_started_at', private.day_start(l.day_timezone),
        'global_daily_max', l.global_daily_max,
        'sent', (select count(*) from private.email_sends s where s.status = 'sent' and s.created_at >= private.day_start(l.day_timezone)),
        'reserved', (select count(*) from private.email_sends s where s.status = 'reserved' and s.created_at >= private.day_start(l.day_timezone)),
        'failed', (select count(*) from private.email_sends s where s.status = 'failed' and s.created_at >= private.day_start(l.day_timezone)),
        'denied_requests', (select count(*) from private.email_requests r where not r.allowed and r.created_at >= private.day_start(l.day_timezone))
    )
    from private.email_limits l where l.id = 1
$$;

-- Эти функции вызываются только серверными функциями с ключом service_role.
revoke all on function public.email_gate_request(text, text, text, text) from public, anon, authenticated;
revoke all on function public.email_hook_reserve(text, text, text, text[]) from public, anon, authenticated;
revoke all on function public.email_hook_finish(text, text[], text[], text) from public, anon, authenticated;
revoke all on function public.email_quota_status() from public, anon, authenticated;
do $$
begin
    if exists (select 1 from pg_roles where rolname = 'service_role') then
        grant execute on function public.email_gate_request(text, text, text, text) to service_role;
        grant execute on function public.email_hook_reserve(text, text, text, text[]) to service_role;
        grant execute on function public.email_hook_finish(text, text[], text[], text) to service_role;
        grant execute on function public.email_quota_status() to service_role;
    end if;
end;
$$;
