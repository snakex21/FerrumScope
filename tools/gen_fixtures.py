#!/usr/bin/env python3
"""
gen_fixtures.py — generuje pliki testowe `db/fixtures/*.cpuimg`.

WAŻNE O PROWODENIU DANYCH
------------------------
To są **ręcznie skonstruowane obrazy referencyjne**, a nie zrzuty z prawdziwego
sprzętu. Powstały z publicznych sygnatur CPUID opisanych w Intel SDM oraz
AMD APM. Zapisujemy je jawnie, żeby:
  * testy nie wymagały konkretnej maszyny,
  * liczby w nich były sprawdzalne i stabilne,
  * nikt nie mylił ich z „danymi z mojego laptopa".

Sygnatury (rodzina / model / stepping) odpowiadają realnym pokoleniom:
  E6600       Intel  Family 6 Model 0x16  (Conroe, 2006)
  i9-13900K   Intel  Family 6 Model 0xB7  (Raptor Lake, 2022)
  Athlon 64   AMD    Family 15  Model 0x02 (K8 Hammer, 2004)
  5800X       AMD    Family 19  Model 0x21 (Vermeer, Zen 3, 2020)
  unknown     producent spoza listy + brak brand stringu

Użycie:  python tools/gen_fixtures.py
"""

from __future__ import annotations

import os
import struct

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
OUT = os.path.join(ROOT, "db", "fixtures")

VENDORS = {
    "GenuineIntel": (0x756E6547, 0x49656E69, 0x6C65746E),
    "AuthenticAMD": (0x68747541, 0x69746E65, 0x444D4163),
    "FerrumTestCo": (0x4F637477, 0x6D756874, 0x6F725465),  # "TwCom" / "tumho" / "orTe"
}


def brand_leaves(text: str) -> list[tuple[int, int, int, int]]:
    """Rozbija 48-bajtowy brand string na 3 liścia CPUID (EAX,EBX,ECX,EDX)."""
    b = text.encode("ascii")
    if len(b) > 47:  # 48 bajtów z NUL-em zamykającym
        raise ValueError(f"brand string za długi: {len(b)} B")
    b = b + b"\x00" * (48 - len(b))
    out = []
    for i in range(3):
        chunk = b[i * 16:(i + 1) * 16]
        vals = struct.unpack("<IIII", chunk)
        out.append(vals)
    return out


def cache_leaf(level: int, kind: int, size_kb: int, ways: int, line: int,
               sharing: int, cores: int) -> tuple[int, int, int, int]:
    """Buduje wpis deterministic cache parameters (leaf 4 / 0x8000001D)."""
    per_set = ways * line
    total = size_kb * 1024
    if total % per_set:
        raise ValueError(f"rozmiar {size_kb} KiB nie dzieli się przez {per_set} B")
    sets = total // per_set
    eax = (level << 5) | kind
    ebx = ((ways - 1) << 22) | (0 << 12) | (line - 1)  # partitions = 1
    ecx = sets - 1
    edx = ((cores - 1) << 14) | (sharing - 1)
    return eax, ebx, ecx, edx


def leaf(leaf_id: int, subleaf: int, regs: tuple[int, int, int, int]) -> str:
    e, b, c, d = regs
    return (f"leaf 0x{leaf_id:X} sub 0x{subleaf:X} "
            f"eax=0x{e:08X} ebx=0x{b:08X} ecx=0x{c:08X} edx=0x{d:08X}")


def signature(extended_family: int, family_field: int, ext_model: int,
              model_field: int, stepping: int) -> int:
    return ((extended_family & 0xFF) << 20) | ((ext_model & 0xF) << 16) | \
           ((family_field & 0xF) << 8) | ((model_field & 0xF) << 4) | (stepping & 0xF)


