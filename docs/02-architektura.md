# FerrumScope — architektura rdzenia (projekt)

Status: projekt fundamentów. Implementacja świadomie **nie** jest jeszcze robiona
(priorytet: CPU-only v1). Wszystkie typy poniżej to kontrakt, nie gotowy kod.

Kontekst: wnioski z `docs/01-analiza-referencji.md`.

---

## 1. Korekta proponowanego layoutu

Twój szkic jest dobry, ale ma jedną wadę: **`bus/` i `arch/` wymieszane są z `platform/`,
przez co nie wiadomo, gdzie ma być granica „to zależy od sprzętu" a „to zależy od OS"**.
Proponuję jedną regułę i jedno odejście od szkicu:

> **Każdy moduł ma dokładnie jednego dostawcę prymitywów: `platform/<os>`.**
> Jeśli moduł potrzebuje dostępu do sprzętu, **deklaruje** capability, a nie importuje OS-a.

Wobec tego `bus/` nie implementuje dostępu do magistrali — implementuje **protobokoły**
(PCI, SMBus, I2C, NVMe) na wstrzykniętym transporcie. To jedyna zmiana merytoryczna.

```
ferrumscope/
├── build.zig                 # build + krok kompilacji bazy
├── build.zig.zon
│
├── src/
│   ├── core/                 # czysty Zig, zero OS, zero I/O
│   │   ├── ids.zig           # VendorId, DeviceId, Bus/Dev/Fn, Rev
│   │   ├── raw.zig           # RawCpuInfo, RawGpuInfo, RawPciDevice, ...
│   │   ├── model.zig         # CpuInfo, GpuInfo, MemoryModule, BoardInfo
│   │   ├── status.zig        # Status<T>, Degraded<T>, Unavailable
│   │   ├── units.zig         # Hz, Volts, Watts, Celsius, Bytes + fmt
│   │   └── version.zig       # semver FerrumScope
│   │
│   ├── arch/                 # prymitywy architektury (czyste, testowalne)
│   │   ├── x86/cpuid.zig     # CPUID: generatory, maski, normalizacja leaf 1/7/0x14/0x16/0x1A
│   │   ├── x86/msr.zig       # adresowanie MSR (rdmsr/wrmsr) + allowlist
│   │   ├── arm64/
│   │   └── none.zig          # stub dla platform bez CPUID (USOS minimal)
│   │
│   ├── bus/                  # protokoły — BEZ I/O
│   │   ├── pci/config.zig    # odczyt config space, mapowanie BAR, struktury
│   │   ├── smbus.zig         # transakcje SMBus/I2C
│   │   ├── i2c.zig
│   │   ├── nvme.zig          # identify / log pages
│   │   └── usb.zig
│   │
│   ├── platform/             # JEDYNE miejsce z `if windows` / `if linux` / `if macos`
│   │   ├── backend.zig       # interfejs Capabilities + vtable transportów
│   │   ├── windows/          # user-mode + client dla sterownika
│   │   │   └── driver/       # źródła sterownika (C/C++), osobny build, osobny podpis
│   │   ├── linux/            # sysfs, hwmon, DRM, ioctl
│   │   ├── macos/            # IOKit, IORegistry, sysctl, Apple Silicon
│   │   └── usos/             # minimalny backend, brak zależności od desktopu
│   │
│   ├── probe/                # KĄD odczytuje (wielofazowo, anulowalnie)
│   │   ├── cpu.zig
│   │   ├── gpu.zig
│   │   ├── memory.zig
│   │   ├── board.zig
│   │   ├── storage.zig
│   │   └── sensors.zig
│   │
│   ├── decode/               # KĄD interpretuje (czyste funkcje raw -> model)
│   │   ├── cpu/x86.zig       # family/model/stepping -> generacja
│   │   ├── cpu/arm64.zig
│   │   ├── gpu/pci.zig       # device_id -> chip
│   │   └── gpu/subsystem.zig # subvendor/subdevice -> board
│   │
│   ├── db/                   # hardware database
│   │   ├── source/           # TOML, edytowalny przez człowieka
│   │   ├── schema/           # json-schema dla TOML-ów
│   │   ├── runtime.zig       # wczytanie ferrum-hwdb.bin
│   │   └── embedded.zig      # @embedFile snapshotu
│   │
│   ├── metrics/              # silnik runtime, bufor próbek
│   ├── benchmark/
│   ├── stress/
│   ├── capture/              # zapis .fcap
│   ├── replay/               # odczyt .fcap -> Backend
│   ├── cli/
│   └── gui/
│
├── tools/
│   ├── hwdb/
│   │   ├── compile.zig       # kompilator bazy (walidacja -> ferrum-hwdb.bin)
│   │   └── pciids_import.py  # import publicznego rejestru PCI ID
│   └── refext/               # analiza referencji CPU-Z/GPU-Z (poza produktem)
│
├── db/
│   ├── source/               # źródło prawdy: cpu/, gpu/, chipset/, pci/
│   └── fixtures/             # .fcap z CI
│
├── reference/                # KWARANTANNA — nigdy nie do dystrybucji
└── docs/
```

