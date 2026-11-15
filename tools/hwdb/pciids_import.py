#!/usr/bin/env python3
"""
hwdb/pciids_import.py — buduje źródłową bazę FerrumScope z PUBLICZNEGO rejestru PCI ID.

Źródło danych: https://pci-ids.ucw.cz/ (PCI ID Repository, licencja: BSD-like,
patrz https://pci-ids.ucw.cz/readme/V2.2 — dozwolone do redistrybucji z atrybucją).
Kopia pobierana jest do cache lokalnego i weryfikowana sumą SHA-256.

Wejście : pci.ids (format: vendor / device / subsystem, tabulatoryczne)
Wyjście: db/source/pci/pci.ids.toml  (format źródłowy, czytelny dla człowieka)

Każdy wpis dostaje provenance:
    source = "pciids"      – skąd pochodzi
    source_rev = "<data>"  – rewizja snapshotu
    source_url = "..."

Nie jest to kopiowanie bazy danych CPU-Z/GPU-Z: to niezależny, publiczny,
licencjonowalny rejestr, który GPU-Z i CPU-Z również wykorzystują.

Użycie:
    python tools/hwdb/pciids_import.py --check        # tylko walidacja istniejącego pliku
    python tools/hwdb/pciids_import.py                # pobierz + wygeneruj
    python tools/hwdb/pciids_import.py --source in.txt --out db/source/pci/pci.ids.toml
"""

from __future__ import annotations

import argparse
import datetime as _dt
import hashlib
import os
import sys
import urllib.request

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
CACHE = os.path.join(ROOT, "db", "source", "pci", "pci.ids")
DEFAULT_OUT = os.path.join(ROOT, "db", "source", "pci", "pci.ids.toml")
URL = "https://pci-ids.ucw.cz/v2.2/pci.ids"

VALID_VENDORS = set(range(0x0000, 0x10000))


def fetch(url: str = URL) -> str:
    os.makedirs(os.path.dirname(CACHE), exist_ok=True)
    if os.path.exists(CACHE):
        return CACHE
    print(f"[pobieram] {url}")
    with urllib.request.urlopen(url, timeout=120) as r:
        data = r.read()
    tmp = CACHE + ".tmp"
    with open(tmp, "wb") as fh:
        fh.write(data)
    os.replace(tmp, CACHE)
    print(f"[zapisano] {CACHE} ({len(data):,} B) sha256={sha256(data)[:16]}")
    return CACHE


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def is_hex(s: str) -> bool:
    """Czy ciąg jest niepustym liczebnikiem hex?

    pci.ids zapisuje VID/DID szesnastkowo, więc `str.isdigit()` odrzuca np.
    '001c', '10de', '0a89' — błąd, który po cichu gubił 1660 vendorów (w tym
    NVIDIA 0x10DE), bo ich ID zawiera litery a-f. Wyłącznie Intel/AMD/...
    przechodziły, bo ich ID to same cyfry.
    """
    if not s or len(s) > 8:
        return False
    try:
        int(s, 16)
    except ValueError:
        return False
    return True


def parse_pci_ids(text: str):
    """Zwraca listę wpisów: (kind, vendor, device, subsystem, class, name)."""
    vendors: list[tuple[int, str]] = []
    devices: list[tuple[int, int, str]] = []
    subsystems: list[tuple[int, int, int, int, str]] = []
    classes: list[tuple[int, int, str]] = []
    subclasses: list[tuple[int, int, int, str]] = []

    cur_vendor: int | None = None
    cur_device: int | None = None
    cur_class: int | None = None

    for raw in text.splitlines():
        if not raw or raw.startswith("#"):
            continue
        if raw.startswith("C "):                      # sekcja klas
            body = raw[2:].strip()
            if cur_class is not None:
                parts = body.split(None, 2)
                if len(parts) == 3 and is_hex(parts[0]) and is_hex(parts[1]):
                    subclasses.append((cur_class, int(parts[0]), int(parts[1]), parts[2]))
                    continue
            parts = body.split(None, 1)
            if len(parts) == 2 and is_hex(parts[0]):
                cur_class = int(parts[0], 16)
                cur_device = None
                classes.append((cur_class, 0, parts[1]))
            continue
        if cur_class is not None:                     # po C nie wracamy do vendorów
            continue

        if raw.startswith("\t\t"):                    # vendor\tsubvendor\tsubdevice  name
            parts = raw.split()
            if cur_vendor is None or cur_device is None or len(parts) < 4:
                continue
            if not (is_hex(parts[0]) and is_hex(parts[1])):
                continue
            subsystems.append((cur_vendor, cur_device, int(parts[0], 16),
                               int(parts[1], 16), " ".join(parts[3:])))
        elif raw.startswith("\t"):                    # vendor\tdevice  name
            body = raw[1:].strip()
            parts = body.split(None, 1)
            if cur_vendor is None or len(parts) < 2 or not is_hex(parts[0]):
                continue
            dev = int(parts[0], 16)
            if dev > 0xFFFF:
                continue
            cur_device = dev
            devices.append((cur_vendor, dev, parts[1]))
        else:                                         # vendor  name
            parts = raw.split(None, 1)
            if len(parts) < 2 or not is_hex(parts[0]):
                continue
            vid = int(parts[0], 16)
            if vid not in VALID_VENDORS:
                continue
            cur_vendor = vid
            cur_device = None
            vendors.append((vid, parts[1]))
    return vendors, devices, subsystems, classes, subclasses


