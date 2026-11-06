#!/bin/bash
# Сборка Lead Generator.app из исходников (нужны Xcode или Command Line Tools, macOS 14+).
# Использование: ./scripts/build-app.sh [папка_назначения]
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${1:-build}"
VERSION="${LEADGEN_VERSION:-1.0.5}"

ARCH_FLAGS=()
if [[ "${UNIVERSAL:-0}" == "1" ]]; then ARCH_FLAGS=(--arch arm64 --arch x86_64); fi

swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}
BIN="$(swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)/LeadGenerator"

APP="$OUT/Lead Generator.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/LeadGenerator"
# Облако (необязательно): адрес проекта Supabase и ПУБЛИЧНЫЙ ключ (anon / publishable).
# Секретный ключ (service_role / sb_secret_) сюда никогда не передаётся — приложение его отвергнет.
# Без этих переменных собирается версия только с локальными учётными записями.
CLOUD_KEYS=""
if [[ -n "${SUPABASE_URL:-}" && -n "${SUPABASE_ANON_KEY:-}" ]]; then
  if [[ "$SUPABASE_ANON_KEY" == sb_secret_* || ! "$SUPABASE_URL" =~ ^https://[A-Za-z0-9.-]+/?$ ]]; then
    echo "SUPABASE_URL должен быть https-адресом, SUPABASE_ANON_KEY — публичным ключом" >&2; exit 1
  fi
  CLOUD_KEYS="  <key>LGSupabaseURL</key><string>${SUPABASE_URL%/}</string>
  <key>LGSupabaseAnonKey</key><string>${SUPABASE_ANON_KEY}</string>"
fi
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Lead Generator</string>
  <key>CFBundleDisplayName</key><string>Lead Generator</string>
  <key>CFBundleIdentifier</key><string>local.leadgenerator.app</string>
  <key>CFBundleExecutable</key><string>LeadGenerator</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>CFBundleDevelopmentRegion</key><string>ru</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
  <key>CFBundleURLTypes</key>
  <array><dict>
    <key>CFBundleURLName</key><string>local.leadgenerator.app.auth</string>
    <key>CFBundleURLSchemes</key><array><string>leadgenerator</string></array>
  </dict></array>
${CLOUD_KEYS}
</dict>
</plist>
PLIST
# Иконка: из Resources/AppIcon-1024.png (исходник Resources/AppIcon.svg) собирается AppIcon.icns,
# тёмная версия — Resources/AppIcon-Dark-1024.png (исходник AppIcon-Dark.svg).
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s Resources/AppIcon-1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) Resources/AppIcon-1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
# Тёмный вариант: приложение ставит его в Dock, когда в macOS включена тёмная тема.
sips -z 512 512 Resources/AppIcon-Dark-1024.png --out "$APP/Contents/Resources/AppIcon-Dark.png" >/dev/null

# Локальная (ad-hoc) подпись: без платного Apple Developer ID. При первом запуске скачанной сборки
# macOS попросит подтверждение: правый клик по приложению → «Открыть».
codesign --force --deep --sign - "$APP"
echo "Готово: $APP"
