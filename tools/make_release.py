#!/usr/bin/env python3
"""
make_release.py — składa artefakty wydania FerrumScope (używane przez
.github/workflows/release.yml, można uruchomić też lokalnie).

Wynik w katalogu --out:
    FerrumScope-<wersja>-windows-x64.zip   wersja przenośna (bez .pdb)
    ferrumscope-update.json                manifest dla aktualizatora
    SHA256SUMS                             sumy zip i manifestu (format sha256sum)
Notatki wydania (sekcja CHANGELOG.md) trafiają do --notes-out (poza --out,
żeby nie zostały wysłane jako plik wydania).

Manifest musi przejść tę samą walidację co src/update/manifest.zig: adres
https://github.com/snakex21/FerrumScope/releases/download/v<wersja>/<zip>,
sha256 = 64 znaki hex, 0 < size < 200 MB. Wersja musi być równa
`version` w src/present.zig — inaczej program po aktualizacji uważałby się
za starszy niż wydanie i proponował ją w kółko.

Użycie:
    python tools/make_release.py --check-version 0.2.0
    python tools/make_release.py --version 0.2.0 --bin zig-out/bin --out dist --notes-out release-notes.md
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import re
import sys
import zipfile

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
REPO = "snakex21/FerrumScope"
MAX_SIZE = 200 * 1024 * 1024
MAX_NOTES = 16 * 1024

SEMVER = re.compile(r"^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(-[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?$")

# (ścieżka w archiwum, źródło: "bin" = katalog --bin, "root" = katalog repozytorium)
FILES = [
    ("ferrumscope.exe", "bin"),
    ("ferrumscope-gui.exe", "bin"),
    ("LICENSE", "root"),
    ("NOTICE.md", "root"),
    ("README.md", "root"),
    ("CHANGELOG.md", "root"),
    ("assets/logos/SOURCES.md", "root"),
]


def present_version() -> str:
    with open(os.path.join(ROOT, "src", "present.zig"), encoding="utf-8") as f:
        m = re.search(r'^pub const version = "([^"]+)";', f.read(), re.M)
    if not m:
        raise SystemExit("[!] nie znaleziono `pub const version` w src/present.zig")
    return m.group(1)


def check_version(version: str) -> None:
    if not SEMVER.match(version):
        raise SystemExit(f"[!] wersja '{version}' nie jest poprawną wersją SemVer (bez 'v' i bez '+build')")
    pv = present_version()
    if pv != version:
        raise SystemExit(f"[!] tag v{version} != src/present.zig version \"{pv}\" — popraw present.zig przed wydaniem")
    print(f"[ok] wersja {version} zgodna z src/present.zig")


def changelog_notes(version: str) -> str:
    with open(os.path.join(ROOT, "CHANGELOG.md"), encoding="utf-8") as f:
        text = f.read()
    m = re.search(r"^## \[?" + re.escape(version) + r"\]?[^\n]*\n(.*?)(?=^## |\Z)", text, re.M | re.S)
    notes = m.group(1).strip() if m else ""
    if len(notes.encode("utf-8")) > MAX_NOTES:
        notes = notes.encode("utf-8")[: MAX_NOTES - 64].decode("utf-8", "ignore").rstrip() + "\n\n(…pełna lista w CHANGELOG.md)"
    return notes


def sha256_file(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def build(version: str, bin_dir: str, out_dir: str, notes_out: str | None) -> None:
    check_version(version)
    os.makedirs(out_dir, exist_ok=True)
    zip_name = f"FerrumScope-{version}-windows-x64.zip"
    zip_path = os.path.join(out_dir, zip_name)
    # Stała data wpisów: archiwum zależy tylko od zawartości plików.
    stamp = (2020, 1, 1, 0, 0, 0)
    with zipfile.ZipFile(zip_path, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as z:
        for arc, src in FILES:
            base = bin_dir if src == "bin" else ROOT
            path = os.path.join(base, *arc.split("/")) if src == "root" else os.path.join(base, arc)
            if not os.path.isfile(path):
                raise SystemExit(f"[!] brak pliku {path}")
            info = zipfile.ZipInfo(arc, date_time=stamp)
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o644 << 16
            with open(path, "rb") as f:
                z.writestr(info, f.read())
    with zipfile.ZipFile(zip_path) as z:
        names = z.namelist()
        bad = z.testzip()
    if bad is not None or any(n.endswith(".pdb") for n in names):
        raise SystemExit(f"[!] archiwum niepoprawne ({bad}) albo zawiera .pdb: {names}")

    size = os.path.getsize(zip_path)
    if not 0 < size < MAX_SIZE:
        raise SystemExit(f"[!] rozmiar archiwum {size} poza zakresem")
    digest = sha256_file(zip_path)
    notes = changelog_notes(version)
    manifest = {
        "version": version,
        "url": f"https://github.com/{REPO}/releases/download/v{version}/{zip_name}",
        "sha256": digest,
        "size": size,
        "notes": notes,
        "published": dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    }
    manifest_path = os.path.join(out_dir, "ferrumscope-update.json")
    with open(manifest_path, "w", encoding="utf-8", newline="\n") as f:
        json.dump(manifest, f, ensure_ascii=False, indent=2)
        f.write("\n")
    with open(os.path.join(out_dir, "SHA256SUMS"), "w", encoding="utf-8", newline="\n") as f:
        f.write(f"{digest}  {zip_name}\n")
        f.write(f"{sha256_file(manifest_path)}  ferrumscope-update.json\n")
    if notes_out:
        with open(notes_out, "w", encoding="utf-8", newline="\n") as f:
            f.write((notes or f"FerrumScope {version}") + "\n")
    print(f"[ok] {zip_name}  {size} B  sha256 {digest}")
    print(f"[ok] {', '.join(names)}")


def main() -> int:
    # Konsola Windows (cp1252/cp1250) nie zawsze zna polskie znaki — nie przerywaj z tego powodu.
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(errors="replace")
        except (AttributeError, ValueError):
            pass
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--check-version", metavar="WERSJA", help="tylko sprawdź zgodność z src/present.zig")
    ap.add_argument("--version")
    ap.add_argument("--bin", default=os.path.join(ROOT, "zig-out", "bin"))
    ap.add_argument("--out", default=os.path.join(ROOT, "dist"))
    ap.add_argument("--notes-out")
    a = ap.parse_args()
    if a.check_version:
        check_version(a.check_version)
        return 0
    if not a.version:
        ap.error("wymagane --version albo --check-version")
    build(a.version, a.bin, a.out, a.notes_out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
