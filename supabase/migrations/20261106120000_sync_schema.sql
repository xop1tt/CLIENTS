-- Lead Generator: облачное хранение и синхронизация данных пользователя.
--
-- Только добавляет новые объекты: ничего не удаляет и не меняет в существующих таблицах.
-- Миграция идемпотентна (IF NOT EXISTS / OR REPLACE), её можно применить повторно.
--
-- Модель синхронизации (подробно: docs/cloud.md):
--   * у каждой строки владелец user_id = auth.uid(); RLS не пускает к чужим строкам;
--   * каждое изменение получает server_seq из общей последовательности; клиент забирает
--     изменения «всё, что новее моего курсора» обычным GET с фильтром server_seq=gt.N;
--   * конфликты решаются по полям: у каждого поля своё время изменения (field_ts),
--     более старое изменение никогда не затирает более новое;
--   * удаление — «надгробие» (deleted = true), чтобы другие устройства узнали об удалении.

create schema if not exists private;
revoke all on schema private from public;

create sequence if not exists public.sync_seq as bigint;

-- ---------------------------------------------------------------------------
-- Таблицы
-- ---------------------------------------------------------------------------

-- Лиды пользователя: данные, найденные поиском, и отметки пользователя.
create table if not exists public.leads (
    user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
    lead_id text not null check (char_length(lead_id) between 1 and 300),
    fingerprint text not null default '' check (char_length(fingerprint) <= 300),
    kind text not null check (kind in ('order', 'organization')),
    source text not null check (char_length(source) between 1 and 100),
    title text not null check (char_length(title) <= 2000),
    score double precision not null default 0,
    relevance text not null default 'rejected' check (relevance in ('high', 'medium', 'low', 'rejected')),
    discovered_at timestamptz not null default now(),
    data jsonb not null default '{}'::jsonb check (jsonb_typeof(data) = 'object' and pg_column_size(data) <= 65536),
    favorite boolean not null default false,
    archived boolean not null default false,
    deleted boolean not null default false,
    seen boolean not null default false,
    note text not null default '' check (char_length(note) <= 20000),
    -- Время последнего изменения каждого поля: {"favorite": "2026-11-06T10:00:00Z", ...}
    field_ts jsonb not null default '{}'::jsonb check (jsonb_typeof(field_ts) = 'object'),
    updated_by text check (char_length(updated_by) <= 100),
    server_seq bigint not null default nextval('public.sync_seq'),
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    primary key (user_id, lead_id)
);
create index if not exists leads_user_seq_idx on public.leads (user_id, server_seq);

-- Исключения (домены, телефоны, email, названия).
create table if not exists public.exclusions (
    user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
    kind text not null check (kind in ('domain', 'phone', 'email', 'name')),
    value text not null check (char_length(value) between 1 and 500),
    deleted boolean not null default false,
    changed_at timestamptz not null default now(),
    updated_by text check (char_length(updated_by) <= 100),
    server_seq bigint not null default nextval('public.sync_seq'),
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    primary key (user_id, kind, value)
);
create index if not exists exclusions_user_seq_idx on public.exclusions (user_id, server_seq);

-- Настройки пользователя: ключ → JSON. Значения, привязанные к устройству (пути к файлам,
-- секреты, оформление), сюда не попадают — это решает клиент по списку разрешённых ключей.
create table if not exists public.user_settings (
    user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
    key text not null check (key ~ '^[a-z][a-z0-9_.-]{0,99}$'),
    value jsonb not null check (pg_column_size(value) <= 65536),
    changed_at timestamptz not null default now(),
    updated_by text check (char_length(updated_by) <= 100),
    server_seq bigint not null default nextval('public.sync_seq'),
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    primary key (user_id, key)
);
create index if not exists user_settings_user_seq_idx on public.user_settings (user_id, server_seq);

-- ---------------------------------------------------------------------------
-- Триггер: порядок изменений и неизменяемый владелец
-- ---------------------------------------------------------------------------
-- Все записи одного пользователя берут одну и ту же транзакционную блокировку до выдачи
-- server_seq. Поэтому номера фиксируются в том же порядке, в каком транзакции завершаются,
-- и клиент, забравший «всё новее N», не пропустит изменение, которое закоммитится позже.

