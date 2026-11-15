#!/usr/bin/env python3
"""Generuje fixture'y topologii Intel dla testów.

    python tools/gen_intel_fixtures.py

KAŻDY plik jest oznaczony w nagłówku jako `synthetic_spec_fixture`.

To jest **istotne** i nie jest ozdobnikiem. Fixture opisuje topologię
zbudowaną wg Intel SDM Volume 2 (CPUID leaves 0xB, 0x1F, 0x1A), ale
**nie jest** zrzutem konkretnego, kupionego SKU. Różnica jest praktyczna,
a nie semantyczna: zrzut z maszyny zawierałby identyfikatory konkretnego
egzemplarza i przypadkowe wartości reszty rejestrów, których dekoder nie
używa. Fixture syntetyczny ma dokładnie te pola, które algorytm czyta,
i każde z nich można wskazać w SDM.

Jeśli kiedykolwiek dojdzie zrzut z prawdziwego CPU, powinien zastąpić ten
plik (albo dodać się obok jako osobny fixture) — ale wtedy nagłówek musi
zmienić `synthetic_spec_fixture` na `native_capture`, bo inaczej test
wprowadza w błąd co do pochodzenia danych.

Hierarchia liści, którą te fixture'y sprawdzają:
  * `intel_legacy_no_topology` — brak 0xB i 0x1F: fizyczna liczba rdzeni
    **nie jest dostępna z CPUID**; to zadanie dla fallbacku, nie dla pomiaru.
  * `intel_leaf0b` — 0x0B, jednorodne SMT2.
  * `intel_leaf1f` — 0x1F (v2) z typem rdzenia; ma pierwszeństwo przed 0x0B.
  * `intel_hybrid` — P-core + E-core, SMT tylko na P-core. 24 wątki na
    16 rdzeniach, więc `24 / 16 = 1.5` i globalne dzielenie **nie działa**.
"""

import os

OUT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "db", "fixtures")

INTEL_VENDOR = (0x756E6547, 0x6C65746E, 0x49656E69)  # EBX, ECX, EDX


def leaf(leaf_id, subleaf, regs):
    eax, ebx, ecx, edx = regs
    return (
        f"leaf 0x{leaf_id:08X} sub 0x{subleaf:02X} "
        f"eax=0x{eax:08X} ebx=0x{ebx:08X} ecx=0x{ecx:08X} edx=0x{edx:08X}"
    )


def per_cpu(cpu_id, leaf_id, subleaf, regs):
    eax, ebx, ecx, edx = regs
    return (
        f"per_cpu {cpu_id} leaf 0x{leaf_id:08X} sub 0x{subleaf:02X} "
        f"eax=0x{eax:08X} ebx=0x{ebx:08X} ecx=0x{ecx:08X} edx=0x{edx:08X}"
    )


def brand_lines(text):
    """Brand string w trzech liściach 0x80000002..4, dopełniony spacjami.

    Kolejność bajtów w rejestrze: najniższy bajt EAX to pierwszy znak
    (to nie jest kodowanie vendor stringu CPUID, które ma odwrotną kolejność).
    """
    padded = text.ljust(48)[:48]
    raw = padded.encode("ascii", "replace")
    out = []
    for i in range(3):
        chunk = raw[i * 16 : (i + 1) * 16]
        regs = [int.from_bytes(chunk[j : j + 4], "little") for j in range(0, 16, 4)]
        out.append(leaf(0x80000002 + i, 0, tuple(regs)))
    return out


# --- Poziomy topologii wg Intel SDM Vol. 2A ---------------------------------
#
# Rozkład rejestrów dla liści 0x0B i 0x1F (oba identyczne):
#   EAX[4:0]   liczba bitów do przesunięcia x2APIC w prawo, żeby dostać
#              unikalny identyfikator NASTĘPNEGO poziomu (kumulatywnie od zera)
#   EAX[31:16] typ rdzenia (0x1F, poz. Core): 0x40 = Core, 0x20 = Atom
#   EBX[15:0]  liczba logicznych procesorów na tym poziomie
#   ECX[15:8]  typ poziomu: 1 = SMT, 2 = Core, 3 = Module, 4 = Tile, 5 = Die
#   ECX[7:0]   numer poziomu (równy indeksowi subleafa)
#   EDX[31:0]  x2APIC ID bieżącego procesora logicznego
#
# x2APIC ID jest w EDX, **nie** w EBX[31:16]. Wcześniejsza wersja generatora
# wkładała go do EBX i deklarowała jednocześnie, że to błąd — plik był
# poprawnym formatem z błędną zawartością, czego żaden test składniowy nie
# wykrywa.

