#!/usr/bin/env bash
set -uo pipefail
docker rm -f lg-gotrue lg-rest >/dev/null 2>&1
pkill -f "smtp_sink.py" 2>/dev/null
pkill -f "stack/gateway.ts" 2>/dev/null
echo "stack is down"