**Odejścia od Twojego szkicu, z uzasadnieniem:**

1. `arch/` zamiast `architektur/` — zostaje, ale **nie ma w nim I/O**: CPUID to architektura,
   MSR to *dostęp* do MSR. Rozdzielenie jest tu celowe, bo pozwala testować dekodery
   na x86 bez Windowsa.
2. `bus/` przed `platform/` — magistrale są protokołem, nie API systemu.
3. `capture/` i `replay/` rozdzielone — `replay` musi udawać `Backend`, inaczej dekodery
   nie da się testować.
4. `gui/` na końcu i **nie** w buildzie `v1`.
5. `driver/` jako podkatalog — sterownik nie jest częścią `platform/windows` w Zig,
   bo to inny język i inny model bezpieczeństwa.

---

## 2. Potok danych

```
sprzęt
  │  (platform backend: Capabilities + transporty)
  ▼
Raw* (probe)          ← surowe, kompletne, bez interpretacji
  │  (decode + db)
  ▼
*Info (model)         ← znormalizowany, gotowy do prezentacji
  │  (render)
  ▼
GUI / CLI / JSON / raport / USOS
```

Reguła: **`Raw*` nigdy nie zależy od `db` i `decode`; `*Info` nigdy nie zależy od platformy.**

---

## 3. `RawCpuInfo` — surowe dane CPU

Zasada: zapisujemy **wszystko**, łącznie z tym, czego dziś nie umiemy zinterpretować.
Dzięki temu `.fcap` zebrany dziś da wynik po wdrożeniu dekodera za rok.

```zig
/// Zbiór architektoniczny: x86 / x86_64 / arm64 / inny.
pub const Arch = enum { x86, x86_64, arm64, riscv64, unknown };

/// Surowe odczytane dane. Każde pole ma `?` albo `Status(T)` — brak odczytu jest
/// informacją, nie błędem.
pub const RawCpuInfo = struct {
    // --- tożsamość, zawsze obecna -----------------------------------------
    arch: Arch,
    vendor_id: ids.VendorId,              // z CPUID.0
    signature: u32,                       // CPUID.0.EAX

    // --- CPUID: zawsze zapisujemy liście surowe --------------------------
    cpuid: CpuidImage,                    // mapa leaf -> 4 rejestry (bounded)

    // --- leaf 1, znormalizowane (surowe w cpuid) -------------------------
    cpu_signature: u32,                   // EAX: stepping|model|family|ext
    ext_family: u8,
    ext_model: u8,
    model: u8,
    family: u8,
    stepping: u8,
    processor_type: u8,
    brand_id: u16,                        // CPUID.1.EBX

    /// leaf 0x80000002..4 — brand string, surowe bajty z NULami
    brand_raw: [48]u8,
    max_leaf_basic: u32,
    max_leaf_extended: u32,

    // --- cechy -------------------------------------------------------------
    features: FeatureSet,                 // z leaf 1, 7, 0x80000001
    xsave_info: XsaveInfo?,               // leaf 0xD
    freq_info: FreqLeaf?,                 // leaf 0x16 (GHz w BCD)
    topology_ext: TopologyExt?,           // leaf 0x1F / 0xB (x2APIC, AMX)

    // --- topologia ---------------------------------------------------------
    logical_cores_raw: u8,                // z CPUID.1
    logical_cores_topology: u8,           // z CPUID.0xB (bez fallbacku)
    apic_ids: []u32,                      // z CPUID.0xB

    /// CACHE — leaf 0x4; zapisujemy WSZYSTKIE cache'e, nie tylko L1/L2/L3.
    caches: []RawCache,

    /// TLB — leaf 2; format bywa zależny od producenta, więc surowo.
    tlb_raw: []u32,
    /// Extended TLB — leaf 0x80000005/0x80000006
    tlb_ext_raw: struct { l1: []u32, l2: []u32 },

    // --- MSR: tylko allowlist, nic więcej ---------------------------------
    msr: MsrSamples,                     // zob. allowlist w §9

    // --- pamięć (to co CPU mówi o sobie, nie DIMM-y) ---------------------
    cache_line_size: ?u16,
    max_address_width: ?u8,
    physical_address_bits: ?u8,

    // --- kontekst platformowy --------------------------------------------
    hypervisor_hint: HypervisorHint?,    // z leaf 0x40000000 (KVM/Hyper-V/VMware)
    platform: PlatformTag,                // opis platformy, nie sprzętu

    // --- diagnostyka -------------------------------------------------------
    source: []const RawSource,            // skąd pochodzi każdy kawałek
    warnings: []const Diagnostic,         // „leaf 0xB niespójny z leaf 1"
};
```

