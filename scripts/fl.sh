#!/bin/bash
# Run the Flutter tool straight from a locally extracted SDK, bypassing the
# `flutter.bat` bootstrap (which re-runs `pub upgrade` for flutter_tools on
# every invocation and makes each command take seconds longer).
#
# The SDK location is resolved relative to this script, not hard-coded:
#   <repo>/.tools/flutter        (the layout used in development)
# Override with FLUTTER_ROOT=/path/to/flutter if yours lives elsewhere.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FLUTTER_ROOT="${FLUTTER_ROOT:-$ROOT/.tools/flutter}"

if [ ! -x "$FLUTTER_ROOT/bin/cache/dart-sdk/bin/dart.exe" ]; then
  echo "ERROR: no Flutter SDK at $FLUTTER_ROOT" >&2
  echo "  set FLUTTER_ROOT, or put the SDK at .tools/flutter next to the repo" >&2
  exit 1
fi

# Mainland mirrors: the default hosts are slow or unreachable from CN.
# Both are overridable so a machine outside CN can use the official hosts.
export PUB_HOSTED_URL="${PUB_HOSTED_URL:-https://pub.flutter-io.cn}"
export FLUTTER_STORAGE_BASE_URL="${FLUTTER_STORAGE_BASE_URL:-https://storage.flutter-io.cn}"

exec "$FLUTTER_ROOT/bin/cache/dart-sdk/bin/dart.exe" \
  "$FLUTTER_ROOT/bin/cache/flutter_tools.snapshot" "$@"
