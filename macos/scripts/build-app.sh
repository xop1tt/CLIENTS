#!/bin/bash
# Сборка Lead Generator.app из исходников (нужны Xcode или Command Line Tools, macOS 14+).
# Использование: ./scripts/build-app.sh [папка_назначения]
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${1:-build}"
VERSION="${LEADGEN_VERSION:-0.1.0}"

ARCH_FLAGS=()
if [[ "${UNIVERSAL:-0}" == "1" ]]; then ARCH_FLAGS=(--arch arm64 --arch x86_64); fi

swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}
BIN="$(swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)/LeadGenerator"

APP="$OUT/Lead Generator.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/LeadGenerator"
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
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
</dict>
</plist>
PLIST
# Локальная (ad-hoc) подпись: без платного Apple Developer ID. При первом запуске скачанной сборки
# macOS попросит подтверждение: правый клик по приложению → «Открыть».
codesign --force --deep --sign - "$APP"
echo "Готово: $APP"
