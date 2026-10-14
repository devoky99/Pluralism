#!/bin/sh
# Baut Pluralism.app aus dem Swift-Paket und signiert es ad hoc mit den nötigen
# Entitlements (Virtualization.framework funktioniert so ohne Apple-Entwicklerkonto).
#
# Aufruf:  ./scripts/build-app.sh            (Release-Build nach build/Pluralism.app)
#          ./scripts/build-app.sh debug      (Debug-Build)
set -eu

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "==> swift build ($CONFIG)"
swift build -c "$CONFIG" --product Pluralism --arch arm64

BIN_DIR="$(swift build -c "$CONFIG" --arch arm64 --show-bin-path)"
APP="$ROOT/build/Pluralism.app"

echo "==> App-Bundle zusammenstellen"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Pluralism" "$APP/Contents/MacOS/Pluralism"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
  cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist" 2>/dev/null || true
fi

echo "==> Ad-hoc signieren mit Entitlements"
codesign --force --sign - --entitlements "$ROOT/Resources/Pluralism.entitlements" --timestamp=none "$APP"
codesign --verify --verbose=2 "$APP"
codesign -d --entitlements - "$APP" 2>/dev/null | grep -q "com.apple.security.virtualization" \
  && echo "    Entitlement com.apple.security.virtualization ist gesetzt."

echo "==> Fertig: $APP"
echo "    Starten mit: open \"$APP\""
