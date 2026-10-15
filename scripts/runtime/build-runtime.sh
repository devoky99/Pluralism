#!/bin/bash
# Baut die Laufzeit, die Pluralism mitliefert: QEMU (nur ARM64-Gäste, Hypervisor.framework)
# aus dem Quellcode sowie swtpm. Ergebnis: build/runtime/ mit bin/, lib/, share/.
#
# Alle Bibliotheken werden in lib/ gebündelt und auf relative Pfade umgeschrieben,
# damit die App ohne Homebrew läuft.
#
# Aufruf: ./scripts/runtime/build-runtime.sh
# Braucht: Xcode bzw. Command Line Tools, Homebrew (nur zum Bauen).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=versions.env
source "$ROOT/scripts/runtime/versions.env"

WORK="${WORK:-$ROOT/build/runtime-work}"
OUT="${OUT:-$ROOT/build/runtime}"
PREFIX="$WORK/prefix"
JOBS="$(sysctl -n hw.ncpu)"

echo "==> Bauwerkzeuge und Bibliotheken (Homebrew)"
export HOMEBREW_NO_AUTO_UPDATE=1
export HOMEBREW_NO_INSTALL_CLEANUP=1
brew install --quiet ninja pkgconf glib pixman libslirp "$SWTPM_FORMULA" || true
for tool in ninja pkg-config; do
  command -v "$tool" >/dev/null || { echo "Fehlt: $tool"; exit 1; }
done

echo "==> QEMU $QEMU_VERSION laden und prüfen"
mkdir -p "$WORK"
cd "$WORK"
if [ ! -f "qemu-$QEMU_VERSION.tar.xz" ]; then
  curl -fL --retry 3 -o "qemu-$QEMU_VERSION.tar.xz" "$QEMU_URL"
fi
echo "$QEMU_SHA256  qemu-$QEMU_VERSION.tar.xz" | shasum -a 256 -c -
rm -rf "qemu-$QEMU_VERSION"
tar xf "qemu-$QEMU_VERSION.tar.xz"
cd "qemu-$QEMU_VERSION"

echo "==> QEMU konfigurieren"
# Nur was Pluralism braucht: ARM64-Gäste mit Hypervisor.framework, VNC für das Pluralism-Fenster,
# Cocoa für das optionale eigene Fenster, CoreAudio, Usermode-Netz als Ausweichweg, TPM über swtpm,
# qemu-img für Plattenabbilder. Keine Gastagenten, keine Ordnerfreigaben (Isolation).
./configure \
  --prefix="$PREFIX" \
  --target-list=aarch64-softmmu \
  --without-default-features \
  --enable-hvf \
  --enable-tools \
  --enable-pixman \
  --enable-vnc \
  --enable-cocoa \
  --enable-coreaudio \
  --enable-slirp \
  --enable-tpm \
  --enable-fdt=internal \
  --disable-docs \
  --disable-guest-agent \
  --disable-werror \
  --extra-cflags="-mmacosx-version-min=${MACOSX_DEPLOYMENT_TARGET:-15.0}" \
  --extra-ldflags="-mmacosx-version-min=${MACOSX_DEPLOYMENT_TARGET:-15.0}"

echo "==> QEMU bauen ($JOBS Kerne)"
make -j"$JOBS"
make install

echo "==> Laufzeit zusammenstellen"
SWTPM_BIN="$(brew --prefix "$SWTPM_FORMULA")/bin/swtpm"
python3 "$ROOT/scripts/runtime/assemble.py" \
  --prefix "$PREFIX" \
  --swtpm "$SWTPM_BIN" \
  --qemu-source "$WORK/qemu-$QEMU_VERSION" \
  --out "$OUT" \
  --qemu-version "$QEMU_VERSION" \
  --swtpm-version "$(brew list --versions "$SWTPM_FORMULA" | awk '{print $2}')"

echo "==> Selbsttest"
"$OUT/bin/qemu-system-aarch64" -version
"$OUT/bin/qemu-img" --version | head -1
"$OUT/bin/swtpm" --version
"$OUT/bin/qemu-system-aarch64" -machine virt -device help > "$WORK/devices.txt"
for device in virtio-blk-pci nvme virtio-net-pci ramfb qemu-xhci usb-storage tpm-tis-device; do
  grep -q "name \"$device\"" "$WORK/devices.txt" || { echo "Gerät fehlt: $device"; exit 1; }
done
"$OUT/bin/qemu-system-aarch64" -machine none -netdev help | grep -q dgram || { echo "netdev dgram fehlt"; exit 1; }
"$OUT/bin/qemu-system-aarch64" -machine none -accel help | grep -q hvf || { echo "hvf fehlt"; exit 1; }
du -sh "$OUT"
echo "==> Fertig: $OUT"
