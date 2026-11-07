#!/bin/bash
# Упаковывает собранное приложение в установщик .dmg: окно с приложением и ярлыком «Программы»,
# куда его нужно перетащить. Использование: ./scripts/make-dmg.sh <выходной.dmg> [путь к .app]
set -euo pipefail
cd "$(dirname "$0")/.."
DMG="$1"
APP="${2:-build/Customers.app}"
STAGE="$(mktemp -d)/Customers"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Customers.app"
ln -s /Applications "$STAGE/Applications"
cp "$APP/Contents/Resources/AppIcon.icns" "$STAGE/.VolumeIcon.icns"
rm -f "$DMG"
hdiutil create -volname "Customers" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$DMG"
# Значок тома: флаг «custom icon» на корне образа (SetFile есть в Command Line Tools).
if command -v SetFile >/dev/null; then
  RW="$(mktemp -d)/rw.dmg"
  hdiutil convert "$DMG" -format UDRW -o "$RW" >/dev/null
  MNT="$(hdiutil attach -nobrowse -noautoopen "$RW" | awk -F'\t' '/\/Volumes\//{print $NF}')"
  SetFile -a C "$MNT" || true
  hdiutil detach "$MNT" >/dev/null
  rm -f "$DMG"
  hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -o "$DMG" >/dev/null
fi
hdiutil verify "$DMG"
echo "Готово: $DMG"
