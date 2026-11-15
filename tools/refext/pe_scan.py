#!/usr/bin/env python3
"""
refext/pe_scan.py — statyczny analizator PE dla binariych referencyjnych FerrumScope.

Narzędzie deweloperskie (analiza referencji CPU-Z / GPU-Z). NIE jest częścią
runtime FerrumScope i nie zawiera żadnych danych z cudzych baz.

Użycie:
    python tools/refext/pe_scan.py scan   <plik.exe>
    python tools/refext/pe_scan.py strings <plik.exe> <plik_wyjściowy.txt> [--min 6]
    python tools/refext/pe_scan.py carve   <plik.exe> <katalog_wyjściowy>
    python tools/refext/pe_scan.py version <plik.exe>
"""

from __future__ import annotations

import argparse
import os
import re
import struct
import sys
from dataclasses import dataclass, field

# ---------------------------------------------------------------------------
# Podstawowe struktury PE
# ---------------------------------------------------------------------------

IMAGE_SCN_CNT_CODE = 0x00000020
IMAGE_SCN_CNT_INITIALIZED_DATA = 0x00000040

RESOURCE_TYPES = {
    1: "RT_CURSOR", 2: "RT_BITMAP", 3: "RT_ICON", 4: "RT_MENU",
    5: "RT_DIALOG", 6: "RT_STRING", 7: "RT_FONTDIR", 8: "RT_FONT",
    9: "RT_ACCELERATOR", 10: "RT_RCDATA", 11: "RT_MESSAGETABLE",
    12: "RT_GROUP_CURSOR", 14: "RT_GROUP_ICON", 16: "RT_VERSION",
    17: "RT_DLGINCLUDE", 19: "RT_PLUGPLAY", 20: "RT_VXD",
    21: "RT_ANICURSOR", 22: "RT_ANIICON", 23: "RT_HTML",
    24: "RT_MANIFEST",
}

# Sygnatury wbudowanych kontenerów, które chcemy wyróżnić.
SIGNATURES = {
    b"7z\xbc\xaf\x27\x1c": "7z",
    b"PK\x03\x04": "zip",
    b"Rar!\x1a\x07": "rar",
    b"\xd0\xcf\x11\xe0\xa1\xb1\x1a\xe1": "ole-cfb",
    b"Inno Setup Setup Data": "innosetup",
    b"NullsoftInst": "nsis",
    b"MSCF": "cab",
    b"LZMA": "lzma-raw",
    b"\x1f\x8b": "gzip",
    b"BZh": "bzip2",
}


@dataclass
class Section:
    name: str
    vaddr: int
    vsize: int
    raw_off: int
    raw_size: int
    chars: int

    @property
    def end(self) -> int:
        return self.raw_off + self.raw_size


@dataclass
class PEFile:
    path: str
    data: bytes = field(repr=False)
    machine: int = 0
    is_64: bool = False
    timestamp: int = 0
    image_base: int = 0
    entry_rva: int = 0
    subsystem: int = 0
    sections: list[Section] = field(default_factory=list)
    directories: list[tuple[int, int]] = field(default_factory=list)
    overlay_off: int = 0
    subsystem_names = {
        1: "NATIVE", 2: "WINDOWS_GUI", 3: "WINDOWS_CUI", 7: "POSIX_CUI",
        9: "WINDOWS_CE_GUI", 10: "EFI_APPLICATION", 14: "XBOX",
    }
    machine_names = {
        0x014C: "i386", 0x0166: "r4000", 0x01C0: "ARM", 0x01C4: "ARMNT",
        0x01F0: "POWERPC", 0x0200: "IA64", 0x8664: "AMD64", 0xAA64: "ARM64",
    }

    @property
    def subsystem_name(self) -> str:
        return self.subsystem_names.get(self.subsystem, str(self.subsystem))

    @property
    def machine_name(self) -> str:
        return self.machine_names.get(self.machine, f"0x{self.machine:04x}")


