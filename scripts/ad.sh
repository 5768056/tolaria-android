#!/usr/bin/env bash
# adb helpers used while testing on a device/emulator.
#
#   ./scripts/ad.sh shell input tap 100 200   -> passthrough to adb
#   ./scripts/ad.sh shot home.png             -> save a screenshot
#   ./scripts/ad.sh dump                      -> list content-desc + bounds
#   ./scripts/ad.sh tapdesc "发送"             -> tap the node with that desc
#
# Which adb binary: $ADB, else $ANDROID_HOME/platform-tools/adb, else `adb`
# from PATH. An emulator may ship its own (MuMu's lives under
# <install>/nx_main/adb.exe); point $ADB at it when the SDK one cannot see
# the device. MuMu's adb also drops the connection intermittently — hence the
# retry loop in ensure().
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ADB="${ADB:-${ANDROID_HOME:-$HOME/AppData/Local/Android/Sdk}/platform-tools/adb.exe}"
[ -x "$ADB" ] || ADB=adb

# Git Bash rewrites /sdcard/... into a Windows path unless this is set.
export MSYS_NO_PATHCONV=1

ensure() {
  "$ADB" start-server >/dev/null 2>&1
  for _ in $(seq 1 25); do
    [ "$("$ADB" get-state 2>/dev/null | tr -d '\r')" = "device" ] && return 0
    sleep 2
  done
  echo "ERROR: device offline" >&2
  return 1
}

ensure || exit 1

case "${1:-}" in
  shot)
    mkdir -p "$ROOT/shots"
    "$ADB" exec-out screencap -p > "$ROOT/shots/${2:-shot.png}"
    echo "saved shots/${2:-shot.png}"
    ;;
  dump)
    "$ADB" shell uiautomator dump /sdcard/ui.xml >/dev/null 2>&1
    "$ADB" exec-out cat /sdcard/ui.xml > "$ROOT/ui.xml"
    grep -o 'content-desc="[^"]*"[^>]*bounds="[^"]*"' "$ROOT/ui.xml" \
      | sed -e 's/content-desc="//' -e 's/" *class=.*bounds="/  |  /' -e 's/"$//' \
      || echo "(no content-desc nodes)"
    ;;
  tapdesc)
    "$ADB" shell uiautomator dump /sdcard/ui.xml >/dev/null 2>&1
    "$ADB" exec-out cat /sdcard/ui.xml > "$ROOT/ui.xml"
    line=$(grep -oE "<node[^>]*content-desc=\"$2\"[ >][^>]*>" "$ROOT/ui.xml" | head -1)
    if [ -z "$line" ]; then echo "NOT FOUND: $2" >&2; exit 1; fi
    xy=$(echo "$line" | grep -o 'bounds="\[[0-9]*,[0-9]*\]\[[0-9]*,[0-9]*\]"' \
      | grep -o '[0-9]*')
    ax=$(echo "$xy" | sed -n 1p); ay=$(echo "$xy" | sed -n 2p)
    bx=$(echo "$xy" | sed -n 3p); by=$(echo "$xy" | sed -n 4p)
    cx=$(( (ax + bx) / 2 )); cy=$(( (ay + by) / 2 ))
    echo "tap $2 @ ($cx,$cy)"
    "$ADB" shell input tap "$cx" "$cy"
    ;;
  *)
    "$ADB" "$@"
    ;;
esac
