#!/bin/bash
# Запускает собранное приложение и проверяет, что оно не падает при открытии окна.
# Ловит ошибки, которые не видны в unit-тестах (например, отсутствующие значения окружения SwiftUI).
set -euo pipefail
APP="${1:-build/Lead Generator.app}"
BIN="$APP/Contents/MacOS/LeadGenerator"
SECONDS_ALIVE="${SMOKE_SECONDS:-15}"

"$BIN" &
pid=$!
sleep "$SECONDS_ALIVE"
if kill -0 "$pid" 2>/dev/null; then
  echo "Приложение работает $SECONDS_ALIVE с после запуска"
  kill "$pid"; wait "$pid" 2>/dev/null || true
else
  wait "$pid" || code=$?
  echo "Приложение завершилось при запуске (код ${code:-0})" >&2
  ls -t ~/Library/Logs/DiagnosticReports/LeadGenerator* 2>/dev/null | head -1 | xargs -I{} head -80 {} >&2 || true
  exit 1
fi