def render(name: str, header_comments: list[str], vendor: str, max_basic: int,
           max_extended: int, sig: int, logical: int, features: tuple[int, int, int, int],
           caches: list[tuple[int, int, int, int, int, int]], brand: str | None,
           leaf_b: int | None = None, ext_8000001e: int | None = None,
           amd_cache_leaf: bool = False,
           intel_cache_leaf: bool = True,
           leaf_b_shift: int = 0) -> str:
    lines: list[str] = []
    lines.append(f"# FerrumScope — obraz referencyjny: {name}")
    for c in header_comments:
        lines.append(f"# {c}")
    lines.append("# Ręcznie skonstruowany obraz CPUID (tools/gen_fixtures.py),")
    lines.append("# oparty na publicznych sygnaturach Intel SDM / AMD APM.")
    lines.append(f"ferrum-cpuimg 1")
    lines.append("arch x86_64")
    lines.append(f"max_basic 0x{max_basic:X}")
    lines.append(f"max_extended 0x{max_extended:X}")
    lines.append("")

    bx, dx, cx = VENDORS[vendor]
    lines.append(leaf(0, 0, (max_basic, bx, cx, dx)))

    # Kolejność krotek: (leaf1.EDX, leaf1.ECX, leaf7.EBX, leaf7.EDX)
    # Uwaga: SSE3/SSSE3/SSE4.x/AES/AVX siedzą w ECX, a nie w EDX.
    f_edx, f_ecx, f_ebx7, f_edx7 = features
    ebx_leaf1 = logical << 16
    lines.append(leaf(1, 0, (sig, ebx_leaf1, f_ecx, f_edx)))

    # leaf 4 — deterministic cache parameters. Zen 3 zwraca tu EAX = 0
    # (liść nieobsługiwany), więc dla AMD go nie generujemy — inaczej ten sam
    # cache trafiłby na listę dwa razy: raz z liścia 4, raz z 0x8000001D.
    if caches and intel_cache_leaf:
        for i, (lvl, kind, size, ways, line, sharing, cores) in enumerate(caches):
            lines.append(leaf(4, i, cache_leaf(lvl, kind, size, ways, line, sharing, cores)))
        lines.append(leaf(4, len(caches), (0, 0, 0, 0)))
    if caches and amd_cache_leaf:
        for i, (lvl, kind, size, ways, line, sharing, cores) in enumerate(caches):
            lines.append(leaf(0x8000001D, i,
                              cache_leaf(lvl, kind, size, ways, line, sharing, cores)))
        lines.append(leaf(0x8000001D, len(caches), (0, 0, 0, 0)))

    # leaf 7 — extended features
    if max_basic >= 7:
        lines.append(leaf(7, 0, (0, f_ebx7, 0, f_edx7)))
        lines.append(leaf(7, 1, (0, 0, 0, 0)))

    # Leaf 0x0B: poziom SMT. EAX = liczba bitów przesunięcia (2^EAX = wątki na
    # rdzeń), EBX = liczba logicznych procesorów na tym poziomie.
    # Zen 3 zwraca tu same zera (EBX = 0), bo topologię podaje w 0x8000001E —
    # dlatego `leaf_b = 0` znaczy „liść istnieje, ale nic nie mówi".
    if leaf_b is not None:
        shift = leaf_b_shift or 0
        lines.append(leaf(0x0B, 0, (shift, leaf_b, (1 << 8), 0)))
        if leaf_b != 0:
            lines.append(leaf(0x0B, 1, (0, leaf_b // 2, (2 << 8), 0)))
        lines.append(leaf(0x0B, 2, (0, 0, 0, 0)))

    lines.append(leaf(0x80000000, 0, (max_extended, 0, 0, 0)))
    lines.append(leaf(0x80000001, 0, (0, 0, 0, 0)))
    if ext_8000001e is not None:
        lines.append(leaf(0x8000001E, 0, (ext_8000001e, 0, 0, 0)))

    if brand:
        for i, regs in enumerate(brand_leaves(brand)):
            lines.append(leaf(0x80000002 + i, 0, regs))

    return "\n".join(lines) + "\n"


# --- Zbiory flag CPUID ------------------------------------------------------
# (leaf1.edx, leaf1.ecx, leaf7.ebx, leaf7.ecx)
F_BASIC = 0
F_SSE2 = 1 << 26          # EDX[26]
F_SSE3 = 1 << 0           # ECX[0]
F_SSSE3 = 1 << 9          # ECX[9]
F_SSE41 = 1 << 19         # ECX[19]
F_SSE42 = 1 << 20         # ECX[20]
F_AES = 1 << 25           # ECX[25]
F_AVX = 1 << 28           # ECX[28]
F_F16C = 1 << 29          # ECX[29]
F_RDRAND = 1 << 30        # ECX[30]

F_BMI1 = 1 << 3           # 7.0:EBX
F_AVX2 = 1 << 5           # 7.0:EBX
F_BMI2 = 1 << 8           # 7.0:EBX
F_AVX512F = 1 << 16       # 7.0:EBX
F_AVX512DQ = 1 << 17      # 7.0:EBX
F_RDSEED = 1 << 18        # 7.0:EBX
F_AVX512CD = 1 << 28      # 7.0:EBX
F_SHA = 1 << 29           # 7.0:EBX
F_AVX512BW = 1 << 30      # 7.0:EBX
F_AVX512VL = 1 << 31      # 7.0:EBX

F_AMX_BF16 = 1 << 22      # 7.0:EDX
F_AMX_TILE = 1 << 24      # 7.0:EDX


def main() -> int:
    os.makedirs(OUT, exist_ok=True)
    files: dict[str, str] = {}

    # ------------------------------------------------------------------
    # 1. Starszy Intel: Core 2 Duo E6600 (Conroe, 2006)
    #    Family 6, Model 0x16. Brak leaf 4 i leaf 0x0B (pre-Nehalem) —
    #    sprawdza ścieżkę „minimum danych", a nie ścieżkę happy path.
    # ------------------------------------------------------------------
    files["intel_core2_e6600.cpuimg"] = render(
        name="Intel Core 2 Duo E6600 (Conroe)",
        header_comments=[
            "Family 6, Model 0x16, stepping 9. Brak leaf 4 i 0x0B:",
            "liczba rdzeni bierze się wyłącznie z CPUID.1.EBX[23:16].",
        ],
        vendor="GenuineIntel", max_basic=0x4, max_extended=0x80000008,
        sig=signature(0x0, 0x6, 0x1, 0x6, 0x9),
        logical=2,
        features=(F_SSE2, F_SSE3 | F_SSSE3, 0, 0),
        caches=[],
        brand="Intel(R) Core(TM)2 Duo CPU     E6600  @ 2.40GHz",
    )

    # ------------------------------------------------------------------
    # 2. Nowszy Intel: Core i9-13900K (Raptor Lake, 2022)
    #    Family 6, Model 0xB7. CPU hybrydowy: 24 wątki, ale liczba rdzeni
    #    fizycznych nie wynika z threads/SMT — sprawdza quirk hybrid_cores.
    # ------------------------------------------------------------------
    files["intel_i9_13900k.cpuimg"] = render(
        name="Intel Core i9-13900K (Raptor Lake)",
        header_comments=[
            "Family 6, Model 0xB7, stepping 1. CPU hybrydowy: 8 rdzeni P",
            "(SMT włączone) + 16 rdzeni E (SMT wyłączone) = 24 wątki.",
        ],
        vendor="GenuineIntel", max_basic=0x20, max_extended=0x80000008,
        sig=signature(0x0, 0x6, 0xB, 0x7, 0x1),
        logical=24,
        features=(F_SSE2,
                  F_SSE3 | F_SSSE3 | F_SSE41 | F_SSE42 | F_AES | F_AVX | F_F16C | F_RDRAND,
                  F_BMI1 | F_AVX2 | F_BMI2 | F_AVX512F | F_AVX512DQ | F_RDSEED |
                  F_AVX512CD | F_SHA | F_AVX512BW | F_AVX512VL,
                  F_AMX_BF16 | F_AMX_TILE),
        caches=[
            (1, 1, 48, 12, 64, 2, 8),    # L1d 48 KiB, 12-way, współdzielony przez 2
            (1, 2, 32, 8, 64, 2, 8),     # L1i 32 KiB, 8-way
            (2, 3, 2048, 16, 64, 2, 8),  # L2 2 MiB na rdzeń
            (3, 3, 24576, 12, 64, 24, 24),  # L3 24 MiB współdzielone (12-way: sets=32768)
        ],
        brand="13th Gen Intel(R) Core(TM) i9-13900K",
        leaf_b=24,
        # EAX w lisciu 0x0B = liczba bitow przesuniecia: 1 -> 2^1 = 2 watki
        # na rdzen (SMT2). Shift 0 oznaczalby SMT wylaczone.
        leaf_b_shift=1,
    )

    # ------------------------------------------------------------------
    # 3. Starszy AMD: Athlon 64 (K8 Hammer, 2004)
    #    Family 15, Model 0x2. Cache opisany liściami 0x80000005/6,
    #    których na tym etapie nie parsujemy — sprawdza brak cache w wyniku.
    # ------------------------------------------------------------------
    files["amd_athlon64_k8.cpuimg"] = render(
        name="AMD Athlon 64 3200+ (K8 Hammer)",
        header_comments=[
            "Family 15, Model 0x02, stepping 3. K8 nie ma leaf 4 — cache",
            "opisywane są w 0x80000005/0x80000006 (Etap 2).",
        ],
        vendor="AuthenticAMD", max_basic=0x4, max_extended=0x80000008,
        sig=signature(0x0, 0xF, 0x0, 0x2, 0x3),
        logical=1,
        features=(F_SSE2, 0, 0, 0),
        caches=[],
        brand="AMD Athlon(tm) 64 Processor  3200+",
    )

    # ------------------------------------------------------------------
    # 4. Zen-family AMD: Ryzen 7 5800X (Vermeer, Zen 3, 2020)
    #    Family 19h, Model 0x21. Cache w 0x8000001D (quirk cache_leaf_ext),
    #    ThreadsPerCore z 0x8000001E.
    # ------------------------------------------------------------------
    files["amd_ryzen7_5800x.cpuimg"] = render(
        name="AMD Ryzen 7 5800X (Vermeer, Zen 3)",
        header_comments=[
            "Family 19h, Model 0x21, stepping 0. Cache w leaf 0x8000001D.",
            "8 rdzeni / 16 wątków (SMT2).",
        ],
        # UWAGA: max_extended musi obejmowac 0x8000001E, bo inaczej probe
        # pomija ten liść jako „poza zakresem" i nie ma skąd wziąć ThreadsPerCore.
        # Zen 3 deklaruje 0x8000001E; wartość 0x80000008 to K8, nie Zen.
        vendor="AuthenticAMD", max_basic=0x10, max_extended=0x8000001E,
        sig=signature(0x0A, 0xF, 0x2, 0x1, 0x0),
        logical=16,
        features=(F_SSE2, F_AES | F_AVX | F_F16C,
                  F_BMI1 | F_AVX2 | F_BMI2 | F_SHA, 0),
        caches=[
            (1, 1, 32, 8, 64, 2, 8),      # L1d 32 KiB, 8-way
            (1, 2, 32, 8, 64, 2, 8),      # L1i 32 KiB, 8-way
            (2, 3, 512, 8, 64, 2, 8),     # L2 512 KiB na rdzeń
            (3, 3, 32768, 16, 64, 16, 8),  # L3 32 MiB współdzielone
        ],
        brand="AMD Ryzen 7 5800X 8-Core Processor",
        # Zen 3 zwraca w lisciu 0x0B same zera — topologie podaje 0x8000001E.
        leaf_b=0,
        ext_8000001e=2,
        amd_cache_leaf=True,
        # Zen 3 nie implementuje liscia 4 (zwraca EAX=0); generowanie go
        # spowodowaloby podwojne zliczenie tego samego cache.
        intel_cache_leaf=False,
    )

    # ------------------------------------------------------------------
    # 5. Nieznany producent + brak brand stringu
    #    Najważniejszy przypadek: wynik musi być użyteczny mimo pustych danych.
    # ------------------------------------------------------------------
    files["unknown_vendor.cpuimg"] = render(
        name="Nieznany producent, brak brand stringu",
        header_comments=[
            "Vendor string nie pasuje do żadnej z rozpoznawanych wartości.",
            "Leaf 0x80000002..4 zwracają same NUL-e. Oczekujemy, że dekoder",
            "wciąż zwróci rodzinę, model i oznaczy wynik jako niepewny.",
        ],
        vendor="FerrumTestCo", max_basic=0x1, max_extended=0x0,
        sig=signature(0x0, 0x6, 0x0, 0xA, 0x1),
        logical=1,
        features=(F_SSE2, 0, 0, 0),
        caches=[],
        brand=None,
    )

    for filename, text in files.items():
        path = os.path.join(OUT, filename)
        with open(path, "w", encoding="utf-8", newline="\n") as fh:
            fh.write(text)
        print(f"[ok] db/fixtures/{filename} ({len(text)} B)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
