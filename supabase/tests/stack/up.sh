#!/usr/bin/env bash
# Поднимает локальный тестовый стенд: PostgreSQL (уже запущенный), Supabase Auth и PostgREST
# в Docker, функции и шлюз в Deno, тестовый SMTP. Облачный Supabase не используется.
set -euo pipefail
source "$(dirname "$0")/env.sh"
cd "$STACK_DIR"
mkdir -p "$STACK_MAIL_DIR" .run

psql -v ON_ERROR_STOP=1 -q -d postgres -c "drop database if exists $STACK_DB with (force)" -c "create database $STACK_DB"
psql -v ON_ERROR_STOP=1 -q -d "$STACK_DB" -f init-roles.sql

docker rm -f lg-gotrue lg-rest >/dev/null 2>&1 || true
docker run -d --name lg-gotrue --network host \
  -e GOTRUE_API_HOST=127.0.0.1 -e PORT=9999 -e API_EXTERNAL_URL="$SUPABASE_URL/auth/v1" \
  -e GOTRUE_DB_DRIVER=postgres \
  -e "DATABASE_URL=postgres://supabase_auth_admin:auth_admin@$PGHOST:$PGPORT/$STACK_DB?search_path=auth" \
  -e GOTRUE_SITE_URL=leadgenerator://auth/callback -e "GOTRUE_URI_ALLOW_LIST=leadgenerator://auth/**" \
  -e GOTRUE_JWT_SECRET="$JWT_SECRET" -e GOTRUE_JWT_EXP="${STACK_JWT_EXP:-3600}" -e GOTRUE_JWT_AUD=authenticated \
  -e GOTRUE_JWT_ADMIN_ROLES=service_role -e GOTRUE_JWT_DEFAULT_GROUP_NAME=authenticated \
  -e GOTRUE_DISABLE_SIGNUP=false -e GOTRUE_EXTERNAL_EMAIL_ENABLED=true -e GOTRUE_MAILER_AUTOCONFIRM=false \
  -e GOTRUE_MAILER_SECURE_EMAIL_CHANGE_ENABLED=true -e GOTRUE_MAILER_OTP_EXP=3600 -e GOTRUE_MAILER_OTP_LENGTH=6 \
  -e GOTRUE_HOOK_SEND_EMAIL_ENABLED=true -e GOTRUE_HOOK_SEND_EMAIL_URI="$SUPABASE_URL/functions/v1/send-email" \
  -e GOTRUE_HOOK_SEND_EMAIL_SECRETS="$SEND_EMAIL_HOOK_SECRET" \
  -e GOTRUE_PASSWORD_MIN_LENGTH=8 \
  -e "GOTRUE_PASSWORD_REQUIRED_CHARACTERS=abcdefghijklmnopqrstuvwxyz:ABCDEFGHIJKLMNOPQRSTUVWXYZ:0123456789" \
  -e GOTRUE_SMTP_MAX_FREQUENCY=1s -e GOTRUE_RATE_LIMIT_EMAIL_SENT=1000 \
  -e GOTRUE_RATE_LIMIT_HEADER=X-Forwarded-For -e GOTRUE_RATE_LIMIT_TOKEN_REFRESH="${STACK_RATE_LIMIT_TOKEN:-150}" \
  -e GOTRUE_RATE_LIMIT_VERIFY="${STACK_RATE_LIMIT_VERIFY:-1000}" \
  -e GOTRUE_SECURITY_REFRESH_TOKEN_ROTATION_ENABLED=true -e GOTRUE_SECURITY_REFRESH_TOKEN_REUSE_INTERVAL=0 \
  "$GOTRUE_IMAGE" >/dev/null

for i in $(seq 1 60); do curl -sf http://127.0.0.1:9999/health >/dev/null && break; sleep 1; done
curl -sf http://127.0.0.1:9999/health >/dev/null || { docker logs lg-gotrue | tail -30; exit 1; }

# Миграции проекта — после того, как Auth создал схему auth.
for f in "$REPO_ROOT"/supabase/migrations/*.sql; do
  PGOPTIONS='--client-min-messages=warning' psql -v ON_ERROR_STOP=1 -q -d "$STACK_DB" -f "$f"
done

docker run -d --name lg-rest --network host \
  -e PGRST_DB_URI="postgres://authenticator:authenticator@$PGHOST:$PGPORT/$STACK_DB" \
  -e PGRST_DB_SCHEMAS=public -e PGRST_DB_ANON_ROLE=anon -e PGRST_JWT_SECRET="$JWT_SECRET" \
  -e PGRST_SERVER_PORT=54330 -e PGRST_SERVER_HOST=127.0.0.1 "$POSTGREST_IMAGE" >/dev/null

pkill -f "smtp_sink.py" 2>/dev/null || true
pkill -f "stack/gateway.ts" 2>/dev/null || true
nohup python3 smtp_sink.py "$STACK_MAIL_DIR" 2525 > .run/smtp.log 2>&1 &
LEADGEN_INTERNAL_URL="$SUPABASE_URL" nohup "$DENO" run --allow-net --allow-env "$STACK_DIR/gateway.ts" > .run/gateway.log 2>&1 &

for i in $(seq 1 60); do
  curl -sf "http://127.0.0.1:54330/" -H "apikey: x" >/dev/null 2>&1 && \
  curl -s -o /dev/null "$SUPABASE_URL/functions/v1/nope" && break
  sleep 1
done
echo "stack is up: $SUPABASE_URL"