def read_pe(path: str) -> PEFile | None:
    with open(path, "rb") as fh:
        data = fh.read()
    if data[:2] != b"MZ":
        return None
    pe = PEFile(path=path, data=data)
    e_lfanew = struct.unpack_from("<I", data, 0x3C)[0]
    if data[e_lfanew:e_lfanew + 4] != b"PE\x00\x00":
        return None
    coff = e_lfanew + 4
    machine, nsec, ts, _, _, opt_size, chars = struct.unpack_from("<HHIIIHH", data, coff)
    pe.machine = machine
    pe.timestamp = ts
    opt = coff + 20
    magic = struct.unpack_from("<H", data, opt)[0]
    pe.is_64 = magic == 0x20B
    if magic not in (0x10B, 0x20B):
        return None
    if pe.is_64:
        pe.image_base = struct.unpack_from("<Q", data, opt + 24)[0]
        pe.entry_rva = struct.unpack_from("<I", data, opt + 16)[0]
        n_dirs = struct.unpack_from("<I", data, opt + 108)[0]
        dir_off = opt + 112
    else:
        pe.image_base = struct.unpack_from("<I", data, opt + 28)[0]
        pe.entry_rva = struct.unpack_from("<I", data, opt + 16)[0]
        n_dirs = struct.unpack_from("<I", data, opt + 92)[0]
        dir_off = opt + 96
    pe.subsystem = struct.unpack_from("<H", data, opt + 68)[0]
    for i in range(min(n_dirs, 16)):
        rva, size = struct.unpack_from("<II", data, dir_off + i * 8)
        pe.directories.append((rva, size))
    sec_off = opt + opt_size
    for i in range(nsec):
        off = sec_off + i * 40
        name = data[off:off + 8].rstrip(b"\x00").decode("latin-1")
        vsize, vaddr, rsize, roff = struct.unpack_from("<IIII", data, off + 8)
        ch = struct.unpack_from("<I", data, off + 36)[0]
        pe.sections.append(Section(name, vaddr, vsize, roff, rsize, ch))
    pe.overlay_off = max((s.end for s in pe.sections), default=0)
    return pe


def rva_to_off(pe: PEFile, rva: int) -> int | None:
    for s in pe.sections:
        if s.vaddr <= rva < s.vaddr + max(s.vsize, s.raw_size):
            return s.raw_off + (rva - s.vaddr)
    return None


def cstr(data: bytes, off: int, limit: int = 512) -> str:
    end = data.find(b"\x00", off, off + limit)
    if end < 0:
        end = off + limit
    return data[off:end].decode("latin-1", "replace")


# ---------------------------------------------------------------------------
# Katalogi: import / export / resource
# ---------------------------------------------------------------------------

def parse_imports(pe: PEFile) -> list[tuple[str, list[str]]]:
    if len(pe.directories) < 2:
        return []
    rva, size = pe.directories[1]
    if not rva:
        return []
    base = rva_to_off(pe, rva)
    if base is None:
        return []
    out: list[tuple[str, list[str]]] = []
    off = base
    while True:
        fields = struct.unpack_from("<IIIII", pe.data, off)
        oft, ts, fwd, name_rva, ft = fields
        if not any(fields):
            break
        noff = rva_to_off(pe, name_rva)
        dll = cstr(pe.data, noff) if noff else "?"
        funcs: list[str] = []
        thunk_rva = oft or ft
        if thunk_rva:
            toff = rva_to_off(pe, thunk_rva)
            step = 8 if pe.is_64 else 4
            while toff is not None:
                if pe.is_64:
                    val = struct.unpack_from("<Q", pe.data, toff)[0]
                    ordinal_flag = 1 << 63
                else:
                    val = struct.unpack_from("<I", pe.data, toff)[0]
                    ordinal_flag = 1 << 31
                if val == 0:
                    break
                if val & ordinal_flag:
                    funcs.append(f"#{val & 0xFFFF}")
                else:
                    hint = rva_to_off(pe, val & 0x7FFFFFFF)
                    funcs.append(cstr(pe.data, hint + 2) if hint else "?")
                toff += step
        out.append((dll, funcs))
        off += 20
    return out