LEVEL_SMT = 1
LEVEL_CORE = 2
LEVEL_INVALID = 0

TYPE_CORE = 0x40
TYPE_ATOM = 0x20


def topo(cpu_id, leaf_id, subleaf, level_type, shift, x2apic, core_type=0, logical_at_level=0):
    """Jeden poprawny poziom topologii liścia 0x0B / 0x1F."""
    eax = (core_type << 16) | (shift & 0x1F)
    ebx = logical_at_level & 0xFFFF
    ecx = ((level_type & 0xFF) << 8) | (subleaf & 0xFF)
    edx = x2apic & 0xFFFFFFFF
    return per_cpu(cpu_id, leaf_id, subleaf, (eax, ebx, ecx, edx))


def extended_leaf(max_extended, feature_bits=0):
    """Liść 0x80000000: deklaracja zakresu extended.

    Bez tego liścia probe nie potwierdza `max_extended` i **nie czyta brand
    stringu** z 0x80000002..4 — nazwa spada wtedy na format hex, choć w pliku
    brand jest i jest poprawny. Fixture'y AMD miały ten liść, Intel nie miał,
    więc wszystkie fixture'y Intel pokazywały pustą nazwę.
    """
    return leaf(0x80000000, 0, (max_extended, 0, 0, feature_bits))


def topo_end(cpu_id, leaf_id, subleaf):
    """Terminator: konwencja CPUID to typ 0 i `EAX = 0`."""
    return per_cpu(cpu_id, leaf_id, subleaf, (0, 0, 0, 0))


def header(kind, spec, max_basic, max_extended, logical, extra_note=""):
    return [
        f"# FerrumScope fixture: {kind}",
        "# synthetic_spec_fixture",
        "#",
        "# POCHODZENIE: dane zsyntetyzowane wg Intel SDM Vol. 2 (CPUID leaves",
        f"# 0xB / 0x1F / 0x1A) dla: {spec}",
        "# NIE jest to zrzut konkretnego, kupionego procesora.",
        f"# Zadeklarowane logical processors: {logical}",
    ] + ([f"# {extra_note}"] if extra_note else []) + [
        f"ferrum-cpuimg 1",
        "arch x86_64",
        f"max_basic 0x{max_basic:X}",
        f"max_extended 0x{max_extended:X}",
        "",
    ]


def write(name, lines):
    path = os.path.normpath(os.path.join(OUT_DIR, name + ".cpuimg"))
    with open(path, "w", encoding="utf-8", newline="\n") as fh:
        fh.write("\n".join(lines) + "\n")
    print(f"  {name}.cpuimg  ({len(lines)} linii)")


# ---------------------------------------------------------------------------
# 1. Starszy Intel bez 0x0B i 0x1F
# ---------------------------------------------------------------------------
def gen_legacy():
    """Family 6, Model 0x0F (Conroe). max_basic = 0x10, więc 0xB i 0x1F
    leżą poza zakresem i CPU ich nie implementuje.

    Konsekwencja, którą test musi potwierdzić: **nie da się** wyznaczyć
    liczby rdzeni fizycznych z CPUID. Jedyne co zostaje to liczba wątków
    z leaf 1 oraz właściwość rodziny z bazy.

    Core 2 Duo E6600: **2 rdzenie, 2 wątki, bez Hyper-Threadingu**. Przy
    `logical = 4` i `quirk_smt_threads = 1` dekorator policzyłby „4 rdzenie",
    co jest fałszywe — więc liczba wątków musi odpowiadać prawdziwej
    maszynie, inaczej fixture uczy wnioskowania zamiast go sprawdzać.
    """
    logical = 2
    out = header(
        "Intel bez nowoczesnych liści topologii",
        "Family 6, Model 0x0F (Conroe/Core 2), max_basic = 0x10",
        0x10,
        0x80000008,
        logical,
        "0x0B i 0x1F są POZA zakresem -> brak pomiaru rdzeni fizycznych.",
    )
    out.append(leaf(0x0, 0, (0x10,) + INTEL_VENDOR))
    # EBX[31:24] = initial APIC ID, EBX[23:16] = MaxLogical, EBX[15:0] = CLFLUSH
    out.append(leaf(0x1, 0, (0x000006F2, (logical << 16) | 0x000100, 0x7FBFEBFF, 0x2FD4FBFF)))
    out += brand_lines("Intel(R) Core(TM)2 Duo CPU     E6600 ")
    out.append(leaf(0x80000002, 0, (0, 0, 0, 0)))  # terminator brandu w v1
    out.append(leaf(0x80000008, 0, (0, 0, 0, 0)))
    write("intel_legacy_no_topology", out)


