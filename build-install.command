#!/bin/bash
# Сборка L2TP Office.app и установка в /Applications
# Запуск: двойной клик в Finder или ./build-install.command
set -euo pipefail
cd "$(dirname "$0")"

APP="L2TP Office.app"
SRC="L2TPOfficeApp"

echo "==> Компиляция main.swift (universal arm64 + x86_64)"
swiftc -O -target arm64-apple-macos13 -parse-as-library "$SRC/main.swift" -o /tmp/L2TPOffice-arm64
swiftc -O -target x86_64-apple-macos13 -parse-as-library "$SRC/main.swift" -o /tmp/L2TPOffice-x86_64
lipo -create -output /tmp/L2TPOffice /tmp/L2TPOffice-arm64 /tmp/L2TPOffice-x86_64

echo "==> Компиляция user-space L2TP helper (universal arm64 + x86_64)"
GOOS=darwin GOARCH=arm64 go build -trimpath -ldflags="-s -w" -o /tmp/l2tp-office-helper-arm64 ./L2TPOfficeHelper
GOOS=darwin GOARCH=amd64 go build -trimpath -ldflags="-s -w" -o /tmp/l2tp-office-helper-x86_64 ./L2TPOfficeHelper
lipo -create -output /tmp/l2tp-office-helper /tmp/l2tp-office-helper-arm64 /tmp/l2tp-office-helper-x86_64

echo "==> Сборка бандла"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$SRC/Info.plist" "$APP/Contents/"
cp "$SRC/AppIcon.icns" "$APP/Contents/Resources/"
cp "RootHelper/l2tp-office-root-helper.sh" "$APP/Contents/Resources/"
mv /tmp/L2TPOffice "$APP/Contents/MacOS/L2TPOffice"
mv /tmp/l2tp-office-helper "$APP/Contents/MacOS/l2tp-office-helper"
chmod +x "$APP/Contents/MacOS/L2TPOffice"
chmod +x "$APP/Contents/MacOS/l2tp-office-helper"
chmod 644 "$APP/Contents/Resources/l2tp-office-root-helper.sh"

echo "==> Подпись (ad-hoc) — после копирования всех ресурсов, иначе иконка ломает подпись"
codesign --force --deep -s - "$APP"

echo "==> Установка в /Applications"
osascript -e 'tell application "L2TP Office" to quit' >/dev/null 2>&1 || true
sleep 1
rm -rf "/Applications/$APP"
ditto "$APP" "/Applications/$APP"
touch "/Applications/$APP"

echo "==> Обновление root-helper"
USER_NAME="$(id -un)"
ROOT_HELPER="/Library/PrivilegedHelperTools/com.rokot.l2tp-office.root-helper"
SUDOERS="/etc/sudoers.d/l2tp-office"
sudo /bin/mkdir -p /Library/PrivilegedHelperTools /etc/sudoers.d
sudo /bin/cp "/Applications/$APP/Contents/Resources/l2tp-office-root-helper.sh" "$ROOT_HELPER"
sudo /usr/sbin/chown root:wheel "$ROOT_HELPER"
sudo /bin/chmod 0500 "$ROOT_HELPER"
SUDOERS_TMP="$(/usr/bin/mktemp /tmp/l2tp-sudoers.XXXXXX)"
/bin/echo "$USER_NAME ALL=(root) NOPASSWD: $ROOT_HELPER" > "$SUDOERS_TMP"
sudo /usr/sbin/chown root:wheel "$SUDOERS_TMP"
sudo /bin/chmod 0440 "$SUDOERS_TMP"
sudo /usr/sbin/visudo -cf "$SUDOERS_TMP" >/dev/null
sudo /bin/mv "$SUDOERS_TMP" "$SUDOERS"

echo "==> Сброс кэша иконок (лечит белый квадрат в доке)"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "/Applications/$APP"
rm -rf "$HOME/Library/Caches/com.apple.iconservices.store" 2>/dev/null || true
killall Dock

echo "==> Готово: /Applications/$APP"
