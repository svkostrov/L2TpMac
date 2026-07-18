#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

app_version=$(/usr/bin/plutil -extract CFBundleShortVersionString raw L2TPOfficeApp/Info.plist)
/usr/bin/grep -Fq -- "- **$app_version**" README.md || fail "README history does not mention app version $app_version"

/usr/bin/grep -Fq 'Self.readLog(Self.logPath)' L2TPOfficeApp/main.swift || fail "GUI must read the full PPP/L2TP log"
if /usr/bin/grep -Fq 'tail(Self.logPath' L2TPOfficeApp/main.swift; then
  fail "GUI regressed to tailing the PPP/L2TP log"
fi

/usr/bin/grep -Fq 'Window("L2TP Office", id: "main")' L2TPOfficeApp/main.swift || fail "main scene must stay single-window"
/usr/bin/grep -Fq 'CommandGroup(replacing: .newItem)' L2TPOfficeApp/main.swift || fail "New Window command must stay disabled"

/usr/bin/grep -Fq 'primaryActionTitle' L2TPOfficeApp/main.swift || fail "menu bar must use one contextual connection action"
if /usr/bin/grep -Fq 'buttonStyle(.borderedProminent)' L2TPOfficeApp/main.swift; then
  /usr/bin/grep -Fq 'primaryActionIsDestructive' L2TPOfficeApp/main.swift || fail "prominent style must be limited to destructive menu action"
fi
/usr/bin/grep -Fq '.tint(.red)' L2TPOfficeApp/main.swift || fail "destructive disconnect action must stay red"
if /usr/bin/grep -Fq '.accentColor' L2TPOfficeApp/main.swift; then
  fail "menu action button must not use blue accent color"
fi
/usr/bin/grep -Fq 'Text("\(vpn.localIP) → \(vpn.remoteIP)")' L2TPOfficeApp/main.swift || fail "menu bar must show connected IPs"
/usr/bin/grep -Fq 'Text(vpn.remotePingText)' L2TPOfficeApp/main.swift || fail "menu bar must show ping text, not only an icon"
/usr/bin/grep -Fq 'return value <= 100 ? .green : .red' L2TPOfficeApp/main.swift || fail "menu bar ping text must be green up to 100 ms and red above 100 ms"
/usr/bin/grep -Fq '.foregroundStyle(pingTextColor)' L2TPOfficeApp/main.swift || fail "menu bar ping text must use ping threshold color"

echo "source regression tests OK"