# ---------------------------------------------------------------------------
# 2. Intel z liściem 0x0B
# ---------------------------------------------------------------------------
def gen_leaf0b():
    """Family 6, Model 0x55 (Skylake), 4 rdzenie × 2 wątki = 8 logicznych.

    Leaf 0x0B subleaf 0 = poziom SMT: EAX = 1 (przesunięcie o 1 bit),
    EBX[31:16] = x2APIC ID, EBX[15:0] = liczba logicznych na tym poziomie.
    subleaf 1 = poziom Core, subleaf 2 kończy serię (EAX = 0).
    """
    logical = 8
    cores = 4
    out = header(
        "Intel z liściem 0x0B",
        "Family 6, Model 0x55 (Skylake), 4C/8T, SMT2",
        0x16,
        0x80000008,
        logical,
        "package = x2apic >> 3; core_id = (x2apic >> 1) & 0x3.",
    )
    out.append(leaf(0x0, 0, (0x16,) + INTEL_VENDOR))
    out.append(leaf(0x1, 0, (0x00050654, (logical << 16) | 0x000100, 0x7FFAFBFF, 0xBFEBFBFF)))
    out.append(extended_leaf(0x80000008))
    out += brand_lines("Intel(R) Core(TM) i5-6600K CPU @ 3.40GHz")
    smt_shift, core_shift, smt_threads = 1, 3, 2
    for cpu in range(logical):
        x2apic = cpu
        out.append(per_cpu(cpu, 0x1, 0, (0x00050654, (logical << 16) | (cpu & 0xFF), 0x7FFAFBFF, 0xBFEBFBFF)))
        out.append(topo(cpu, 0xB, 0, LEVEL_SMT, smt_shift, x2apic, logical_at_level=smt_threads))
        out.append(topo(cpu, 0xB, 1, LEVEL_CORE, core_shift, x2apic, logical_at_level=logical))
        out.append(topo_end(cpu, 0xB, 2))
    write("intel_leaf0b", out)


# ---------------------------------------------------------------------------
# 3. Intel z liściem 0x1F (v2)
# ---------------------------------------------------------------------------
def gen_leaf1f():
    """Family 6, Model 0x8F (Sapphire Rapids), 8 rdzeni × 2 wątki.

    Liść 0x1F różni się od 0x0B tym, że `EAX[31:16]` niesie **typ rdzenia**
    (0x40 = Core / P-core, 0x20 = Atom / E-core). Dekoder preferuje 0x1F, bo
    ma dodatkową informację, której 0x0B nie zawiera.
    """
    logical = 16
    cores = 8
    out = header(
        "Intel z liściem 0x1F (v2)",
        "Family 6, Model 0x8F (Sapphire Rapids), 8C/16T, SMT2",
        0x20,
        0x80000008,
        logical,
        "0x1F ma pierwszenstwo przed 0x0B; EAX[31:16] = 0x40 = typ Core.",
    )
    out.append(leaf(0x0, 0, (0x20,) + INTEL_VENDOR))
    # Sygnatura koduje Family 6, ext_model 8, model_field 0xF -> displayModel 0x8F
    # (Sapphire Rapids), zgodnie z nagłówkiem. Wcześniej było tu `0x000806A1`, co
    # daje `8 << 4 | 0xA = 0x8A` — czyli **Lakefield**. Fixture twierdził jedno,
    # a opisywał drugie, i nic tego nie wykrywało, bo plik był poprawnym formatem
    # z błędną zawartością: dokładnie ten sam rodzaj pomyłki, co `0x1` zamiast `0x1F`.
    out.append(leaf(0x1, 0, (0x000806F1, (logical << 16) | 0x000100, 0x7FFAFBFF, 0xBFEBFBFF)))
    out.append(extended_leaf(0x80000008))
    out += brand_lines("Intel(R) Xeon(R) Platinum 8488C CPU")
    smt_shift, core_shift, smt_threads = 1, 4, 2
    for cpu in range(logical):
        x2apic = cpu
        out.append(per_cpu(cpu, 0x1, 0, (0x000806F1, (logical << 16) | (cpu & 0xFF), 0x7FFAFBFF, 0xBFEBFBFF)))
        # Liść 0x1F, NIE 0x1. Wcześniejsza wersja zapisywała tu `0x1`, więc w
        # pliku nie było liścia, którego szukał decoder: `measure()` nie
        # znajdował poziomu SMT, odrzucał pomiar i topologia spadała na `hwdb`.
        # Ta litera była kosztowna w sposób niewidoczny — plik wyglądał
        # poprawnie, a test badał nieistniejący liść.
        #
        # x2APIC idzie w EDX[31:0], typ rdzenia w EAX[31:16] (0x40 = Core).
        out.append(topo(cpu, 0x1F, 0, LEVEL_SMT, smt_shift, x2apic, core_type=TYPE_CORE, logical_at_level=smt_threads))
        out.append(topo(cpu, 0x1F, 1, LEVEL_CORE, core_shift, x2apic, core_type=TYPE_CORE, logical_at_level=logical))
        out.append(topo_end(cpu, 0x1F, 2))
        # 0x1A: Native Model ID (EAX). Dekoder używa go jako potwierdzenia,
        # że wszystkie rdzenie tego samego procesora zgłaszają ten sam model —
        # przy hybridzie to nieoczywiste, bo 0x1A jest per-procesor.
        out.append(per_cpu(cpu, 0x1A, 0, (0x000806A0, 0x08080200, 0x00000000, 0x00000000)))
    write("intel_leaf1f", out)