**Dlaczego `CpuidImage` zamiast gotowych pól:** leaf 0x1F, 0x14 i 0x1A są nowsze niż
większość dekodera. Zapisanie surowego obrazu oznacza, że nowy dekoder da wynik dla
`.fcap` sprzed roku, bez ponownego chodzenia po sprzęcie.

---

## 4. `RawGpuInfo` — surowe dane GPU

Tu GPU-Z pokazuje, czego nie wolno pominąć: **chip ≠ karta**.

```zig
pub const RawGpuInfo = struct {
    // --- lokalizacja --------------------------------------------------------
    location: PciLocation,               // { bus, device, function }
    vendor_id: ids.VendorId,
    device_id: ids.DeviceId,             // identyfikuje CHIP
    revision: u8,                         // identyfikuje rewizję steppingu
    subvendor_id: ?u16,                  // identyfikuje PRODUCENTA KARTY
    subdevice_id: ?u16,                  // identyfikuje KONKRETNĄ KARTĘ

    // --- przestrzeń konfiguracyjna ------------------------------------------
    config: PciConfigSpace,               // 4 KB (lub mniej, jeśli nie dało się czytać)
    header_type: u8,                      // 0 / 1 / 2 — inny układ pól!
    class_code: u32,                      // 0x030000 itd.
    bars: []Bar,                          // typ, adres, flagi, rozmiar

    // --- przydziały ---------------------------------------------------------
    memory_bars: []MemoryBar,             // typ VRAM (VRAM/ECC/SRAM) + rozmiar

    // --- identyfikacja poza PCI ---------------------------------------------
    /// Odczyt z BAR (VBIOS/EFI image) — nagłówek + selektywne bloki.
    vbios: ?VbiosImage,                   // sygnatura, wersja, data, tekst, tabela
    /// Vendor API (ADL/NVAPI/IGCL) — surowo, z numerem wersji API.
    vendor_api: ?VendorApiBlob,
    /// SMBIOS typu 128 (ACPI), 127 (?), a na laptopach — wpisy z DMI.
    smbios_oem: ?[]const u8,

    // --- stan / telemetryczne surowe ----------------------------------------
    runtime: ?RawGpuRuntime,              // zawsze opcjonalne i asynchroniczne

    source: []const RawSource,
    warnings: []const Diagnostic,
};

pub const PciLocation = struct {
    bus: u8, device: u5, function: u3,
    // Typ slotu: PCIe/PCI/AGP — wyprowadzany, ale zapisujemy surowe pola
    // (link status, slot) bo bywa mylące.
    pcie: ?PcieInfo,                     // link speed/width zbrojenia, slot, L1 substates
};
```

**Świadoma decyzja:** `RawGpuInfo` zawiera `?VbiosImage` i `?VendorApiBlob`, choć
w v1 CPU-only ich nie obsługujemy. Koszt: kilka linii. Korzyść: `.fcap` z v1 da wynik
dla GPU później, bez zmiany formatu pliku.