create or replace function private.sync_stamp()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
    if tg_op = 'UPDATE' and new.user_id is distinct from old.user_id then
        raise exception 'user_id cannot be changed' using errcode = '42501';
    end if;
    perform pg_advisory_xact_lock(hashtextextended('leadgen-sync:' || new.user_id::text, 0));
    new.server_seq := nextval('public.sync_seq');
    new.updated_at := now();
    -- Время изменений не может быть в будущем, как бы строка ни записывалась (sync_push или
    -- прямой запрос к таблице): иначе «будущее» поле навсегда выигрывало бы у всех устройств.
    if tg_table_name = 'leads' then
        new.discovered_at := least(new.discovered_at, now());
        new.field_ts := coalesce((
            select jsonb_object_agg(k, to_jsonb(least((v #>> '{}')::timestamptz, now())))
            from jsonb_each(coalesce(new.field_ts, '{}'::jsonb)) as e(k, v)
        ), '{}'::jsonb);
    else
        new.changed_at := least(new.changed_at, now());
    end if;
    if tg_op = 'INSERT' then
        new.created_at := now();
    else
        new.created_at := old.created_at;
    end if;
    return new;
end;
$$;

drop trigger if exists leads_sync_stamp on public.leads;
create trigger leads_sync_stamp before insert or update on public.leads
    for each row execute function private.sync_stamp();
drop trigger if exists exclusions_sync_stamp on public.exclusions;
create trigger exclusions_sync_stamp before insert or update on public.exclusions
    for each row execute function private.sync_stamp();
drop trigger if exists user_settings_sync_stamp on public.user_settings;
create trigger user_settings_sync_stamp before insert or update on public.user_settings
    for each row execute function private.sync_stamp();

-- ---------------------------------------------------------------------------
-- Row Level Security: каждый видит и меняет только свои строки
-- ---------------------------------------------------------------------------

alter table public.leads enable row level security;
alter table public.exclusions enable row level security;
alter table public.user_settings enable row level security;
alter table public.leads force row level security;
alter table public.exclusions force row level security;
alter table public.user_settings force row level security;

do $$
declare
    t text;
begin
    foreach t in array array['leads', 'exclusions', 'user_settings'] loop
        execute format('drop policy if exists %I on public.%I', t || '_select_own', t);
        execute format('drop policy if exists %I on public.%I', t || '_insert_own', t);
        execute format('drop policy if exists %I on public.%I', t || '_update_own', t);
        execute format('drop policy if exists %I on public.%I', t || '_delete_own', t);
        execute format($p$create policy %I on public.%I for select to authenticated
                          using ((select auth.uid()) = user_id)$p$, t || '_select_own', t);
        execute format($p$create policy %I on public.%I for insert to authenticated
                          with check ((select auth.uid()) = user_id)$p$, t || '_insert_own', t);
        execute format($p$create policy %I on public.%I for update to authenticated
                          using ((select auth.uid()) = user_id)
                          with check ((select auth.uid()) = user_id)$p$, t || '_update_own', t);
        execute format($p$create policy %I on public.%I for delete to authenticated
                          using ((select auth.uid()) = user_id)$p$, t || '_delete_own', t);
    end loop;
end;
$$;

-- Анонимный ключ (anon) к данным доступа не имеет вовсе.
revoke all on public.leads, public.exclusions, public.user_settings from anon, public;
grant select, insert, update, delete on public.leads, public.exclusions, public.user_settings to authenticated;
grant usage on sequence public.sync_seq to authenticated;

-- ---------------------------------------------------------------------------
-- sync_push: выгрузка изменений с устройства
-- ---------------------------------------------------------------------------
-- Вызывается как POST /rest/v1/rpc/sync_push с JWT пользователя. Работает с правами
-- вызывающего (security invoker), поэтому RLS действует и здесь.
--
-- p_changes = {
--   "leads": [{"lead_id", "fingerprint", "kind", "source", "title", "score", "relevance",
--              "discovered_at", "data", "favorite", "archived", "deleted", "seen", "note",
--              "ts": {"data": iso, "favorite": iso, ...}}],
--   "exclusions": [{"kind", "value", "deleted", "changed_at"}],
--   "settings": [{"key", "value", "changed_at"}]
-- }
-- Поле применяется, только если его время изменения новее серверного. Время с устройства
-- не может быть больше времени сервера (защита от неверных часов на устройстве).
-- Повторная отправка тех же изменений ничего не меняет (идемпотентность).

create or replace function public.sync_push(p_device text, p_changes jsonb)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
    uid uuid := auth.uid();
    server_now timestamptz := now();
    item jsonb;
    cur public.leads%rowtype;
    f text;
    ts timestamptz;
    cur_ts timestamptz;
    new_ts jsonb;
    changed boolean;
    rows_changed int;
    n_leads int := 0;
    n_excl int := 0;
    n_settings int := 0;
    lead_fields constant text[] := array['data', 'favorite', 'archived', 'deleted', 'seen', 'note'];
begin
    if uid is null then
        raise exception 'not authenticated' using errcode = '42501';
    end if;
    if jsonb_typeof(p_changes) is distinct from 'object' then
        raise exception 'p_changes must be an object' using errcode = '22023';
    end if;
    if coalesce(jsonb_array_length(p_changes -> 'leads'), 0)
       + coalesce(jsonb_array_length(p_changes -> 'exclusions'), 0)
       + coalesce(jsonb_array_length(p_changes -> 'settings'), 0) > 500 then
        raise exception 'too many changes in one request (max 500)' using errcode = '54000';
    end if;
    p_device := left(p_device, 100);
    perform pg_advisory_xact_lock(hashtextextended('leadgen-sync:' || uid::text, 0));

    -- Лиды
    for item in select * from jsonb_array_elements(coalesce(p_changes -> 'leads', '[]'::jsonb)) loop
        select * into cur from public.leads where user_id = uid and lead_id = item ->> 'lead_id' for update;
        if not found then
            if not (item ? 'data') then
                continue;  -- без данных лида создать нельзя; клиент пришлёт их следующим запросом
            end if;
            new_ts := '{}'::jsonb;
            foreach f in array lead_fields loop
                ts := least(coalesce((item -> 'ts' ->> f)::timestamptz, '1970-01-01'::timestamptz), server_now);
                new_ts := new_ts || jsonb_build_object(f, ts);
            end loop;
            insert into public.leads (user_id, lead_id, fingerprint, kind, source, title, score, relevance,
                                      discovered_at, data, favorite, archived, deleted, seen, note,
                                      field_ts, updated_by)
            values (uid, item ->> 'lead_id', coalesce(item ->> 'fingerprint', ''), item ->> 'kind',
                    item ->> 'source', coalesce(item ->> 'title', ''), coalesce((item ->> 'score')::float8, 0),
                    coalesce(item ->> 'relevance', 'rejected'),
                    least(coalesce((item ->> 'discovered_at')::timestamptz, server_now), server_now), item -> 'data',
                    coalesce((item ->> 'favorite')::boolean, false), coalesce((item ->> 'archived')::boolean, false),
                    coalesce((item ->> 'deleted')::boolean, false), coalesce((item ->> 'seen')::boolean, false),
                    coalesce(item ->> 'note', ''), new_ts, p_device);
            n_leads := n_leads + 1;
            continue;
        end if;

        changed := false;
        new_ts := cur.field_ts;
        foreach f in array lead_fields loop
            continue when not (item ? f);
            ts := least(coalesce((item -> 'ts' ->> f)::timestamptz, '1970-01-01'::timestamptz), server_now);
            cur_ts := coalesce((cur.field_ts ->> f)::timestamptz, '-infinity'::timestamptz);
            continue when ts <= cur_ts;
            changed := true;
            new_ts := new_ts || jsonb_build_object(f, ts);
            case f
                when 'data' then
                    cur.data := item -> 'data';
                    cur.fingerprint := coalesce(item ->> 'fingerprint', cur.fingerprint);
                    cur.kind := coalesce(item ->> 'kind', cur.kind);
                    cur.source := coalesce(item ->> 'source', cur.source);
                    cur.title := coalesce(item ->> 'title', cur.title);
                    cur.score := coalesce((item ->> 'score')::float8, cur.score);
                    cur.relevance := coalesce(item ->> 'relevance', cur.relevance);
                    -- Дата обнаружения — самая ранняя из известных.
                    cur.discovered_at := least(cur.discovered_at, coalesce((item ->> 'discovered_at')::timestamptz, cur.discovered_at));
                when 'favorite' then cur.favorite := (item ->> 'favorite')::boolean;
                when 'archived' then cur.archived := (item ->> 'archived')::boolean;
                when 'deleted' then cur.deleted := (item ->> 'deleted')::boolean;
                when 'seen' then cur.seen := (item ->> 'seen')::boolean;
                when 'note' then cur.note := coalesce(item ->> 'note', '');
            end case;
        end loop;
        if changed then
            update public.leads set
                fingerprint = cur.fingerprint, kind = cur.kind, source = cur.source, title = cur.title,
                score = cur.score, relevance = cur.relevance, discovered_at = cur.discovered_at, data = cur.data,
                favorite = cur.favorite, archived = cur.archived, deleted = cur.deleted, seen = cur.seen,
                note = cur.note, field_ts = new_ts, updated_by = p_device
            where user_id = uid and lead_id = cur.lead_id;
            n_leads := n_leads + 1;
        end if;
    end loop;

    -- Исключения
    for item in select * from jsonb_array_elements(coalesce(p_changes -> 'exclusions', '[]'::jsonb)) loop
        ts := least(coalesce((item ->> 'changed_at')::timestamptz, '1970-01-01'::timestamptz), server_now);
        insert into public.exclusions as e (user_id, kind, value, deleted, changed_at, updated_by)
        values (uid, item ->> 'kind', item ->> 'value', coalesce((item ->> 'deleted')::boolean, false), ts, p_device)
        on conflict (user_id, kind, value) do update
            set deleted = excluded.deleted, changed_at = excluded.changed_at, updated_by = excluded.updated_by
            where e.changed_at < excluded.changed_at;
        get diagnostics rows_changed = row_count;
        if rows_changed > 0 then n_excl := n_excl + 1; end if;
    end loop;

    -- Настройки
    for item in select * from jsonb_array_elements(coalesce(p_changes -> 'settings', '[]'::jsonb)) loop
        ts := least(coalesce((item ->> 'changed_at')::timestamptz, '1970-01-01'::timestamptz), server_now);
        insert into public.user_settings as s (user_id, key, value, changed_at, updated_by)
        values (uid, item ->> 'key', item -> 'value', ts, p_device)
        on conflict (user_id, key) do update
            set value = excluded.value, changed_at = excluded.changed_at, updated_by = excluded.updated_by
            where s.changed_at < excluded.changed_at;
        get diagnostics rows_changed = row_count;
        if rows_changed > 0 then n_settings := n_settings + 1; end if;
    end loop;

    return jsonb_build_object('server_time', server_now, 'leads', n_leads,
                              'exclusions', n_excl, 'settings', n_settings);
end;
$$;

revoke all on function public.sync_push(text, jsonb) from public, anon;
grant execute on function public.sync_push(text, jsonb) to authenticated;

-- Сводка для проверки переноса данных: сколько строк пользователя лежит в облаке.
create or replace function public.sync_stats()
returns jsonb
language sql
security invoker
stable
set search_path = ''
as $$
    select jsonb_build_object(
        'leads', (select count(*) from public.leads where user_id = auth.uid()),
        'leads_active', (select count(*) from public.leads where user_id = auth.uid() and not deleted),
        'exclusions', (select count(*) from public.exclusions where user_id = auth.uid() and not deleted),
        'settings', (select count(*) from public.user_settings where user_id = auth.uid()),
        'max_seq', (select coalesce(max(m), 0) from (
            select max(server_seq) m from public.leads where user_id = auth.uid()
            union all select max(server_seq) from public.exclusions where user_id = auth.uid()
            union all select max(server_seq) from public.user_settings where user_id = auth.uid()) x)
    );
$$;

revoke all on function public.sync_stats() from public, anon;
grant execute on function public.sync_stats() to authenticated;