# ---------------------------------------------------------------------------
# 4. Intel hybrydowy: P-core + E-core
# ---------------------------------------------------------------------------
def gen_hybrid():
    """Family 6, Model 0x97 (Alder Lake), 8 P-core (SMT2) + 8 E-core (bez SMT).

    8*2 + 8*1 = **24 wątki na 16 rdzeniach**. `24 / 16 = 1.5`, więc
    `threads / physical` nie jest całkowite i **nie wolno** z tego wyliczać
    szerokości SMT. Dekoder musi zliczyć wątki osobno dla każdego rdzenia.

    To jest dokładnie przypadek, dla którego „logical / 2 = physical" jest
    błędne: dałoby 12 rdzeni zamiast 16.

    Nazwa pliku to `intel_hybrid_12900k`, bo 8P + 8E to topologia **i9-12900K**.
    i7-12700K ma 8P + 4E. Poprzednia wersja nazywała ten układ 12700K — nazwa
    nie wpływa na dekodowanie, ale fixture twierdzący jedno, a opisujący drugie,
    jest nie do odróżnienia od prawdziwego zrzutu.
    """
    p_threads = 16  # 8 P-core po 2
    e_threads = 8  # 8 E-core po 1
    logical = p_threads + e_threads
    out = header(
        "Intel hybrydowy P-core + E-core",
        "Family 6, Model 0x97 (Alder Lake), 8 P-core + 8 E-core, 24 wątki",
        0x20,
        0x80000008,
        logical,
        "24/16 = 1.5 -> globalne dzielenie threads/physical NIE DZIAŁA.",
    )
    out.append(leaf(0x0, 0, (0x20,) + INTEL_VENDOR))
    out.append(leaf(0x1, 0, (0x00090672, (logical << 16) | 0x000100, 0x7FFAFBFF, 0xBFEBFBFF)))
    out.append(extended_leaf(0x80000008))
    out += brand_lines("12th Gen Intel(R) Core(TM) i9-12900K")

    # Shift poziomu Core musi objąć **całą** przestrzeń x2APIC pakietu, inaczej
    # górne bity wyjdą jako osobne pakiety. 24 logiczne procesory mieszczą się
    # w 5 bitach, więc `package = x2apic >> 5` = 0 dla każdego CPU.
    core_shift = 5
    for cpu in range(logical):
        if cpu < p_threads:
            # P-core: SMT2, typ Core.
            x2apic = cpu
            smt_shift = 1
            core_type = TYPE_CORE
        else:
            # E-core: bez SMT, typ Atom. x2APIC 16..23 — wciąż w tym samym
            # pakiecie, bo bit 4 leży poniżej `core_shift`.
            x2apic = cpu
            smt_shift = 0
            core_type = TYPE_ATOM

        out.append(per_cpu(cpu, 0x1, 0, (0x00090672, (logical << 16) | (cpu & 0xFF), 0x7FFAFBFF, 0xBFEBFBFF)))
        out.append(topo(cpu, 0x1F, 0, LEVEL_SMT, smt_shift, x2apic, core_type=core_type, logical_at_level=(2 if smt_shift else 1)))
        out.append(topo(cpu, 0x1F, 1, LEVEL_CORE, core_shift, x2apic, core_type=core_type, logical_at_level=logical))
        out.append(topo_end(cpu, 0x1F, 2))
        out.append(per_cpu(cpu, 0x1A, 0, (0x00090670, 0x08080200, 0x00000000, 0x00000000)))
    write("intel_hybrid_12900k", out)