---

## 5. `CpuInfo` — znormalizowany model

```zig
pub const CpuInfo = struct {
    // --- tożsamość ----------------------------------------------------------
    name: Name,                           // patrz niżej — nigdy nie .unknown
    vendor: Vendor,                       // .intel / .amd / .apple / .hygon / .other(u16)
    brand_raw: [48]u8,                    // zawsze surowe, także gdy name != brand

    // --- numeracja x86 ------------------------------------------------------
    numbering: ?X86Numbering,             // { family, model, stepping, ext_* }
    /// Rodzina w sensie marketingowym (Zen 4, Raptor Lake, ...) — z bazy.
    family_name: ?[]const u8,
    codename: ?[]const u8,                // z bazy, może być null dla „nieznanej generacji"

    // --- surowy odczyt vs interpretacja (wdrożone, format v3) ----------------
    //
    // Podział, którego nie wolno złamać: `stepping` to **odczyt** CPUID, a
    // `stepping_name` to **interpretacja** z bazy. Nigdy nie zastępujemy jednego
    // drugim — `VMR-B2` pochodzi z bazy z jawnym provenance, a `2` z CPUID,
    // i obie wartości współistnieją.
    stepping: u8,                         // surowe, z CPUID leaf 1 EAX[3:0]
    signature_source: FieldSource,         // .cpuid — jawnie, by nie mylić z interpretacją
    stepping_name: ?[]const u8,            // np. "VMR-B2"; null = „nie umiemy"
    stepping_name_source: FieldSource,     // .empirical | .hwdb_exact | ...
    stepping_name_provenance: Provenance,  // { source_url, source, source_type, confidence, notes }

    // --- gniazdo / pakiet ----------------------------------------------------
    //
    // `smbios_socket_designation` to **osobne** pole od `socket_name`, bo SMBIOS
    // podaje nazwę slotu na płycie (`CPU1`, `J202`), a nie typ gniazda procesora.
    // Bez tego podziału `Socket Designation` przejąłby rolę gniazda i pokazałby
    // „CPU1" tam, gdzie powinno być „AM4".
    socket_name: ?[]const u8,              // np. "AM4"
    socket_source: FieldSource,
    socket_confidence: Confidence,
    socket_provenance: Provenance,
    package_contacts: u16,                 // 0 = nieznana (nie wolno zgadywać)
    smbios_socket_designation: ?[]const u8,
    smbios_socket_source: FieldSource,

    // --- refinament z brand stringu -----------------------------------------
    //
    // Wyłącznie pola, których CPUID nie niesie. Reguły są w bazie i mają
    // **wymuszony zakres** (vendor + rodzina + model), więc wzorzec typu „X3D”
    // nie może przypisać wariantu procesorowi innego producenta.
    product_name: ?[]const u8,             // konkretny SKU, np. "Ryzen 7 5800X3D"
    product_name_source: FieldSource,
    variant_source: FieldSource,           // .brand_derived = zinterpretowaliśmy brand
    variant_provenance: Provenance,

    // --- opis ---------------------------------------------------------------
    cores_physical: u16,
    threads_logical: u16,
    smt: SmtInfo,                         // sibling/thread + core-type mask (P/E w ARM)
    base_clock: ?Hertz,
    max_turbo: ?Hertz,
    boost_bins: ?[]const Bin,             // dla Intel: PL1/PL2/TAU — z MSR, nie z bazy

    // --- pamięć cache --------------------------------------------------------
    caches: []CacheLevel,

    // --- cechy (ustalane, nie zgadywane) ------------------------------------
    features: FeatureSet,
    has_avx512: bool,                     // liczone z faktycznych bitów, nie z nazwy

    // --- topologia ----------------------------------------------------------
    topology: Topology,                   // gniazda, NUMA, grupy, L3 ownership

    // --- jakość dopasowania (patrz §7) -------------------------------------
    match: MatchQuality,
```

### 5.1 `FieldSource` — jeden `match quality` nie wystarcza

