#!/bin/bash
# Baut Pluralism.app aus dem Swift-Paket, packt die QEMU-Laufzeit hinein und signiert alles ad hoc
# mit den nötigen Entitlements (ohne bezahltes Apple-Entwicklerkonto).
#
# Aufruf:  ./scripts/build-app.sh            Release-Build nach build/Pluralism.app
#          ./scripts/build-app.sh debug      Debug-Build
#
# Laufzeit: build/runtime (von scripts/runtime/build-runtime.sh) oder Pfad in PLURALISM_RUNTIME.
# Ohne Laufzeit entsteht eine App, die QEMU aus Homebrew sucht (nur für Linux-VMs nicht nötig).
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUNTIME="${PLURALISM_RUNTIME:-$ROOT/build/runtime}"
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

if [ -x "$RUNTIME/bin/qemu-system-aarch64" ]; then
  echo "==> QEMU-Laufzeit einpacken ($RUNTIME)"
  ditto "$RUNTIME" "$APP/Contents/Resources/Runtime"
  echo "==> Laufzeit signieren"
  find "$APP/Contents/Resources/Runtime/lib" -type f -name "*.dylib" -print0 | \
    xargs -0 -n 20 codesign --force --sign - --timestamp=none
  codesign --force --sign - --timestamp=none "$APP/Contents/Resources/Runtime/bin/qemu-img"
  codesign --force --sign - --timestamp=none "$APP/Contents/Resources/Runtime/bin/swtpm"
  codesign --force --sign - --timestamp=none \
    --entitlements "$ROOT/Resources/QEMU.entitlements" \
    "$APP/Contents/Resources/Runtime/bin/qemu-system-aarch64"
else
  echo "==> Hinweis: keine QEMU-Laufzeit unter $RUNTIME, die App sucht QEMU dann in Homebrew"
fi

echo "==> App ad hoc signieren"
codesign --force --sign - --timestamp=none --entitlements "$ROOT/Resources/Pluralism.entitlements" "$APP"
codesign --verify --strict --verbose=2 "$APP"
codesign -d --entitlements - "$APP" 2>/dev/null | grep -q "com.apple.security.virtualization" \
  && echo "    Entitlement com.apple.security.virtualization ist gesetzt."
if [ -x "$APP/Contents/Resources/Runtime/bin/qemu-system-aarch64" ]; then
  codesign -d --entitlements - "$APP/Contents/Resources/Runtime/bin/qemu-system-aarch64" 2>/dev/null \
    | grep -q "com.apple.security.hypervisor" && echo "    QEMU hat das Hypervisor-Entitlement."
  codesign -d --entitlements - "$APP/Contents/Resources/Runtime/bin/qemu-system-aarch64" 2>/dev/null \
    | grep -q "com.apple.security.virtualization" && echo "    QEMU darf vmnet ohne Root nutzen (Virtualization-Entitlement)." \
    || { echo "QEMU fehlt com.apple.security.virtualization"; exit 1; }
  "$APP/Contents/Resources/Runtime/bin/qemu-system-aarch64" -version | head -1
fi

du -sh "$APP"
echo "==> Fertig: $APP"
echo "    Starten mit: open \"$APP\""
