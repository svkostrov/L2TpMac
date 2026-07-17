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
  fail "menu bar Settings button must not use blue prominent style"
fi

echo "source regression tests OK"