Brief i porównanie z CPU-Z pokazały, że **jeden** globalny „stopień dopasowania"
nie opisuje wszystkich pól: nazwa może pochodzić z CPUID, kodname z dopasowanego
wzorca, wariant z brand stringu, a gniazdo z bazy. Wszystkie cztery to „dane
zidentyfikowane", ale o zupełnie różnej sile dowodu.

```zig
pub const FieldSource = enum {
    none,                 // nikt o tym nie myślał
    cpuid,                // sprzęt — odczyt
    generated,            // wygenerowane z samej sygnatury

    hwdb,                 // starsze pola — zachowane dla zgodności
    hwdb_exact,           // dopasowanie na konkretny model
    hwdb_pattern,         // dopasowanie zakresem modeli (wzorzec)
    hwdb_family,          // trafienie wyłącznie na wpis family_generic

    brand_derived,        // z brand stringu, przez regułę z zakresem
    smbios,               // z SMBIOS (slot na płycie ≠ typ gniazda)
    platform,             // ACPI / rejestry platformowe
    empirical,            // obserwacja na sprzęcie (np. CPU-Z jako oracle)
    unknown,              // sprawdzone i celowo nieznane
};
```

Osobne osie, których **nie** łączymy:

* `FieldSource` — **skąd** (pomiar / baza / heurystyka / obserwacja).
* `Confidence` (`unknown|low|medium|high`) — **jak bardzo** ufamy.
* `ProvenanceType` (`vendor_doc|derived|reference_observation|community|…`) —
  **jaki materiał** za tym stoi.

Rozbicie na trzy pola jest celowe: obserwacja na własnym sprzęcie bywa **pewna**
i wciąż **nie jest** dokumentacją producenta. `reference_observation` + `medium`
mówi dokładnie to, co wiemy o `VMR-B2`.

    // --- kontekst ------------------------------------------------------------
    virtualization: ?Virtualization,
    raw_digest: u64,                      // hash surowych danych — do logów i diffów
};
```

---

## 6. `GpuInfo` — znormalizowany model

```zig
pub const GpuInfo = struct {
    name: Name,                           // "AMD Radeon RX 6900 XT"
    vendor: GpuVendor,                    // .amd .nvidia .intel .apple .other

    // --- trzy warstwy tożsamości (wspólna lekcja z analizy GPU-Z) -----------
    chip: ?ChipInfo,                      // "Navi 21"  ← po device_id
    board: ?BoardInfo,                    // "PowerColor Red Devil" ← po subvendor/subdevice
    revision: ?[]const u8,                 // po revision

    location: PciLocation,
    bus: GpuBus,                          // .pcie .pci .agp .unknown
    generation: ?GpuGeneration,           // "RDNA 2", "Blackwell" — z bazy

    vram: ?MemoryInfo,                    // typ + pojemność z BAR-ów
    clocks: ?ClockLimits,                 // max boost z bazy, nie z odczytu
    features: GpuFeatureSet,

    match: MatchQuality,
    raw_digest: u64,
};
```

`chip` / `board` / `revision` to osobne pola **celowo**: to jedyna poprawna droga przy
~10 tys. kart partnerskich na tym samym rdzeniu.

---

## 7. `Name` i `MatchQuality` — brak `null` w warstwie prezentacji

Wynik analizy CPU-Z/GPU-Z: brak wpisu w bazie nie może dać pustego pola.

```zig
pub const Name = struct {
    /// Nazwa „produktu" znaleziona w bazie, np. "AMD Ryzen 9 5950X".
    display: []const u8,
    /// Nazwa generowana z danych surowych, gdy baza milczy, np.
    /// "Unknown 0x17F1 (Family 25 Model 113)". Zawsze niepusta.
    fallback: FallbackKind,
};

pub const FallbackKind = enum {
    brand_string,          // CPUID.0x80000002 — najlepszy przypadek
    family_model_pattern,  // wzorzec z bazy: "AMD Ryzen 7 {model}00X"
    family_only,           // "AMD Zen 3, model 0x{model}"
    hex_id,                // "Unknown vendor 0x10DE device 0x2684"
};

