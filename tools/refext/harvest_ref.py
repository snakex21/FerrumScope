#!/usr/bin/env python3
"""
refext/harvest_ref.py — zbiór *referencyjnych* identyfikatorów sprzętu z binarii CPU-Z / GPU-Z.

WAŻNE (prawnie):
  Wynik tego skryptu NIE jest bazą FerrumScope i nie wolno go dołączać do
  dystrybucji ani do `db/source/`. Trafia do `reference/dumps/` — katalogu
  „quarantine”, który istnieje wyłącznie po to, by:
    * zweryfikować nasze dekodery i testy regresyjne („czy zgadzamy się z oracle?"),
    * zobaczyć, jakich SKU brakuje w naszej bazie,
    * porównać kompletność i pokrycie.
  Właściwe źródła danych FerrumScope: `tools/hwdb/pciids_import.py` (publiczne
  pci.ids), dokumentacja producentów oraz capture'y .fcap użytkowników.
  Każdy wpis w bazie FerrumScope musi mieć pole `source` (provenance).

Użycie:
    python tools/refext/harvest_ref.py --all
    python tools/refext/harvest_ref.py --gpuz
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pe_scan  # noqa: E402

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
REF_DIR = os.path.join(ROOT, "do referencji")
PROBE_DIR = os.path.join(ROOT, "tools", "refext", "_probe")
DUMP_DIR = os.path.join(ROOT, "reference", "dumps")

BANNER = (
    "QUARANTINE — dane wyłącznie do analizy porównawczej. NIE do dystrybucji, "
    "NIE do db/source/. Pochodne binariów CPUID/CPU-Z oraz TechPowerUp/GPU-Z."
)

TARGETS = {
    "cpuz": os.path.join(REF_DIR, "cpuz", "cpuz_x64.exe"),
    "gpuz": os.path.join(REF_DIR, "gpuz", "GPU-Z.2.71.0.exe"),
}

# Klasyfikatory. Kolejność ma znaczenie — pierwsze trafienie wygrywa.
RULES: list[tuple[str, re.Pattern]] = [
    # --- CPU ---------------------------------------------------------------
    ("cpu.marketing", re.compile(
        r"(Intel\(R\)\s*(?:Core|Xeon|Pentium|Celeron)|AMD\s*(?:Ryzen|EPYC|Athlon|"
        r"Sempron|FX)|Ryzen\s+\d|Core\s+[iI]?[3579](?:-|\s)|Xeon\s+[WES]?\d{3,4})")),
    ("cpu.format", re.compile(r"%\d?d|%\d?s")),
    ("cpu.brand", re.compile(r"^(GenuineIntel|AuthenticAMD|CentaurHauls|Intel\(R\)|"
                             r"AMD|HygonGenuine|VMwareVMware|VirtualCPU|KVMKVMKVM)$")),
    # --- GPU ---------------------------------------------------------------
    ("gpu.chip", re.compile(r"^(Navi\s*\d{1,2}|AD\d{3,4}|GB\d{3,4}|GN\d{3,4}|GA\d{3,4}|"
                            r"GH\d{3,4}|G[A-Z]?\d{2,3}|TU\d{3}|PHX|ADL|ARL|BRK)$")),
    ("gpu.model", re.compile(r"^(?:Radeon\s+)?(?:RX\s+\d{4}|RTX\s+\d{4,5}|GTX\s+\d{3,4}|"
                             r"GT\s+\d{3,4}|Quadro\s+[A-Z0-9]+|Arc\s+[A-Z]\d{3}|"
                             r"Radeon\s+Pro\s+[A-Z0-9]+|HD\s+\d{4})$")),
    ("gpu.vendor_api", re.compile(r"^(NVAPI|ADL|I2C|ADL_.*|IGCL|OCL|AMDOLED|AMDM|"
                                  r"NVCPL|NVML|atiadl|ADLX)$")),
    # --- Inferfejsy systemowe / dostęp do sprzętu --------------------------
    ("io.device_path", re.compile(r"^\\\\\.\\|^\\\\\?\\|^\Device\\|^\\\\\.\\pipe\\")),
    ("io.api", re.compile(r"^(SetupDi[A-Z]\w+|CM_\w+|DeviceIoControl|CreateFileW?|"
                          r"ReadFile|WriteFile|PhysicalDrive\d+|\\\\\.\\DISPLAY)$")),
    ("io.vendor_func", re.compile(r"(ADL_Display_\w+|ADLX_\w+|nvapi\w*|NVCPL\w*)")),
    # --- Formaty surowych identyfikatorów ----------------------------------
    ("raw.id_format", re.compile(r"0x%0?4[Xx]|0x%0?2[Xx]")),
    ("raw.pci_tuple", re.compile(r"vendor.*0x%04[Xx].*device|device 0x%04[Xx]")),
]

# Ciągi, które są oczywistym szumem binarnym / komunikatami API, nie danymi sprzętu.
STOP = re.compile(
    r"^(Get|Set|Create|Open|Close|Read|Write|Enable|Disable|Register|Unregister|"
    r"Initialize|Query|Enum|Find|Load|Free|Alloc|Release|Delete|Add|Remove|Insert|"
    r"this |The |Cannot |Failed|Error|Warning|Usage|Invalid|Unexpected|Microsoft|"
    r"[A-Za-z]+32$)", re.I)


def classify(s: str) -> str | None:
    if len(s) < 3 or len(s) > 120:
        return None
    if STOP.match(s):
        return None
    for kind, rx in RULES:
        if rx.search(s):
            return kind
    return None


def find_upx() -> list[str]:
    """Szuka lokalnie pobranego UPX-a (GPL, pobierany przez tools/refext/fetch_tools.sh)."""
    cands = ["upx"]
    bindir = os.path.join(ROOT, "tools", "refext", "bin")
    if os.path.isdir(bindir):
        for dirpath, _dirs, files in os.walk(bindir):
            for f in files:
                if f.lower() == "upx.exe":
                    cands.append(os.path.join(dirpath, f))
    return cands


def looks_packed(path: str) -> bool:
    """Czy plik wygląda na spakowany UPX-em? (nagłówek 'UPX!' lub sekcje UPX0/UPX1)"""
    with open(path, "rb") as fh:
        head = fh.read(0x400)
    if b"UPX!" in head:
        return True
    pe = pe_scan.read_pe(path)
    if pe is None:
        return False
    names = {s.name.upper() for s in pe.sections}
    return "UPX0" in names or "UPX1" in names


def upx_unpack(path: str) -> str:
    """Rozpakowuje kopię referencyjną UPX-em; zwraca ścieżkę do rozpakowanego pliku."""
    os.makedirs(PROBE_DIR, exist_ok=True)
    out = os.path.join(PROBE_DIR, os.path.basename(path) + ".unpacked.exe")
    if os.path.exists(out) and os.path.getsize(out) > os.path.getsize(path):
        return out
    if not looks_packed(path):
        # UPX zwraca błąd na pliku niepakowanym — to nie jest brak narzędzia.
        return path
    for cand in find_upx():
        try:
            subprocess.run([cand, "-d", "-o", out, path], check=True,
                           capture_output=True, timeout=300)
            print(f"[upx] rozpakowano do {os.path.relpath(out, ROOT)}")
            return out
        except (OSError, subprocess.CalledProcessError):
            continue
    print("[upx] plik jest spakowany, ale UPX-a nie znaleziono — wyniki będą niepełne; "
          "pobierz narzędzie: tools/refext/fetch_tools.sh")
    return path


def harvest(path: str, unpack: bool = True) -> dict:
    target = upx_unpack(path) if unpack else path
    pe = pe_scan.read_pe(target)
    with open(target, "rb") as fh:
        buf = fh.read()
    strings = pe_scan.extract_strings(buf, 5)

    buckets: dict[str, list[dict]] = {}
    for off, enc, s in strings:
        kind = classify(s.strip())
        if kind is None:
            continue
        buckets.setdefault(kind, []).append({"value": s.strip(), "enc": enc, "off": hex(off)})

    # deduplikacja po wartości (bez offsetu) + limit per bucket
    result: dict[str, list[dict]] = {}
    for kind, items in sorted(buckets.items()):
        seen: dict[str, dict] = {}
        for it in items:
            seen.setdefault(it["value"], it)
        result[kind] = list(seen.values())[:2000]

    return {
        "source_binary": os.path.relpath(path, ROOT).replace("\\", "/"),
        "analysed_binary": os.path.relpath(target, ROOT).replace("\\", "/"),
        "binary_size": len(buf),
        "packed": target != path,
        "machine": pe.machine_name if pe else "?",
        "is_64": pe.is_64 if pe else False,
        "sections": [{"name": s.name, "raw_off": s.raw_off, "raw_size": s.raw_size,
                      "vaddr": s.vaddr, "vsize": s.vsize} for s in pe.sections] if pe else [],
        "imports": {dll: fns for dll, fns in (pe_scan.parse_imports(pe) if pe else [])},
        "version_info": pe_scan.parse_version_info(pe) if pe else {},
        "notice": BANNER,
        "counts": {k: len(v) for k, v in result.items()},
        "values": result,
    }


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--all", action="store_true")
    ap.add_argument("--cpuz", action="store_true")
    ap.add_argument("--gpuz", action="store_true")
    ap.add_argument("--no-unpack", action="store_true")
    args = ap.parse_args()
    which = [k for k, f in (("cpuz", args.cpuz), ("gpuz", args.gpuz)) if f]
    if args.all or not which:
        which = list(TARGETS)

    os.makedirs(DUMP_DIR, exist_ok=True)
    for key in which:
        src = TARGETS[key]
        if not os.path.exists(src):
            print(f"[!] brak pliku: {src}")
            continue
        data = harvest(src, unpack=not args.no_unpack)
        out = os.path.join(DUMP_DIR, f"{key}.json")
        with open(out, "w", encoding="utf-8", newline="\n") as fh:
            json.dump(data, fh, indent=1, ensure_ascii=False)
        total = sum(data["counts"].values())
        print(f"{key}: {os.path.relpath(out, ROOT)}  pakowane={data['packed']} "
              f"ciągi={total}  {data['counts']}")
    print("-" * 70)
    print(BANNER)
    return 0


if __name__ == "__main__":
    sys.exit(main())
