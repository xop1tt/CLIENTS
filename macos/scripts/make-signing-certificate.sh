#!/bin/bash
# Создаёт собственный (самоподписанный) сертификат подписи кода для релизов Lead Generator
# и кладёт его в секреты репозитория MACOS_SIGN_P12 и MACOS_SIGN_PASSWORD.
#
# Зачем: Связка ключей macOS запоминает разрешение «Разрешать всегда» для подписи приложения.
# Ad-hoc подпись у каждой сборки своя, поэтому после каждого обновления macOS снова спрашивает
# пароль. С одним и тем же сертификатом подпись у всех версий одинакова.
# Это бесплатно, но это не Apple Developer ID: Gatekeeper по-прежнему попросит «Открыть»
# при первом запуске скачанного dmg.
#
# Запуск на своём Mac (нужен установленный и авторизованный gh: brew install gh && gh auth login):
#   ./macos/scripts/make-signing-certificate.sh
# Без gh скрипт сохранит файлы и подскажет, что вставить в Settings → Secrets → Actions.
set -euo pipefail

REPO="${REPO:-xop1tt/CLIENTS}"
NAME="Lead Generator Self-Signed"
DIR="$(mktemp -d)"
trap 'rm -rf "$DIR"' EXIT
PASSWORD="$(openssl rand -base64 24)"

cat > "$DIR/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
CNF

# Срок 20 лет: сертификат должен пережить все будущие релизы, иначе подпись сменится.
openssl req -x509 -newkey rsa:2048 -nodes -days 7300 -config "$DIR/cert.cnf" \
  -keyout "$DIR/key.pem" -out "$DIR/cert.pem" 2>/dev/null
# Старый формат PKCS#12 (-legacy в OpenSSL 3), его понимает `security import` в macOS.
LEGACY=""
if openssl version | grep -q "^OpenSSL 3"; then LEGACY="-legacy"; fi
openssl pkcs12 -export $LEGACY -inkey "$DIR/key.pem" -in "$DIR/cert.pem" -name "$NAME" \
  -out "$DIR/sign.p12" -passout "pass:$PASSWORD"
P12_B64="$(base64 < "$DIR/sign.p12" | tr -d '\n')"

if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  printf '%s' "$P12_B64" | gh secret set MACOS_SIGN_P12 --repo "$REPO"
  printf '%s' "$PASSWORD" | gh secret set MACOS_SIGN_PASSWORD --repo "$REPO"
  echo "Готово: секреты MACOS_SIGN_P12 и MACOS_SIGN_PASSWORD заданы в $REPO."
  echo "Следующий релиз будет подписан этим сертификатом."
else
  OUT="$HOME/Desktop/lead-generator-signing"
  mkdir -p "$OUT"
  printf '%s' "$P12_B64" > "$OUT/MACOS_SIGN_P12.txt"
  printf '%s' "$PASSWORD" > "$OUT/MACOS_SIGN_PASSWORD.txt"
  echo "gh не найден. Файлы сохранены в $OUT."
  echo "Откройте https://github.com/$REPO/settings/secrets/actions, создайте два секрета"
  echo "с именами файлов и вставьте их содержимое, затем удалите папку $OUT."
fi
echo "Не создавайте сертификат заново: новый сертификат снова сменит подпись."