pub const MatchQuality = enum {
    exact,        // (vendor, device, revision) w bazie
    device,       // (vendor, device) w bazie
    pattern,      // dopasowanie wzorcem rodziny
    vendor_only,  // znamy producenta, nie znamy modelu
    unknown,      // zgłoś do bazy — UI powinno to aktywnie zachęcać
};
```

`MatchQuality` przechodzi do JSON-a i do raportu, więc widzimy pokrycie bazy w telemetrii
projektu, bez zbierania danych osobowych.

---

## 8. Model prymitywów i statusów

```zig
pub const Status = union(enum) {
    ok,
    unsupported,      // platforma nie ma tej capability — NIE błąd
    denied,           // brak uprawnień — komunikat „uruchom jako administrator"
    timeout,          // proba przekroczyła budżet czasu
    failed,           // sprzęt zwrócił błąd
    absent,           // urządzenia nie ma (prawidłowy wynik: „brak NVMe")
    skipped,          // zależność nie spełniona (np. brak bazy)
};

pub const Degraded = struct {
    /// Co udało się ustalić.
    partial: ?anyopaque,        // typ zależny od probe'a
    status: Status,
    detail: ?[]const u8,        // diagnostyka dla logu, nie dla UI
};
```

**Reguła:** `unsupported` i `absent` to **nie błędy programu**. GUI ma pokazać
„niedostępne na tej platformie", CLI ma zwrócić 0 i zaznaczyć pole.
Błąd programu to wyłącznie: błędna baza, błędny `.fcap`, błąd wewnętrzny dekodera.

---

## 9. Capability model

```zig
pub const Capability = enum {
    cpuid,
    msr_read,
    pci_config,
    io_ports,
    smbus,
    i2c,
    nvme_admin,
    smbios,
    // ...
    drm_sysfs,        // Linux
    iokit_registry,   // macOS
    gpubus_pci,       // Windows: \\.\DISPLAY
    vendor_adl,       // AMD ADL
    vendor_nvapi,     // NVIDIA
    vendor_igcl,      // Intel
};

/// Backend zgłasza, co MA; probe deklaruje, czego POTRZEBUJE.
pub const Capabilities = struct {
    bitset: u64,               // bit per Capability
    reasons: []const Unavailable,  // czemu brak (dla UI i logu)

    pub fn has(self: Capabilities, c: Capability) bool;
};

/// Deklaracja wymagań probe'a — sprawdzana PRZED startem, nie w trakcie.
pub const Requirements = struct {
    needs: CapabilitySet,
    optional: CapabilitySet,   // brak = degrade, nie skip
    min_access: AccessLevel,   // .user .service .driver
};
```

`min_access` jest kluczowe: pozwala CLI napisać **„ta sekcja wymaga sterownika,
zacznij `ferrumscope service install`"** zamiast zwracać pustkę.

### Allowlist MSR (zasada bezpieczeństwa)

Sterownik **nie** udostępnia dowolnych MSR. Zamknięta lista, wbudowana w oba końce:

| MSR | Zastosowanie |
|---|---|
| `0x150` | TDP/PL1 |
| `0x16F` | TDC |
| `0x610` | PL2 / turbo power |
| `0x611` | turbo ratio limits |
| `0x613` | turbo ratios per core |
| `0x640` | turbo activation ratio |
| `0x64C` | turbo ratio limits (atom) |
| `0x770` | perf status / turbo ratio |
| `0x771` | perf control |
| `0x774` | core perf status |
| `0x1A0` | Thermal/power (mobile) |
| `0xC8` | `MSR_IA32_PERF_STATUS` — RDT |

Zapis do MSR: domyślnie **wyłączony**; wymaga jawnego `--allow-msr-write` i wpisu
na listę dozwolonych. To jest kompromis między „aż poinformować o limicie" a
„nie zostawić użytkownika z uszkodzoną maszyną".

---

## 10. Wielofazowe skanowanie

```
faza 0  OS + arch + CPUID              ~0 ms      (CPUID to kilka set)
faza 1  FAST (równolegle, budżet ~120 ms)
        ├─ pamięć: SMBIOS type 17        zależy: nic
        ├─ płyta:  SMBIOS type 0/1/2     zależy: nic
        ├─ OS:      jądro, dystrybucja  zależy: nic
        ├─ GPU:     SetupDi/sysfs/PCI    zależy: pci_config
        └─ storage: namespace / \\.\PhysicalDrive  zależy: nic
             ↓  UI pokazuje pierwszy użyteczny wynik