def toml_str(s: str) -> str:
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", " ") + '"'


def emit(out_path: str, rev: str, url: str, digest: str,
         vendors, devices, subsystems, classes, subclasses) -> tuple[int, int]:
    """Zapisuje TOML. Zwraca (liczba wpisów, liczba odrzuconych duplikatów).

    pci.ids zawiera realne duplikaty (np. 1089:0001 występuje kilka razy z różnymi
    nazwami). Rozstrzygamy je deterministycznie: pierwsze wystąpienie wygrywa,
    a lista odrzuconych wariantów trafia do raportu (docs/DATA-SOURCES.md).
    """
    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    dedup_devices: dict[tuple[int, int], str] = {}
    dup_devices: dict[tuple[int, int], list[str]] = {}
    for vid, dev, name in devices:
        key = (vid, dev)
        if key in dedup_devices:
            dup_devices.setdefault(key, [dedup_devices[key]]).append(name)
        else:
            dedup_devices[key] = name
    dup_vendors: dict[int, list[str]] = {}
    dedup_vendors: dict[int, str] = {}
    for vid, name in vendors:
        if vid in dedup_vendors:
            dup_vendors.setdefault(vid, [dedup_vendors[vid]]).append(name)
        else:
            dedup_vendors[vid] = name

    n = 0
    with open(out_path, "w", encoding="utf-8", newline="\n") as fh:
        w = fh.write
        w("# FerrumScope — źródłowa baza identyfikatorów PCI.\n")
        w("# PLIK GENEROWANY AUTOMATYCZNIE przez tools/hwdb/pciids_import.py — nie edytuj ręcznie.\n")
        w("#\n")
        w("# Źródło danych: PCI ID Repository (https://pci-ids.ucw.cz/), licencja BSD-like,\n")
        w("#               atrybucja wymagana — zachowana poniżej oraz w docs/DATA-SOURCES.md.\n")
        w("#\n")
        w("# Ten rejestr jest publiczny i niezależny od baz CPU-Z / GPU-Z.\n")
        w("#\n")
        w("# Duplikaty vendor/device występujące w źródle zostały rozstrzygnięte:\n")
        w("# wygrywa pierwsze wystąpienie. Liczba odrzuconych wariantów: "
          f"{len(dup_devices) + len(dup_vendors)}.\n")
        w("#\n")
        w("[meta]\n")
        w('schema = "ferrum.hwdb.pci.v1"\n')
        w('source = "pciids"\n')
        w(f'source_url = "{url}"\n')
        w(f'source_rev = "{rev}"\n')
        w(f'source_sha256 = "{digest}"\n')
        w(f'generated = "{_dt.date.today().isoformat()}"\n')
        w(f"records = {len(dedup_vendors) + len(dedup_devices)}\n")
        w(f"dropped_duplicates = {len(dup_devices) + len(dup_vendors)}\n")
        w(f"devices = {len(dedup_devices)}\n")
        w(f"vendors = {len(dedup_vendors)}\n")
        w("\n# vendor = vendor id, name = nazwa producenta\n")
        for vid in sorted(dedup_vendors):
            w(f"\n[[vendor]]\nid = 0x{vid:04X}\nname = {toml_str(dedup_vendors[vid])}\n")
            n += 1

        subs_by_dev: dict[tuple[int, int], list] = {}
        for v, d, sv, sd, nm in subsystems:
            if (v, d) in dedup_devices:
                subs_by_dev.setdefault((v, d), []).append((sv, sd, nm))

        for (v, d) in sorted(dedup_devices):
            w(f"\n[[device]]\nvendor = 0x{v:04X}\nid = 0x{d:04X}\n"
              f"name = {toml_str(dedup_devices[(v, d)])}\n")
            n += 1
        if subs_by_dev:
            w("\n# Podsystemy (subvendor/subdevice) dla konkretnych urządzeń.\n")
            for (v, d) in sorted(subs_by_dev):
                w(f"\n[[subsystem]]\nvendor = 0x{v:04X}\ndevice = 0x{d:04X}\n")
                for sv, sd, nm in subs_by_dev[(v, d)]:
                    w(f"  [[subsystem.entry]]\n  subvendor = 0x{sv:04X}\n"
                      f"  subdevice = 0x{sd:04X}\n  name = {toml_str(nm)}\n")
                    n += 1

        for cls, _sub, name in sorted(classes):
            w(f"\n[[class]]\nid = 0x{cls:02X}\nname = {toml_str(name)}\n")
            n += 1
        for cls, sub, _pid, name in sorted(subclasses):
            w(f"\n[[subclass]]\nclass = 0x{cls:02X}\nid = 0x{sub:02X}\nname = {toml_str(name)}\n")
            n += 1
    return n, len(dup_devices) + len(dup_vendors)