def parse_resources(pe: PEFile, want_data: bool = False):
    """Zwraca listę węzłów (poziom, typ, nazwa, lang, rva, rozmiar, blob)."""
    if len(pe.directories) < 3:
        return []
    rva, size = pe.directories[2]
    if not rva:
        return []
    base = rva_to_off(pe, rva)
    if base is None:
        return []
    results = []

    def walk(rel: int, depth: int, path: list[str]):
        off = base + rel
        chars, ts, major, minor, named, ids = struct.unpack_from("<IIHHHH", pe.data, off)
        total = named + ids
        for i in range(total):
            eoff = off + 16 + i * 8
            name_id, rva2 = struct.unpack_from("<II", pe.data, eoff)
            if depth == 0:
                if name_id & 0x80000000:
                    no = base + (name_id & 0x7FFFFFFF)
                    nlen = struct.unpack_from("<H", pe.data, no)[0]
                    label = pe.data[no + 2:no + 2 + nlen * 2].decode("utf-16-le", "replace")
                else:
                    label = RESOURCE_TYPES.get(name_id, f"#{name_id}")
            elif name_id & 0x80000000:
                no = base + (name_id & 0x7FFFFFFF)
                nlen = struct.unpack_from("<H", pe.data, no)[0]
                label = pe.data[no + 2:no + 2 + nlen * 2].decode("utf-16-le", "replace")
            else:
                label = str(name_id)
            newpath = path + [label]
            if rva2 & 0x80000000:
                walk(rva2 & 0x7FFFFFFF, depth + 1, newpath)
            else:
                doff = base + rva2
                d_rva, d_size, codepage, _ = struct.unpack_from("<IIII", pe.data, doff)
                fo = rva_to_off(pe, d_rva)
                blob = pe.data[fo:fo + d_size] if fo is not None else b""
                results.append((tuple(newpath), d_rva, d_size, blob if want_data else None))

    walk(0, 0, [])
    return results


def parse_version_info(pe: PEFile) -> dict[str, str]:
    info: dict[str, str] = {}
    for path, rva, size, blob in parse_resources(pe, want_data=True):
        if not path or path[0] != "RT_VERSION":
            continue
        d = blob
        for key in ("FileDescription", "FileVersion", "ProductName", "ProductVersion",
                    "CompanyName", "OriginalFilename", "InternalName", "LegalCopyright"):
            enc = key.encode("utf-16-le")
            idx = d.find(enc)
            if idx < 0:
                continue
            vstart = idx + len(enc)
            vlen = struct.unpack_from("<I", d, vstart)[0]
            val = d[vstart + 4:vstart + 4 + vlen * 2].decode("utf-16-le", "replace").rstrip("\x00")
            info[key] = val
    return info


# ---------------------------------------------------------------------------
# Strings
# ---------------------------------------------------------------------------

def extract_strings(pe_or_bytes, min_len: int = 6) -> list[tuple[int, str, str]]:
    if isinstance(pe_or_bytes, PEFile):
        buf = pe_or_bytes.data
    else:
        buf = pe_or_bytes
    out: list[tuple[int, str, str]] = []
    for m in re.finditer(rb"[\x20-\x7e]{%d,}" % min_len, buf):
        out.append((m.start(), "ascii", m.group().decode("latin-1")))
    # UTF-16LE
    for m in re.finditer(rb"(?:[\x20-\x7e]\x00){%d,}" % min_len, buf):
        out.append((m.start(), "utf16", m.group().decode("utf-16-le")))
    out.sort()
    return out


# ---------------------------------------------------------------------------
# Polecenia
# ---------------------------------------------------------------------------

def cmd_scan(path: str) -> int:
    pe = read_pe(path)
    if pe is None:
        print(f"[!] nie jest to plik PE: {path}")
        return 1
    import datetime
    if pe.timestamp:
        ts = datetime.datetime.fromtimestamp(pe.timestamp, datetime.UTC).isoformat().replace("+00:00", "Z")
    else:
        ts = "?"
    print(f"== {os.path.basename(path)} ==")
    print(f"rozmiar        : {len(pe.data):,} B")
    print(f"machine        : {pe.machine_name}")
    print(f"format         : {'PE32+' if pe.is_64 else 'PE32'}")
    print(f"image base     : 0x{pe.image_base:X}")
    print(f"entry point    : 0x{pe.entry_rva:X}")
    print(f"subsystem      : {pe.subsystem_name}")
    print(f"timestamp      : {ts}")
    print(f"nakładki       : {pe.overlay_off:,} B (overlay {len(pe.data) - pe.overlay_off:,} B)")
    print("\n-- sekcje --")
    for s in pe.sections:
        flags = []
        if s.chars & IMAGE_SCN_CNT_CODE:
            flags.append("CODE")
        if s.chars & IMAGE_SCN_CNT_INITIALIZED_DATA:
            flags.append("IDATA")
        if s.raw_size == 0:
            flags.append("BSS")
        print(f"  {s.name:<10} VA=0x{s.vaddr:08X} VSZ=0x{s.vsize:08X} "
              f"RAW=0x{s.raw_off:08X}+0x{s.raw_size:08X} {','.join(flags)}")

    vi = parse_version_info(pe)
    if vi:
        print("\n-- wersja (VS_VERSIONINFO) --")
        for k, v in vi.items():
            print(f"  {k:<20}: {v}")

    print("\n-- importy --")
    for dll, funcs in parse_imports(pe):
        print(f"  {dll} ({len(funcs)})")
        if len(funcs) <= 40:
            print("      " + ", ".join(funcs))
        else:
            print("      " + ", ".join(funcs[:20]) + ", ...")

    print("\n-- zasoby --")
    res = parse_resources(pe)
    by_type: dict[str, list] = {}
    for path_, rva, size, _ in res:
        t = path_[0]
        by_type.setdefault(t, []).append((path_, size))
    for t, items in sorted(by_type.items(), key=lambda kv: -sum(i[1] for i in kv[1])):
        total = sum(i[1] for i in items)
        print(f"  {t:<20} {len(items):>4} szt., {total:>10,} B")
        # pokaż największe
        for path_, size in sorted(items, key=lambda i: -i[1])[:6]:
            print(f"      {'/'.join(path_):<40} {size:>10,} B")
    return 0