faza 2  DEEP (w tle, anulowalna)
        ├─ cache/TLB z CPUID 0x4/0x80000005   zależy: cpuid
        ├─ PCIe link z config space            zależy: pci_config
        ├─ MSR (allowlist)                     zależy: msr_read
        ├─ SPD modułów RAM                     zależy: smbus
        └─ NVMe identify                       zależy: io_ports
             ↓
faza 3  ON-DEMAND (tylko na żądanie)
        ├─ Super I/O (vendor ID)         zależy: io_ports
        ├─ VRM / phase controller        zależy: i2c
        ├─ fan controllers                zależy: i2c
        └─ głęboka telemetryka GPU       zależy: vendor_*
```

**Budżet czasu zamiast gołego „timeout":** każdy probe dostaje `deadline`
i `CancellationToken`. Odpowiada na `cancel` w bezpiecznym punkcie (po I/O, nie w trakcie).
Limity: fast 120 ms, deep 3 s, on-demand bez limitu (jawnie uruchamiany).

**Antywzorzec, którego unikamy:** CPU-Z/GPU-Z nie mają twardego podziału faz i mogą
zablokować UI na wolnym probe. U nas wolny probe **nigdy** nie blokuje fazy 1 — dostaje
osobny wątek i timeout, a wynik wraca jako `Status.timeout`.

### Dependency graph jako typ

```zig
pub const Node = enum { cpuid, smbios, pci_config, msr, smbus, i2c, io_ports, vendor_api, ... };

pub const Edge = struct { from: Node, to: Node, required: bool };
//                 ^-- to musi się wykonać, zanim from ruszy

