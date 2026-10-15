#!/usr/bin/env python3
"""Stellt die mitgelieferte Laufzeit für Pluralism zusammen.

- kopiert qemu-system-aarch64, qemu-img und swtpm nach <out>/bin
- kopiert die nötige Firmware nach <out>/share/qemu
- sammelt alle Bibliotheken außerhalb des Systems (Homebrew) nach <out>/lib und schreibt die
  Ladepfade auf relative Pfade um (@executable_path/../lib, @loader_path)
- signiert alles ad hoc neu (QEMU mit dem Hypervisor-Entitlement)
- legt Lizenztexte und eine Versionsliste ab (GPL-Pflichten von QEMU)

Danach darf keine Datei mehr auf /opt/homebrew oder /usr/local verweisen.
"""

import argparse
import json
import os
import re
import shutil
import subprocess
import sys

SYSTEM_PREFIXES = ("/usr/lib/", "/System/")
FIRMWARE_FILES = ["edk2-aarch64-code.fd", "edk2-arm-vars.fd"]
FIRMWARE_DESCRIPTORS = ["firmware/60-edk2-aarch64.json"]


def run(cmd, check=True):
    result = subprocess.run(cmd, capture_output=True, text=True)
    if check and result.returncode != 0:
        sys.exit(f"Fehler bei {' '.join(cmd)}:\n{result.stdout}{result.stderr}")
    return result.stdout


