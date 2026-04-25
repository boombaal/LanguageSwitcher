#!/usr/bin/env bash
# Run after: xcodebuild … Debug build. Requires interactive GUI session (Terminal.app).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Debug/LanguageSwitcher.app"
BIN="$APP/Contents/MacOS/LanguageSwitcher"
if [[ ! -x "$BIN" ]]; then
  echo "Build first: $BIN missing"
  exit 1
fi
pkill -f "LanguageSwitcher.app" 2>/dev/null || true
sleep 0.3
# Запуск через `open` на .app (как в Finder), а не прямой Mach-O — так же разумно для TCC.
echo "Launching 4s: $APP"
open "$APP"
sleep 4
pkill -f "LanguageSwitcher.app" 2>/dev/null || killall LanguageSwitcher 2>/dev/null || true
echo "---- ~/LanguageSwitcher-launch.log (last 15) ----"
tail -15 "$HOME/LanguageSwitcher-launch.log" 2>/dev/null || echo "(missing)"
echo "---- App Support/launch.log (last 15) ----"
tail -15 "$HOME/Library/Application Support/LanguageSwitcher/launch.log" 2>/dev/null || echo "(missing — run from Terminal on a logged-in Mac)"
echo "---- /tmp/LanguageSwitcher-boot.log (last 5) ----"
tail -5 /tmp/LanguageSwitcher-boot.log 2>/dev/null || echo "(missing)"
if grep -q "markProcessStart" "$HOME/LanguageSwitcher-launch.log" 2>/dev/null; then
  echo "OK: Swift markProcessStart line in home launch log"
  exit 0
fi
echo "FAIL: no 'markProcessStart' in ~/LanguageSwitcher-launch.log (need GUI session or longer wait)"
exit 1