def cmd_version(path: str) -> int:
    pe = read_pe(path)
    if pe is None:
        print("nie PE")
        return 1
    for k, v in parse_version_info(pe).items():
        print(f"{k}={v}")
    return 0


def cmd_strings(path: str, out_path: str, min_len: int) -> int:
    with open(path, "rb") as fh:
        buf = fh.read()
    rows = extract_strings(buf, min_len)
    with open(out_path, "w", encoding="utf-8", newline="\n") as fh:
        for off, enc, s in rows:
            fh.write(f"0x{off:08X}\t{enc}\t{s}\n")
    print(f"{len(rows):,} ciągów -> {out_path}")
    return 0


def cmd_res(path: str, outdir: str, only_type: str | None) -> int:
    pe = read_pe(path)
    if pe is None:
        print("nie PE")
        return 1
    os.makedirs(outdir, exist_ok=True)
    for rpath, rva, size, blob in parse_resources(pe, want_data=True):
        if only_type and rpath[0] != only_type:
            continue
        name = "_".join(x.replace("/", "_") for x in rpath)
        with open(os.path.join(outdir, name + ".bin"), "wb") as fh:
            fh.write(blob)
        head = blob[:8].hex()
        print(f"{name:<32} {size:>10,} B  rva=0x{rva:08X}  head={head}")
    return 0


def cmd_carve(path: str, outdir: str) -> int:
    os.makedirs(outdir, exist_ok=True)
    with open(path, "rb") as fh:
        buf = fh.read()
    found = 0
    for sig, kind in SIGNATURES.items():
        start = 0
        while True:
            idx = buf.find(sig, start)
            if idx < 0:
                break
            start = idx + 1
            print(f"0x{idx:08X}  {kind}")
            found += 1
    # znak sygnatury PE (MZ ... PE\0\0) - wbudowane pliki
    start = 0
    pes = 0
    while True:
        idx = buf.find(b"MZ", start)
        if idx < 0 or idx + 0x40 > len(buf):
            break
        start = idx + 2
        try:
            lfanew = struct.unpack_from("<I", buf, idx + 0x3C)[0]
        except struct.error:
            continue
        if 0 < lfanew < 0x1000 and idx + lfanew + 4 <= len(buf):
            if buf[idx + lfanew:idx + lfanew + 4] == b"PE\x00\x00":
                pes += 1
                print(f"0x{idx:08X}  embedded PE #{pes}")
                name = os.path.join(outdir, f"pe_{pes:02d}_0x{idx:08X}.bin")
                with open(name, "wb") as fh:
                    fh.write(buf[idx:])
    print(f"suma: {found} sygnatur kontenerów, {pes} wbudowanych PE")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("scan")
    p.add_argument("file")
    p = sub.add_parser("version")
    p.add_argument("file")
    p = sub.add_parser("strings")
    p.add_argument("file")
    p.add_argument("out")
    p.add_argument("--min", type=int, default=6)
    p = sub.add_parser("carve")
    p.add_argument("file")
    p.add_argument("outdir")
    p = sub.add_parser("res")
    p.add_argument("file")
    p.add_argument("outdir")
    p.add_argument("--type", default=None)
    args = ap.parse_args()
    if args.cmd == "scan":
        return cmd_scan(args.file)
    if args.cmd == "version":
        return cmd_version(args.file)
    if args.cmd == "strings":
        return cmd_strings(args.file, args.out, args.min)
    if args.cmd == "carve":
        return cmd_carve(args.file, args.outdir)
    if args.cmd == "res":
        return cmd_res(args.file, args.outdir, args.type)
    return 1


if __name__ == "__main__":
    sys.exit(main())