pub const Plan = struct {
    nodes: []const NodeSpec,   // { node, phase, deadline_ms, requirements }
    edges: []const Edge,
    // Topologiczne sortowanie + wykrywanie cykli przy budowie planu.
    // Cykl to błąd kompilacji planu, nie sytuacja runtime.
};
```

---

## 11. Podział backendów platformowych

Kontrakt jest jeden — `platform/backend.zig`:

```zig
pub const Backend = struct {
    caps: Capabilities,
    cpuid: ?*const CpuidProvider,
    pci: ?*const PciProvider,
    io: ?*const IoProvider,     // port I/O + MMIO + MSR
    smbus: ?*const SmbusProvider,
    nvme: ?*const NvmeProvider,
    os_info: ?*const OsInfoProvider,
    sysfs_fs: ?*const FileSystem,   // Linux: /sys; USOS: własny VFS
};
```

### Windows
- **User-mode wystarczy dla:** CPUID, SetupDi (PCI config, SMBIOS przez `WMI`),
  storage przez `IOCTL`, GPU przez `SetupDiGetDeviceInstanceIdW` + ADL/NVAPI.
- **Wymaga sterownika dla:** MSR, port I/O, MMIO PCI, Super I/O, SPD (SMBus).
- Sterownik: `src/platform/windows/driver/`. Zakres dozwolony:
  `MmMapIoSpace`, `READ_PORT_*`, `WRITE_PORT_*`, `KeGetCurrentProcessor`,
  wewnętrzny `RDMSR` dla allowlisty, `IRP_MJ_DEVICE_CONTROL`.
  **Zero logiki identyfikacyjnej.** Zero „Jeśli vendor == 0x10DE to…".
- Instalacja: podpisany serwis, `ferrumscope service install`, komunikat z linkiem
  do instrukcji przy braku uprawnień. Tryb bez serwisu działa z jawnymi `Status.denied`.

### Linux
- Kolejność: **najpierw interfejs kernela.** sysfs → hwmon → DRM → ioctl → dopiero
  dostęp bezpośredni.
- `pci_config` przez sysfs `/sys/bus/pci/devices/*/config` i/lub `libpciaccess`
  albo `pread` na `/dev/mem` (ostatnia instancja, z ostrzeżeniem).
- MSR przez `/dev/cpu/N/msr` — **już jest gotowy w jądrze**, nie piszemy modułu.
- NVMe przez ioctl na `/dev/nvmeN`, SPD przez `ee1004`/`at24`, Super I/O przez `/dev/port`.
- Cel: `ferrumscope` bez roota ma działać dla 90% informacji.

### macOS
- Intel: `sysctlbyname` (`machdep.cpu.*`, `hw.*`), IOKit (`IOService`, `IOPCIDevice`),
  SMC przez `AppleSMC` dla temperatur.
- Apple Silicon: `sysctl hw.*` (rdpru/performance counters), IOKit dla GPU,
  **`hw.model` + `cpus.*`** jako źródło identyfikacji (brak CPUID).
- Różnica w dekoderze, nie w rdzeniu: `decode/cpu/arm64.zig` konsumuje
  `RawCpuInfo{ .arch = .arm64, ... }` wypełnionym z sysctl.
- Jeśli czegoś nie da się uzyskać bez prywatnego API → `Status.unsupported`.
  Żadnych kruchy hacków.

### USOS
- Core nie może importować niczego desktopowego. Warunek: kompilacja `core` +
  `decode` + `db` **bez** libc, bez libc++, bez wywołań systemowych.
- `platform/usos/` implementuje `Backend` na minimalnym VFS + wewnętrznym RPC
  do usługi diagnostycznej.
- Test: `zig build test-core` musi przechodzić na buildzie `-Dtarget=usos-min`.

---

## 12. Plan pierwszej wersji — **CPU-only**

Cel: `ferrumscope` (CLI) + `ferrumscope-gui` (odkładany), poprawna identyfikacja CPU
na Windows/Linux/macOS w <150 ms, z capture/replay.

### Etap 1 — fundament (bez I/O)
- `core/`, `arch/x86/cpuid.zig`, `decode/cpu/x86.zig`, model + `Status`.
- Testy na **ręcznie skonstruowanych** obrazach CPUID (bez sprzętu).

### Etap 2 — platformy
- `platform/{linux,windows,macos}/` dla `cpuid` + `os_info` + `smbios`.
- Sterownik: **odkładany do Etapu 4** — w Etapie 2 działa `--no-driver`.

### Etap 3 — baza
- `db/source/cpu/{intel,amd,apple}.toml`, kompilator, `ferrum-hwdb.bin`,
  wbudowany snapshot.
- Test: „dla N konkretnych sygnatur CPUID zwracamy X" jako tabela golden.

### Etap 4 — capture/replay
- `.fcap` zapis/odczyt, `replay` jako backend, złote pliki w `db/fixtures/`.
- To jest moment, w którym projekt staje się testowalny na CI bez sprzętu.

### Etap 5 — MSR i sterownik (Windows)
- Driver w C, allowlist z §9, podpisany, testowany ręcznie.

### Etap 6 — CLI
```
ferrumscope                     # fast scan, czytelne podsumowanie
ferrumscope cpu --json          # pełny model
ferrumscope cpu --raw           # surowe CPUID
ferrumscope explain cpu         # skąd wziął każde pole
ferrumscope capture out.fcap
ferrumscope replay out.fcap
ferrumscope hwdb check          # walidacja bazy
```

`explain` jest ważniejszy, niż się wydaje: to odpowiedź na pytanie
„skąd FerrumScope wie, że to jest Ryzen 9 5950X?" — i natychmiast pokazuje,
czy baza kłamie.

### Poza zakresem v1 (świadomie)
GUI, GPU (pełne), benchmarki, stress testy, płyta, sensory.

---

## 13. Metryki sukcesu v1

| Metryka | Cel |
|---|---|
| Czas do pierwszego wyniku CPU | < 15 ms |
| Czas pełnego fast scanu | < 150 ms (p99, laptop klasy 2018) |
| Poprawność family/model/stepping | 100 % na złotych plikach `.fcap` |
| Pokrycie nazw CPU | ≥ 99 % SKU z 3 ostatnich generacji każdego producenta |
| Zależności `core` | 0 (brak libc, brak OS) |
| Testy bez sprzętu | 100 % przez `replay` |

Poprawność identyfikacji sprawdzamy **wyłącznie** przez `replay` złotych plików —
CPU-Z/GPU-Z służą tu wyłącznie jako **oracle porównawcze** w `tools/refext/`,
nigdy jako źródło danych produktu.