# ---------------------------------------------------------------------------
# 5. Dwa gniazda — powtarzający się CoreId
# ---------------------------------------------------------------------------
def gen_2xsocket():
    """2 gniazda po 8 rdzeni SMT2 = 16 rdzeni, 32 logiczne procesory.

    Fixture istnieje po to, by udowodnić jedną rzecz: pole `CoreId` jest
    **lokalne w obrębie pakietu i celowo się powtarza** między gniazdami. Rdzeń
    o id 0 w gnieździe 0 i rdzeń o id 0 w gnieździe 1 mają ten sam `core_id`,
    a mimo to są dwoma różnymi rdzeniami fizycznymi. Liczenie samych `core_id`
    dałoby 8 zamiast 16.

    Numeracja SDM (tylko dwa poziomy, bez Die/Tile):

        SMT:  shift = 1  -> 2 logiczne procesory na tym poziomie
        Core: shift = 4  -> 16 logicznych procesorów w pakiecie

    Stąd `core_id = (x2apic >> 1) & 0x7` (trzy bity, bo `4 - 1 = 3`) oraz
    `package = x2apic >> 4`. Gniazdo 0 dostaje x2APIC 0..15, gniazdo 1 16..31,
    więc `core_id` wychodzi 0..7 **w obu gniazdach**, a `package` raz 0, raz 1.

    Liczba pakietów **nie jest zapisana w pliku** — decoder musi ją wyliczyć z
    x2APIC i shiftów. Fixture zawiera wyłącznie to, co raportowałby sprzęt.
    """
    per_socket_cores = 8
    per_socket_threads = per_socket_cores * 2  # SMT2
    logical = per_socket_threads * 2
    out = header(
        "Intel, dwa gniazda",
        "Family 6, Model 0x8F, 2 gniazda po 8C/16T, razem 16C/32T",
        0x20,
        0x80000008,
        logical,
        "CoreId 0..7 POWTARZA SIĘ w obu gniazdach; rozróżnia je package_id.",
    )
    out.append(leaf(0x0, 0, (0x20,) + INTEL_VENDOR))
    # Family 6, ext_model 6, model_field 0xA -> displayModel 0x6A (Ice Lake-SP),
    # czyli generacja, z której pochodzi Xeon Gold 6338 użyty w brand stringu.
    out.append(leaf(0x1, 0, (0x000606A1, (logical << 16) | 0x000100, 0x7FFAFBFF, 0xBFEBFBFF)))
    out.append(extended_leaf(0x80000008))
    out += brand_lines("Intel(R) Xeon(R) Gold 6338 CPU @ 2.20GHz")

    smt_shift, core_shift, smt_threads = 1, 4, 2
    for cpu in range(logical):
        # Gniazda dostają kolejne bloki numerów x2APIC; nic więcej nie kodujemy.
        x2apic = cpu
        out.append(per_cpu(cpu, 0x1, 0, (0x000606A1, (logical << 16) | (cpu & 0xFF), 0x7FFAFBFF, 0xBFEBFBFF)))
        out.append(topo(cpu, 0x1F, 0, LEVEL_SMT, smt_shift, x2apic, core_type=TYPE_CORE, logical_at_level=smt_threads))
        out.append(topo(cpu, 0x1F, 1, LEVEL_CORE, core_shift, x2apic, core_type=TYPE_CORE, logical_at_level=per_socket_threads))
        out.append(topo_end(cpu, 0x1F, 2))
    write("intel_2xsocket_8core", out)


if __name__ == "__main__":
    print("Generowanie fixture'ów Intel (synthetic_spec_fixture):")
    gen_legacy()
    gen_leaf0b()
    gen_leaf1f()
    gen_hybrid()
    gen_2xsocket()
    print("Gotowe.")
