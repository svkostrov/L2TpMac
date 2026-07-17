#!/bin/bash
# Коммит и push в https://github.com/svkostrov/L2TpMac
cd "$(dirname "$0")"
find .git -name '*.lock' -delete 2>/dev/null
find .git/objects -name 'tmp_obj_*' -delete 2>/dev/null
git add -A
git commit -m "Rebuild app bundle with fixed icon and robust menu bar window opening" || true
git push -u origin main
echo "==> push завершён"
