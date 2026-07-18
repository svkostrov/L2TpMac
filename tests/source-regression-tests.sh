#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

app_version=$(/usr/bin/plutil -extract CFBundleShortVersionString raw L2TPOfficeApp/Info.plist)
/usr/bin/grep -Fq -- "- **$app_version**" README.md || fail "README history does not mention app version $app_version"
/usr/bin/grep -Fq "requiredRootHelperVersion = \"$app_version\"" L2TPOfficeApp/main.swift || fail "app must require root-helper $app_version"
/usr/bin/grep -Fq "ROOT_HELPER_VERSION=\"$app_version\"" RootHelper/l2tp-office-root-helper.sh || fail "root-helper version must match app version $app_version"
/usr/bin/grep -Fq 'retrying once' RootHelper/l2tp-office-root-helper.sh || fail "root-helper must retry the early L2TP handshake close once"

/usr/bin/grep -Fq 'Self.readLog(Self.logPath)' L2TPOfficeApp/main.swift || fail "GUI must read the full PPP/L2TP log"
if /usr/bin/grep -Fq 'tail(Self.logPath' L2TPOfficeApp/main.swift; then
  fail "GUI regressed to tailing the PPP/L2TP log"
fi

/usr/bin/grep -Fq 'Window("L2TP Office", id: "main")' L2TPOfficeApp/main.swift || fail "main scene must stay single-window"
/usr/bin/grep -Fq 'CommandGroup(replacing: .newItem)' L2TPOfficeApp/main.swift || fail "New Window command must stay disabled"

/usr/bin/grep -Fq 'primaryActionTitle' L2TPOfficeApp/main.swift || fail "menu bar must use one contextual connection action"
/usr/bin/grep -Fq '.tint(.red)' L2TPOfficeApp/main.swift || fail "destructive disconnect action must stay red"
/usr/bin/grep -Fq '.foregroundStyle(connectDisabled ? Color.secondary : Color.green)' L2TPOfficeApp/main.swift || fail "disabled window connect action must be visually dimmed"
/usr/bin/grep -Fq '.foregroundStyle(primaryActionDisabled ? Color.secondary : Color.green)' L2TPOfficeApp/main.swift || fail "disabled menu connect action must be visually dimmed"
if /usr/bin/grep -Fq '.tint(.green)' L2TPOfficeApp/main.swift; then
  fail "connect action must not use green button fill"
fi
if /usr/bin/grep -Fq '.accentColor' L2TPOfficeApp/main.swift; then
  fail "menu action button must not use blue accent color"
fi
/usr/bin/grep -Fq 'Text("\(vpn.localIP) → \(vpn.remoteIP)")' L2TPOfficeApp/main.swift || fail "menu bar must show connected IPs"
/usr/bin/grep -Fq 'Text(vpn.remotePingText)' L2TPOfficeApp/main.swift || fail "menu bar must show ping text, not only an icon"
/usr/bin/grep -Fq '@Published var uptimeText' L2TPOfficeApp/main.swift || fail "VPN manager must expose connection uptime"
/usr/bin/grep -Fq 'uptimeTimer = Timer.scheduledTimer(withTimeInterval: 1.0' L2TPOfficeApp/main.swift || fail "connection uptime must update every second"
/usr/bin/grep -Fq 'Text(vpn.uptimeText)' L2TPOfficeApp/main.swift || fail "UI must show connection uptime"
/usr/bin/grep -Fq 'formatUptime(since:' L2TPOfficeApp/main.swift || fail "VPN manager must format connection uptime"
/usr/bin/grep -Fq 'return value <= 100 ? .green : .red' L2TPOfficeApp/main.swift || fail "menu bar ping text must be green up to 100 ms and red above 100 ms"
/usr/bin/grep -Fq '.foregroundStyle(pingTextColor)' L2TPOfficeApp/main.swift || fail "menu bar ping text must use ping threshold color"
if /usr/bin/awk '/updater.checkForUpdates\\(silent: false\\)/,/NSWorkspace.shared.open\\(repositoryURL\\)/ { print }' L2TPOfficeApp/main.swift | /usr/bin/grep -Fq 'VStack(alignment: .leading'; then
  fail "menu bar update version and status must stay on one line"
fi

echo "source regression tests OK"
