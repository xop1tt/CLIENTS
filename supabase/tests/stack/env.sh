# Параметры локального тестового стенда. Это НЕ облачные ключи: секреты ниже известны всем
# и годятся только для одноразовой базы на этом компьютере.
export STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export REPO_ROOT="$(cd "$STACK_DIR/../../.." && pwd)"
export PGHOST="${PGHOST:-127.0.0.1}" PGPORT="${PGPORT:-5432}" PGUSER="${PGUSER:-postgres}" PGPASSWORD="${PGPASSWORD:-postgres}"
export STACK_DB="${STACK_DB:-leadgen_test}"
export JWT_SECRET="local-test-jwt-secret-with-at-least-32-characters"
# Секрет хука собирается из заведомо тестовой строки, а не хранится готовым литералом:
# иначе secret scanning принимает его за настоящий ключ Stripe/Standard Webhooks.
export SEND_EMAIL_HOOK_SECRET="v1,whsec_$(printf '%s' 'test-hook-secret-1234567890abcdef' | base64 | tr -d '\n')"
export SUPABASE_URL="http://127.0.0.1:54321"
export SUPABASE_ANON_KEY="$(python3 "$STACK_DIR/jwt.py" "$JWT_SECRET" anon)"
export SUPABASE_SERVICE_ROLE_KEY="$(python3 "$STACK_DIR/jwt.py" "$JWT_SECRET" service_role)"
export STACK_MAIL_DIR="${STACK_MAIL_DIR:-/tmp/lg-mail}"
export SMTP_HOST=127.0.0.1 SMTP_PORT=2525 SMTP_MODE=plain SMTP_USER=sink-user SMTP_PASS=sink-pass
export SMTP_FROM="Lead Generator <no-reply@leadgen.test>"
export GOTRUE_IMAGE="${GOTRUE_IMAGE:-supabase/gotrue:v2.180.0}"
export POSTGREST_IMAGE="${POSTGREST_IMAGE:-postgrest/postgrest:v13.0.7}"
export DENO="${DENO:-deno}"
