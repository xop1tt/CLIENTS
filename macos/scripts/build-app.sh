#!/bin/bash
# Сборка Customers.app из исходников (нужны Xcode или Command Line Tools, macOS 14+).
# Использование: ./scripts/build-app.sh [папка_назначения]
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${1:-build}"
VERSION="${LEADGEN_VERSION:-1.0.9}"

ARCH_FLAGS=()
if [[ "${UNIVERSAL:-0}" == "1" ]]; then ARCH_FLAGS=(--arch arm64 --arch x86_64); fi

swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}
BIN="$(swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)/LeadGenerator"

APP="$OUT/Customers.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/LeadGenerator"
# SQLCipher (шифрование локальной базы) подключён как динамический фреймворк: кладём его в пакет
# приложения и добавляем путь поиска Contents/Frameworks. Без него приложение не запустится.
FRAMEWORK="$(dirname "$BIN")/SQLCipher.framework"
if [[ ! -d "$FRAMEWORK" ]]; then
  echo "Не найден $FRAMEWORK — сборка без SQLCipher невозможна" >&2; exit 1
fi
mkdir -p "$APP/Contents/Frameworks"
ditto "$FRAMEWORK" "$APP/Contents/Frameworks/SQLCipher.framework"
RPATHS="$(otool -l "$APP/Contents/MacOS/LeadGenerator")"
if [[ "$RPATHS" != *"@executable_path/../Frameworks"* ]]; then
  install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/LeadGenerator"
fi
# Облако (необязательно): адрес проекта Supabase и ПУБЛИЧНЫЙ ключ (anon / publishable).
# Секретный ключ проекта (sb_secret_…) сюда никогда не передаётся — приложение его отвергнет.
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
  <key>CFBundleName</key><string>Customers</string>
  <key>CFBundleDisplayName</key><string>Customers</string>
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
# Иконка: одна, тёмная. Из Resources/AppIcon-1024.png (рисует scripts/make-icon.py, исходник AppIcon.svg)
# собирается AppIcon.icns. Приложение не подменяет значок в Dock: при выходе Dock показывает значок
# из пакета, поэтому он должен быть таким же, как во время работы.
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s Resources/AppIcon-1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) Resources/AppIcon-1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

# Подпись. Платного Apple Developer ID нет, поэтому при первом запуске скачанной сборки
# macOS попросит подтверждение: правый клик по приложению → «Открыть».
# LEADGEN_SIGN_IDENTITY — собственный (самоподписанный) сертификат: с ним подпись одинакова у всех
# версий, и Связка ключей не спрашивает пароль после каждого обновления. Без него — ad-hoc подпись,
# которая у каждой сборки своя.
SIGN_ID="${LEADGEN_SIGN_IDENTITY:--}"
if [ "$SIGN_ID" != "-" ] && ! codesign --force --deep --sign "$SIGN_ID" ${LEADGEN_SIGN_KEYCHAIN:+--keychain "$LEADGEN_SIGN_KEYCHAIN"} "$APP"; then
  echo "::warning::Не удалось подписать сертификатом, используется ad-hoc подпись" >&2
  SIGN_ID="-"
fi
if [ "$SIGN_ID" = "-" ]; then codesign --force --deep --sign - "$APP"; fi
codesign -dr - "$APP" 2>&1 | sed 's/^/Требование подписи: /' || true
echo "Готово: $APP"
