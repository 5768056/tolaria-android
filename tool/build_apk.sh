#!/usr/bin/env bash
# One-shot build: pub get -> analyze -> test -> release APK.
#
# Usage (from the project root):
#   FLUTTER=flutter tool/build_apk.sh
#   FLUTTER=../.tools/fl.sh tool/build_apk.sh   # if using the SDK in .tools/
set -euo pipefail

# China mirrors: pub.dev archives and the official Flutter/Gradle hosts are
# unusably slow (or 502) without them. Remove these two exports outside China.
export PUB_HOSTED_URL="${PUB_HOSTED_URL:-https://pub.flutter-io.cn}"
export FLUTTER_STORAGE_BASE_URL="${FLUTTER_STORAGE_BASE_URL:-https://storage.flutter-io.cn}"

FLUTTER="${FLUTTER:-flutter}"

cd "$(dirname "$0")/.."

echo "==> pub get"
"$FLUTTER" pub get

echo "==> analyze"
"$FLUTTER" analyze

echo "==> test"
"$FLUTTER" test

echo "==> build apk --release"
"$FLUTTER" build apk --release

echo
echo "APK: build/app/outputs/flutter-apk/app-release.apk"
