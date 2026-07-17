#!/bin/bash
# Сборка L2TP Office.app и установка в /Applications
# Запуск: двойной клик в Finder или ./build-install.command
set -euo pipefail
cd "$(dirname "$0")"

APP="L2TP Office.app"
SRC="L2TPOfficeApp"

echo "==> Компиляция main.swift"
swiftc -O -parse-as-library "$SRC/main.swift" -o /tmp/L2TPOffice

echo "==> Компиляция user-space L2TP helper"
GOOS=darwin GOARCH=arm64 go build -trimpath -ldflags="-s -w" -o /tmp/l2tp-office-helper ./L2TPOfficeHelper

echo "==> Сборка бандла"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$SRC/Info.plist" "$APP/Contents/"
cp "$SRC/AppIcon.icns" "$APP/Contents/Resources/"
mv /tmp/L2TPOffice "$APP/Contents/MacOS/L2TPOffice"
mv /tmp/l2tp-office-helper "$APP/Contents/MacOS/l2tp-office-helper"
chmod +x "$APP/Contents/MacOS/L2TPOffice"
chmod +x "$APP/Contents/MacOS/l2tp-office-helper"

echo "==> Подпись (ad-hoc) — после копирования всех ресурсов, иначе иконка ломает подпись"
codesign --force --deep -s - "$APP"

echo "==> Установка в /Applications"
osascript -e 'tell application "L2TP Office" to quit' >/dev/null 2>&1 || true
sleep 1
rm -rf "/Applications/$APP"
ditto "$APP" "/Applications/$APP"
touch "/Applications/$APP"

echo "==> Сброс кэша иконок (лечит белый квадрат в доке)"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "/Applications/$APP"
rm -rf "$HOME/Library/Caches/com.apple.iconservices.store" 2>/dev/null || true
killall Dock

echo "==> Готово: /Applications/$APP"
