#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

echo "==> Go unit tests"
go test ./...

echo "==> Shell syntax"
bash -n RootHelper/l2tp-office-root-helper.sh build-install.command push.command tests/root-helper-tests.sh

echo "==> Root helper unit tests"
bash tests/root-helper-tests.sh

echo "==> Swift compile check"
swiftc -parse-as-library L2TPOfficeApp/main.swift -o /tmp/L2TPOffice-test

echo "==> OK"