def is_macho(path):
    try:
        with open(path, "rb") as handle:
            magic = handle.read(4)
    except OSError:
        return False
    return magic in (b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca")


def dependencies(path):
    """Abhängigkeiten laut otool -L (ohne die eigene ID bei Bibliotheken)."""
    lines = run(["otool", "-L", path]).splitlines()[1:]
    deps = []
    own_id = run(["otool", "-D", path]).splitlines()[1:]
    own_id = own_id[0].strip() if own_id else None
    for line in lines:
        match = re.match(r"\s+(.+?) \(compatibility version", line)
        if not match:
            continue
        dep = match.group(1)
        if dep == own_id:
            continue
        deps.append(dep)
    return deps


def rpaths(path):
    output = run(["otool", "-l", path])
    found = []
    lines = output.splitlines()
    for index, line in enumerate(lines):
        if "cmd LC_RPATH" in line:
            for follow in lines[index + 1:index + 4]:
                match = re.match(r"\s+path (.+?) \(offset", follow)
                if match:
                    found.append(match.group(1))
                    break
    return found


def resolve(dep, loader_original, executable_original):
    """Echter Pfad einer Abhängigkeit, so wie dyld sie beim ursprünglichen Ort finden würde."""
    loader_dir = os.path.dirname(loader_original)
    if dep.startswith("@loader_path/"):
        return os.path.realpath(os.path.join(loader_dir, dep[len("@loader_path/"):]))
    if dep.startswith("@executable_path/"):
        return os.path.realpath(os.path.join(os.path.dirname(executable_original), dep[len("@executable_path/"):]))
    if dep.startswith("@rpath/"):
        name = dep[len("@rpath/"):]
        candidates = []
        for entry in rpaths(loader_original) + rpaths(executable_original):
            entry = entry.replace("@loader_path", loader_dir)
            entry = entry.replace("@executable_path", os.path.dirname(executable_original))
            candidates.append(os.path.join(entry, name))
        candidates += [os.path.join("/opt/homebrew/lib", name), os.path.join(loader_dir, name)]
        for candidate in candidates:
            if os.path.exists(candidate):
                return os.path.realpath(candidate)
        sys.exit(f"Kann {dep} (benutzt von {loader_original}) nicht finden")
    return os.path.realpath(dep)


def is_system(dep):
    return dep.startswith(SYSTEM_PREFIXES)


def sign(path, entitlements=None):
    cmd = ["codesign", "--force", "--sign", "-", "--timestamp=none"]
    if entitlements:
        cmd += ["--entitlements", entitlements]
    run(cmd + [path])


def cellar_root(original):
    """/opt/homebrew/Cellar/<name>/<version> zu einer Datei, falls vorhanden."""
    match = re.match(r"(.*/Cellar/[^/]+/[^/]+)/", original)
    return match.group(1) if match else None


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--prefix", required=True, help="Installationsordner von QEMU")
    parser.add_argument("--swtpm", required=True, help="Pfad zum swtpm-Programm")
    parser.add_argument("--qemu-source", required=True, help="Quellordner von QEMU (Lizenzen, Entitlements)")
    parser.add_argument("--out", required=True)
    parser.add_argument("--qemu-version", default="")
    parser.add_argument("--swtpm-version", default="")
    args = parser.parse_args()

    out = os.path.abspath(args.out)
    if os.path.exists(out):
        shutil.rmtree(out)
    for sub in ("bin", "lib", "share/qemu/firmware", "share/licenses"):
        os.makedirs(os.path.join(out, sub), exist_ok=True)

    executables = {
        "qemu-system-aarch64": os.path.join(args.prefix, "bin", "qemu-system-aarch64"),
        "qemu-img": os.path.join(args.prefix, "bin", "qemu-img"),
        "swtpm": os.path.realpath(args.swtpm),
    }

    originals = {}        # kopierte Datei -> ursprünglicher Pfad
    executable_of = {}    # kopierte Datei -> ursprüngliches Programm, das sie lädt
    for name, source in executables.items():
        if not os.path.exists(source):
            sys.exit(f"Fehlt: {source}")
        target = os.path.join(out, "bin", name)
        shutil.copy2(source, target)
        os.chmod(target, 0o755)
        originals[target] = os.path.realpath(source)
        executable_of[target] = os.path.realpath(source)

    # Bibliotheken einsammeln (Breitensuche)
    queue = list(originals.keys())
    library_names = {}    # ursprünglicher echter Pfad -> Name in lib/
    rewrites = {}         # kopierte Datei -> [(alter Eintrag, neuer Eintrag)]
    while queue:
        current = queue.pop(0)
        original = originals[current]
        in_bin = os.path.dirname(current).endswith("/bin")
        rewrites[current] = []
        for dep in dependencies(current):
            if is_system(dep):
                continue
            real = resolve(dep, original, executable_of[current])
            name = library_names.get(real) or os.path.basename(dep)
            if real not in library_names:
                library_names[real] = name
                target = os.path.join(out, "lib", name)
                if not os.path.exists(target):
                    shutil.copy2(real, target)
                    os.chmod(target, 0o644)
                    originals[target] = real
                    executable_of[target] = executable_of[current]
                    queue.append(target)
            new = ("@executable_path/../lib/" if in_bin else "@loader_path/") + name
            rewrites[current].append((dep, new))

    # Ladepfade umschreiben
    for path, changes in rewrites.items():
        cmd = ["install_name_tool"]
        if os.path.dirname(path).endswith("/lib"):
            cmd += ["-id", "@rpath/" + os.path.basename(path)]
        for old, new in changes:
            if old != new:
                cmd += ["-change", old, new]
        if len(cmd) > 1:
            run(cmd + [path])
        for entry in rpaths(path):
            if not entry.startswith("@"):
                run(["install_name_tool", "-delete_rpath", entry, path], check=False)

    # Signieren: erst Bibliotheken, dann Programme
    entitlements = os.path.join(args.qemu_source, "accel", "hvf", "entitlements.plist")
    for path in sorted(rewrites):
        if path.endswith(".dylib") or os.path.dirname(path).endswith("/lib"):
            sign(path)
    for name in executables:
        path = os.path.join(out, "bin", name)
        sign(path, entitlements if name == "qemu-system-aarch64" and os.path.exists(entitlements) else None)

    # Firmware
    share = os.path.join(args.prefix, "share", "qemu")
    for name in FIRMWARE_FILES:
        source = os.path.join(share, name)
        if not os.path.exists(source):
            sys.exit(f"Firmware fehlt: {source}")
        shutil.copy2(source, os.path.join(out, "share", "qemu", name))
    for name in FIRMWARE_DESCRIPTORS:
        source = os.path.join(share, name)
        if os.path.exists(source):
            shutil.copy2(source, os.path.join(out, "share", "qemu", name))
    keymaps = os.path.join(share, "keymaps")
    if os.path.isdir(keymaps):
        shutil.copytree(keymaps, os.path.join(out, "share", "qemu", "keymaps"))

    # Lizenzen
    licenses = os.path.join(out, "share", "licenses")
    qemu_licenses = os.path.join(licenses, "qemu")
    os.makedirs(qemu_licenses, exist_ok=True)
    for name in ("COPYING", "COPYING.LIB", "LICENSE"):
        source = os.path.join(args.qemu_source, name)
        if os.path.exists(source):
            shutil.copy2(source, os.path.join(qemu_licenses, name))
    bundled = []
    for real, name in sorted(library_names.items(), key=lambda item: item[1]):
        root = cellar_root(real)
        formula, version = "", ""
        if root:
            parts = root.rstrip("/").split("/")
            formula, version = parts[-2], parts[-1]
            target = os.path.join(licenses, formula)
            if not os.path.isdir(target):
                os.makedirs(target)
                for entry in os.listdir(root):
                    if re.match(r"(LICEN[CS]E|COPYING|NOTICE|AUTHORS)", entry, re.IGNORECASE):
                        source = os.path.join(root, entry)
                        if os.path.isfile(source):
                            shutil.copy2(source, os.path.join(target, entry))
        bundled.append({"file": name, "formula": formula, "version": version})
    swtpm_root = cellar_root(os.path.realpath(args.swtpm))
    if swtpm_root:
        target = os.path.join(licenses, "swtpm")
        os.makedirs(target, exist_ok=True)
        for entry in os.listdir(swtpm_root):
            if re.match(r"(LICEN[CS]E|COPYING)", entry, re.IGNORECASE):
                shutil.copy2(os.path.join(swtpm_root, entry), os.path.join(target, entry))

    manifest = {
        "qemu": args.qemu_version,
        "swtpm": args.swtpm_version,
        "libraries": bundled,
        "source": "https://github.com/devoky99/Pluralism/tree/main/scripts/runtime",
    }
    with open(os.path.join(out, "share", "pluralism-runtime.json"), "w") as handle:
        json.dump(manifest, handle, indent=2, ensure_ascii=False)

    # Prüfen: keine Verweise mehr nach außen
    problems = []
    for folder in ("bin", "lib"):
        for name in os.listdir(os.path.join(out, folder)):
            path = os.path.join(out, folder, name)
            if not is_macho(path):
                continue
            for dep in dependencies(path):
                if not is_system(dep) and not dep.startswith("@"):
                    problems.append(f"{folder}/{name} -> {dep}")
    if problems:
        sys.exit("Externe Verweise übrig:\n" + "\n".join(problems))

    print(f"Laufzeit fertig: {len(executables)} Programme, {len(library_names)} Bibliotheken")


if __name__ == "__main__":
    main()