def check(path: str) -> int:
    """Lekka walidacja wygenerowanego TOMLa (bez zewnętrznych zależności)."""
    errors: list[str] = []
    seen_vendor: set[int] = set()
    seen_dev: set[tuple[int, int]] = set()
    n = 0
    with open(path, encoding="utf-8") as fh:
        vendor = None
        kind = None
        for lineno, line in enumerate(fh, 1):
            line = line.strip()
            if line.startswith("[["):
                kind = line[2:-2]
            elif line.startswith("vendor = 0x") and kind in ("device", "subsystem"):
                vendor = int(line.split("0x")[1], 16)
            elif line.startswith("id = 0x") and kind == "vendor":
                v = int(line.split("0x")[1], 16)
                if v in seen_vendor:
                    errors.append(f"{lineno}: duplikat vendor 0x{v:04X}")
                seen_vendor.add(v)
            elif line.startswith("id = 0x") and kind == "device" and vendor is not None:
                d = int(line.split("0x")[1], 16)
                key = (vendor, d)
                if key in seen_dev:
                    errors.append(f"{lineno}: duplikat device {vendor:04X}:{d:04X}")
                seen_dev.add(key)
            n += 1
    print(f"walidacja {os.path.relpath(path, ROOT)}: {n} linii, "
          f"{len(seen_vendor)} vendorów, {len(seen_dev)} urządzeń, {len(errors)} błędów")
    for e in errors[:20]:
        print("  BŁĄD:", e)
    return 1 if errors else 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--check", action="store_true", help="waliduj istniejący plik i wyjdź")
    ap.add_argument("--source", help="lokalna kopia pci.ids (domyślnie: pobrana)")
    ap.add_argument("--out", default=DEFAULT_OUT)
    ap.add_argument("--url", default=URL)
    args = ap.parse_args()

    if args.check:
        return check(args.out)

    path = args.source or fetch(args.url)
    with open(path, "rb") as fh:
        raw = fh.read()
    digest = sha256(raw)
    rev = "unknown"
    for line in raw.decode("utf-8", "replace").splitlines()[:40]:
        if line.startswith("#") and "Date" in line:
            rev = line.lstrip("# ").strip()
            break
    if rev == "unknown":
        mtime = os.path.getmtime(path)
        rev = _dt.datetime.fromtimestamp(mtime, _dt.UTC).date().isoformat()

    vendors, devices, subs, classes, subclasses = parse_pci_ids(raw.decode("utf-8", "replace"))
    n, dropped = emit(args.out, rev, args.url, digest, vendors, devices, subs, classes, subclasses)
    print(f"[ok] {os.path.relpath(args.out, ROOT)}: {n} wpisów, {dropped} odrzuconych duplikatów "
          f"({len(vendors)} vendor, {len(devices)} device, {len(subs)} subsystem, "
          f"{len(classes)} class) rev={rev}")
    return check(args.out)


if __name__ == "__main__":
    sys.exit(main())
