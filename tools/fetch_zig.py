#!/usr/bin/env python3
"""
fetch_zig.py — pobiera przypiętą wersję Zig do tools/zig/.

Projekt FerrumScope nie zależy od Zig z PATH. Wersja jest przypięta w tym
skrypcie i w build.zig.zon; skrypt jest idempotentny.

Każde pobrane archiwum jest weryfikowane sumą SHA-256 przypiętą poniżej
(wartości z https://ziglang.org/download/index.json, pole `shasum`). Archiwum
o innej sumie NIE jest rozpakowywane.

Użycie:
    python tools/fetch_zig.py
    python tools/fetch_zig.py --check
"""

from __future__ import annotations

import argparse
import hashlib
import io
import os
import platform
import sys
import urllib.request
import zipfile

# Przypięta wersja. Zmiana tutaj = zmiana w build.zig.zon i w docs/.
ZIG_VERSION = "0.15.2"
# Które artefakty bierzemy dla hosta i dla krzyżowej kompilacji pod testy replay.
HOST_TARGET = {
    "windows": f"zig-x86_64-windows-{ZIG_VERSION}.zip",
    "linux": f"zig-x86_64-linux-{ZIG_VERSION}.tar.xz",
    "macos": f"zig-x86_64-macos-{ZIG_VERSION}.tar.xz",
    "windows-aarch64": f"zig-aarch64-windows-{ZIG_VERSION}.zip",
    "macos-aarch64": f"zig-aarch64-macos-{ZIG_VERSION}.tar.xz",
}

# SHA-256 archiwów Zig 0.15.2 (https://ziglang.org/download/index.json).
# Zmiana wersji = zmiana tych sum; brak sumy = odmowa pobrania.
ZIG_SHA256 = {
    f"zig-x86_64-windows-{ZIG_VERSION}.zip":
        "3a0ed1e8799a2f8ce2a6e6290a9ff22e6906f8227865911fb7ddedc3cc14cb0c",
    f"zig-x86_64-linux-{ZIG_VERSION}.tar.xz":
        "02aa270f183da276e5b5920b1dac44a63f1a49e55050ebde3aecc9eb82f93239",
    f"zig-x86_64-macos-{ZIG_VERSION}.tar.xz":
        "375b6909fc1495d16fc2c7db9538f707456bfc3373b14ee83fdd3e22b3d43f7f",
    f"zig-aarch64-windows-{ZIG_VERSION}.zip":
        "b926465f8872bf983422257cd9ec248bb2b270996fbe8d57872cca13b56fc370",
    f"zig-aarch64-macos-{ZIG_VERSION}.tar.xz":
        "3cc2bab367e185cdfb27501c4b30b1b0653c28d9f73df8dc91488e66ece5fa6b",
}

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
DEST = os.path.join(ROOT, "tools", "zig")


def zig_exe() -> str | None:
    if not os.path.isdir(DEST):
        return None
    for name in os.listdir(DEST):
        if not name.startswith("zig-"):
            continue
        for exe in (os.path.join(DEST, name, "zig.exe"),
                    os.path.join(DEST, name, "zig")):
            if os.path.exists(exe):
                return exe
    return None


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--check", action="store_true",
                    help="sprawdź, czy przypięty Zig jest obecny")
    args = ap.parse_args()

    exe = zig_exe()
    if args.check:
        if not exe:
            print(f"[brak] Zig {ZIG_VERSION} nie znaleziony w tools/zig/")
            print("       uruchom: python tools/fetch_zig.py")
            return 1
        print(f"[ok] {os.path.relpath(exe, ROOT)}")
        return 0

    if exe:
        print(f"[ok] Zig już obecny: {os.path.relpath(exe, ROOT)}")
        return 0

    host = {
        "win32": "windows", "windows": "windows",
        "linux": "linux", "darwin": "macos",
    }.get(sys.platform, "windows")
    if platform.machine().lower() in ("arm64", "aarch64") and host != "linux":
        host += "-aarch64"
    archive = HOST_TARGET[host]
    expected = ZIG_SHA256.get(archive)
    if not expected:
        print(f"[!] brak przypiętej sumy SHA-256 dla {archive} — odmawiam pobrania")
        return 1
    url = f"https://ziglang.org/download/{ZIG_VERSION}/{archive}"
    print(f"[pobieram] {url}")
    with urllib.request.urlopen(url, timeout=600) as r:
        data = r.read()
    actual = hashlib.sha256(data).hexdigest()
    if actual != expected:
        print(f"[!] SHA-256 się nie zgadza dla {archive}")
        print(f"    oczekiwano: {expected}")
        print(f"    otrzymano : {actual}")
        print("    archiwum odrzucone, nic nie zostało rozpakowane")
        return 1
    print(f"[sha256 ok] {actual}")
    print(f"[{len(data):,} B] rozpakowuję do tools/zig/ ...")
    os.makedirs(DEST, exist_ok=True)
    if archive.endswith(".zip"):
        zipfile.ZipFile(io.BytesIO(data)).extractall(DEST)
    else:
        import tarfile
        with tarfile.open(fileobj=io.BytesIO(data)) as tf:
            tf.extractall(DEST, filter="data")
    exe = zig_exe()
    if not exe:
        print("[!] rozpakowano, ale nie znaleziono pliku zig.exe — sprawdź tools/zig/")
        return 1
    print(f"[ok] {os.path.relpath(exe, ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
