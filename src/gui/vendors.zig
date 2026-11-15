//! Rozpoznawanie producentów (płyta główna, chipset, pamięć, dyski, CPU, GPU)
//! i łańcuch obrazów / logo dla plakietek w GUI.
//!
//! Wejścia:
//!   - SMBIOS typ 2 (producent płyty), typ 17 (producent modułu pamięci — nazwa
//!     albo kod JEDEC JEP106 w postaci szesnastkowej, np. „04CD”, „80CE”),
//!   - STORAGE_DEVICE_DESCRIPTOR (producent / model dysku, np. „WDC WD40EFRX”,
//!     „ST12000NM0127”, „CT1000P3SSD8”),
//!   - identyfikator producenta PCI (`pciVendor`),
//!   - napis producenta z CPUID liść 0 (`cpuVendor`).
//! Wynik to **klucz producenta** (małe litery, np. `asrock`, `skhynix`,
//! `western-digital`) — ten sam co nazwa pliku `assets/logos/<klucz>.png`.
//!
//! Kolejność wyboru obrazu (`logoChain`, jak w `badge.zig`):
//!   1. obraz użytkownika `data\images\<kategoria>\<klucz>-<model>.png`,
//!      potem `data\images\<kategoria>\<klucz>.png` (ścieżki zwracane względem
//!      `data\images\`),
//!   2. logo dołączone `assets/logos/<klucz>.png` (oraz klucz ogólniejszy,
//!      np. `nvidia-nforce` → `nvidia`),
//!   3. rysowana plakietka z tekstem `displayName(klucz)` albo surowej nazwy.
//!
//! Moduł jest czysty (bez Win32) i testowany.

const std = @import("std");

// ---------------------------------------------------------------------------
// Nazwy wyświetlane
// ---------------------------------------------------------------------------

const Display = struct { key: []const u8, name: []const u8 };

const display_names = [_]Display{
    .{ .key = "asrock", .name = "ASRock" },
    .{ .key = "asus", .name = "ASUS" },
    .{ .key = "msi", .name = "MSI" },
    .{ .key = "gigabyte", .name = "GIGABYTE" },
    .{ .key = "biostar", .name = "BIOSTAR" },
    .{ .key = "evga", .name = "EVGA" },
    .{ .key = "supermicro", .name = "Supermicro" },
    .{ .key = "gskill", .name = "G.SKILL" },
    .{ .key = "corsair", .name = "Corsair" },
    .{ .key = "kingston", .name = "Kingston" },
    .{ .key = "crucial", .name = "Crucial" },
    .{ .key = "micron", .name = "Micron" },
    .{ .key = "samsung", .name = "Samsung" },
    .{ .key = "skhynix", .name = "SK hynix" },
    .{ .key = "teamgroup", .name = "TEAMGROUP" },
    .{ .key = "adata", .name = "ADATA" },
    .{ .key = "patriot", .name = "Patriot" },
    .{ .key = "western-digital", .name = "WD" },
    .{ .key = "seagate", .name = "Seagate" },
    .{ .key = "toshiba", .name = "Toshiba" },
    .{ .key = "kioxia", .name = "KIOXIA" },
    .{ .key = "lexar", .name = "Lexar" },
    .{ .key = "sandisk", .name = "SanDisk" },
    .{ .key = "amd", .name = "AMD" },
    .{ .key = "ati", .name = "ATI" },
    .{ .key = "intel", .name = "Intel" },
    .{ .key = "nvidia", .name = "NVIDIA" },
    .{ .key = "nvidia-nforce", .name = "nForce" },
    .{ .key = "via", .name = "VIA" },
    .{ .key = "sis", .name = "SiS" },
    .{ .key = "ali", .name = "ALi" },
    .{ .key = "uli", .name = "ULi" },
    .{ .key = "serverworks", .name = "ServerWorks" },
    .{ .key = "broadcom", .name = "Broadcom" },
    .{ .key = "zhaoxin", .name = "Zhaoxin" },
    .{ .key = "hygon", .name = "Hygon" },
    .{ .key = "3dfx", .name = "3dfx" },
    .{ .key = "matrox", .name = "Matrox" },
    .{ .key = "s3", .name = "S3" },
    .{ .key = "xgi", .name = "XGI" },
    .{ .key = "powervr", .name = "PowerVR" },
    .{ .key = "cyrix", .name = "Cyrix" },
    .{ .key = "centaur", .name = "Centaur" },
    .{ .key = "transmeta", .name = "Transmeta" },
    .{ .key = "nexgen", .name = "NexGen" },
    .{ .key = "rise", .name = "Rise" },
    .{ .key = "nsc", .name = "NSC" },
    .{ .key = "umc", .name = "UMC" },
    .{ .key = "vortex86", .name = "Vortex86" },
    .{ .key = "sapphire", .name = "Sapphire" },
    .{ .key = "powercolor", .name = "PowerColor" },
    .{ .key = "xfx", .name = "XFX" },
    .{ .key = "zotac", .name = "ZOTAC" },
    .{ .key = "palit", .name = "Palit" },
    .{ .key = "gainward", .name = "Gainward" },
    .{ .key = "pny", .name = "PNY" },
    .{ .key = "inno3d", .name = "INNO3D" },
    .{ .key = "galax", .name = "GALAX" },
    .{ .key = "colorful", .name = "Colorful" },
    .{ .key = "yeston", .name = "Yeston" },
    .{ .key = "maxsun", .name = "MAXSUN" },
    .{ .key = "his", .name = "HIS" },
    .{ .key = "dell", .name = "Dell" },
    .{ .key = "hp", .name = "HP" },
    .{ .key = "lenovo", .name = "Lenovo" },
    .{ .key = "acer", .name = "Acer" },
};

/// Nazwa do rysowanej plakietki; nieznany klucz zwracany bez zmian.
pub fn displayName(key: []const u8) []const u8 {
    for (display_names) |d| {
        if (std.mem.eql(u8, d.key, key)) return d.name;
    }
    return key;
}

// ---------------------------------------------------------------------------
// normalize: napis producenta / modelu → klucz
// ---------------------------------------------------------------------------

/// Wartości zastępcze z SMBIOS / dysków — brak informacji.
const placeholders = [_][]const u8{
    "unknown",                 "to be filled by o.e.m.", "to be filled by oem", "default string",
    "not specified",           "not available",          "none",                "n/a",
    "na",                      "oem",                    "o.e.m.",              "system manufacturer",
    "undefined",               "empty",                  "not applicable",      "fill by oem",
    "base board manufacturer",
};

fn isPlaceholder(s: []const u8) bool {
    for (placeholders) |p| {
        if (std.ascii.eqlIgnoreCase(s, p)) return true;
    }
    // „Manufacturer00”, „Manufacturer01”… (puste pola SPD w niektórych BIOS-ach).
    if (std.ascii.startsWithIgnoreCase(s, "manufacturer")) return true;
    // Same zera / same F (np. „00000000”, „FFFF”).
    var all_zero = true;
    var all_f = true;
    for (s) |c| {
        if (c != '0') all_zero = false;
        if (c != 'F' and c != 'f') all_f = false;
    }
    return all_zero or all_f;
}

/// Kody JEDEC JEP106 (bank liczony od 1, kod z bitem nieparzystości).
/// Źródło: JEDEC JEP106 w wersji z tabeli `@vendors` programu decode-dimms
/// (i2c-tools, git.kernel.org/pub/scm/utils/i2c-tools/i2c-tools.git,
/// eeprom/decode-dimms), sprawdzone 2026-11-15.
/// W SMBIOS typ 17 pierwszy bajt to liczba kodów kontynuacji (0x7F) z bitem
/// nieparzystości (bank 1 → 0x80, bank 2 → 0x01, bank 3 → 0x02, bank 6 → 0x85),
/// drugi to kod producenta — stąd np. „80CE” (Samsung), „0198” (Kingston).
const Jedec = struct { bank: u8, code: u8, key: []const u8 };

const jedec_codes = [_]Jedec{
    .{ .bank = 1, .code = 0x2C, .key = "micron" }, // Micron Technology
    .{ .bank = 1, .code = 0xAD, .key = "skhynix" }, // SK Hynix (dawniej Hyundai Electronics)
    .{ .bank = 1, .code = 0xCE, .key = "samsung" }, // Samsung
    .{ .bank = 2, .code = 0x98, .key = "kingston" }, // Kingston
    .{ .bank = 3, .code = 0x9E, .key = "corsair" }, // Corsair
    .{ .bank = 5, .code = 0xCB, .key = "adata" }, // A-DATA Technology
    .{ .bank = 5, .code = 0xCD, .key = "gskill" }, // G Skill Intl
    .{ .bank = 5, .code = 0xEF, .key = "teamgroup" }, // Team Group Inc.
    .{ .bank = 6, .code = 0x02, .key = "patriot" }, // Patriot Memory
    .{ .bank = 6, .code = 0x9B, .key = "crucial" }, // Crucial Technology
    // Pominięte celowo: samo „98” / „9E” / „9B” bez banku. W banku 1 te kody
    // należą do innych firm (0x98 = Kioxia, 0x9E = Exel, 0x9B = Eurotechnique),
    // więc bez numeru banku nie da się ich jednoznacznie przypisać do
    // Kingstona / Corsaira / Crucial.
};

fn hexVal(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

fn hexByte(s: []const u8) ?u8 {
    const hi = hexVal(s[0]) orelse return null;
    const lo = hexVal(s[1]) orelse return null;
    return hi * 16 + lo;
}

fn isHex(s: []const u8) bool {
    for (s) |c| if (hexVal(c) == null) return false;
    return true;
}

fn jedecLookup(bank: u8, code: u8) ?[]const u8 {
    for (jedec_codes) |j| {
        if (j.bank == bank and j.code == code) return j.key;
    }
    return null;
}

/// Bajt kontynuacji: liczba 0..15 z bitem 7 dopełniającym do nieparzystości.
fn continuationBank(b: u8) ?u8 {
    const n = b & 0x7F;
    if (n > 15) return null;
    if (@popCount(b) % 2 != 1) return null;
    return n + 1;
}

/// Kod JEDEC zapisany szesnastkowo: „80CE”, „0198”, „80CE000080CE”,
/// „CE00000000000000” (kod, potem zera — bank 1) albo krótkie „CE”.
fn jedecKey(s: []const u8) ?[]const u8 {
    if (s.len < 2 or s.len > 16 or s.len % 2 != 0 or !isHex(s)) return null;
    const b0 = hexByte(s[0..2]).?;
    if (s.len == 2) {
        // Sam kod bez banku: tylko jednoznaczne kody z banku 1.
        return switch (b0) {
            0x2C, 0xAD, 0xCE => jedecLookup(1, b0),
            else => null,
        };
    }
    const b1 = hexByte(s[2..4]).?;
    // Część BIOS-ów pomija bit nieparzystości dla banku 1 („00CE” zamiast „80CE”).
    if (b0 == 0x00) return jedecLookup(1, b1);
    if (continuationBank(b0)) |bank| {
        if (jedecLookup(bank, b1)) |k| return k;
    }
    // Odwrotny zapis „CE00…”: kod producenta z banku 1, a po nim zera.
    if (b1 == 0 and continuationBank(b0) == null) return jedecLookup(1, b0);
    return null;
}

/// Fragmenty nazwy (małe litery, tylko [a-z0-9], sklejone) → klucz.
/// Kolejność ma znaczenie (np. `supermicro` przed `micron`, `kioxia` przed `toshiba`).
const Rule = struct { needle: []const u8, key: []const u8 };

const joined_rules = [_]Rule{
    .{ .needle = "supermicro", .key = "supermicro" },
    .{ .needle = "microstar", .key = "msi" },
    .{ .needle = "asrock", .key = "asrock" },
    .{ .needle = "asustek", .key = "asus" },
    .{ .needle = "gigabyte", .key = "gigabyte" },
    .{ .needle = "biostar", .key = "biostar" },
    .{ .needle = "evga", .key = "evga" },
    .{ .needle = "gskill", .key = "gskill" },
    .{ .needle = "corsair", .key = "corsair" },
    .{ .needle = "kingston", .key = "kingston" },
    .{ .needle = "crucial", .key = "crucial" },
    .{ .needle = "hynix", .key = "skhynix" },
    .{ .needle = "hyundaielectronics", .key = "skhynix" },
    .{ .needle = "micron", .key = "micron" },
    .{ .needle = "samsung", .key = "samsung" },
    .{ .needle = "teamgroup", .key = "teamgroup" },
    .{ .needle = "adata", .key = "adata" },
    .{ .needle = "patriot", .key = "patriot" },
    .{ .needle = "westerndigital", .key = "western-digital" },
    .{ .needle = "seagate", .key = "seagate" },
    .{ .needle = "kioxia", .key = "kioxia" },
    .{ .needle = "toshiba", .key = "toshiba" },
    .{ .needle = "lexar", .key = "lexar" },
    .{ .needle = "sandisk", .key = "sandisk" },
    .{ .needle = "atitechnologies", .key = "ati" },
    .{ .needle = "viatechnologies", .key = "via" },
    .{ .needle = "siliconintegratedsystems", .key = "sis" },
    .{ .needle = "acerlab", .key = "ali" },
    .{ .needle = "ulielectronics", .key = "uli" },
    .{ .needle = "serverworks", .key = "serverworks" },
    .{ .needle = "broadcom", .key = "broadcom" },
    .{ .needle = "zhaoxin", .key = "zhaoxin" },
    .{ .needle = "hygon", .key = "hygon" },
    .{ .needle = "haiguang", .key = "hygon" },
    .{ .needle = "3dfx", .key = "3dfx" },
    .{ .needle = "matrox", .key = "matrox" },
    .{ .needle = "s3graphics", .key = "s3" },
    .{ .needle = "xgitechnology", .key = "xgi" },
    .{ .needle = "powervr", .key = "powervr" },
    .{ .needle = "videologic", .key = "powervr" },
    .{ .needle = "cyrix", .key = "cyrix" },
    .{ .needle = "centaur", .key = "centaur" },
    .{ .needle = "transmeta", .key = "transmeta" },
    .{ .needle = "nexgen", .key = "nexgen" },
    .{ .needle = "nationalsemiconductor", .key = "nsc" },
    .{ .needle = "unitedmicroelectronics", .key = "umc" },
    .{ .needle = "vortex86", .key = "vortex86" },
    .{ .needle = "advancedmicrodevices", .key = "amd" },
    .{ .needle = "nvidia", .key = "nvidia" },
};

/// Krótkie nazwy — tylko jako całe słowo (żeby „msi” nie trafiało w środek innych słów).
const token_rules = [_]Rule{
    .{ .needle = "asus", .key = "asus" },
    .{ .needle = "msi", .key = "msi" },
    .{ .needle = "wd", .key = "western-digital" },
    .{ .needle = "wdc", .key = "western-digital" },
    .{ .needle = "ati", .key = "ati" },
    .{ .needle = "via", .key = "via" },
    .{ .needle = "sis", .key = "sis" },
    .{ .needle = "ali", .key = "ali" },
    .{ .needle = "uli", .key = "uli" },
    .{ .needle = "s3", .key = "s3" },
    .{ .needle = "xgi", .key = "xgi" },
    .{ .needle = "umc", .key = "umc" },
    .{ .needle = "nsc", .key = "nsc" },
    .{ .needle = "amd", .key = "amd" },
    .{ .needle = "intel", .key = "intel" },
    .{ .needle = "team", .key = "teamgroup" },
    .{ .needle = "teamgroup", .key = "teamgroup" },
    .{ .needle = "skhynix", .key = "skhynix" },
};

/// Przedrostki numerów modeli dysków (pierwsze słowo, wielkie litery).
/// `digit` = po przedrostku musi stać cyfra (np. „ST” + „12000…”).
const Prefix = struct { prefix: []const u8, digit: bool, key: []const u8 };

const model_prefixes = [_]Prefix{
    .{ .prefix = "ST", .digit = true, .key = "seagate" }, // ST12000NM0127, ST2000DM008
    .{ .prefix = "WD", .digit = true, .key = "western-digital" }, // WD40EFRX-68N32N0
    .{ .prefix = "CT", .digit = true, .key = "crucial" }, // CT1000P3SSD8, CT500MX500SSD1
    .{ .prefix = "MTFD", .digit = false, .key = "micron" }, // MTFDKBA512TFH
    .{ .prefix = "HFS", .digit = true, .key = "skhynix" }, // HFS512GDE9X081N
    .{ .prefix = "HFM", .digit = true, .key = "skhynix" }, // HFM512GD3JX013N
    .{ .prefix = "MZ-", .digit = false, .key = "samsung" }, // MZ-V8V1T0
    .{ .prefix = "MZV", .digit = false, .key = "samsung" }, // MZVL2512HCJQ
    .{ .prefix = "MZ7", .digit = false, .key = "samsung" }, // MZ7LN256HAJQ
    .{ .prefix = "SA400", .digit = false, .key = "kingston" }, // SA400S37240G
    .{ .prefix = "SNV", .digit = true, .key = "kingston" }, // SNV2S1000G
    .{ .prefix = "SKC", .digit = true, .key = "kingston" }, // SKC3000D2048G
    .{ .prefix = "SDSSD", .digit = false, .key = "sandisk" }, // SDSSDH3-1T00
    .{ .prefix = "KXG", .digit = true, .key = "kioxia" }, // KXG60ZNV256G
    .{ .prefix = "KBG", .digit = true, .key = "kioxia" }, // KBG40ZNS256G
    .{ .prefix = "THNSN", .digit = false, .key = "toshiba" }, // THNSNJ256GCSU
    .{ .prefix = "DT01", .digit = false, .key = "toshiba" }, // DT01ACA300
    .{ .prefix = "HDWD", .digit = false, .key = "toshiba" }, // HDWD110
    .{ .prefix = "MG0", .digit = true, .key = "toshiba" }, // MG08ACA16TE
};

/// Pierwsze słowa pomijane przy przedrostkach (pole producenta z warstwy SCSI/ATA).
const generic_first = [_][]const u8{ "ata", "nvme", "scsi", "sata", "usb" };

fn trim(raw: []const u8) []const u8 {
    return std.mem.trim(u8, raw, " \t\r\n\x00");
}

fn prefixKey(word: []const u8) ?[]const u8 {
    for (model_prefixes) |p| {
        if (word.len <= p.prefix.len) continue;
        if (!std.ascii.startsWithIgnoreCase(word, p.prefix)) continue;
        if (p.digit and !std.ascii.isDigit(word[p.prefix.len])) continue;
        return p.key;
    }
    return null;
}

/// Producent płyty / pamięci / dysku → klucz producenta (`null` = nieznany
/// lub wartość zastępcza). Przyjmuje nazwę firmy, kod JEDEC albo model dysku.
pub fn normalize(raw: []const u8) ?[]const u8 {
    const s = trim(raw);
    if (s.len == 0 or isPlaceholder(s)) return null;
    if (jedecKey(s)) |k| return k;

    // Sklejone małe litery/cyfry (do 128 znaków).
    var jb: [128]u8 = undefined;
    var jn: usize = 0;
    for (s) |c| {
        if (jn >= jb.len) break;
        if (std.ascii.isAlphanumeric(c)) {
            jb[jn] = std.ascii.toLower(c);
            jn += 1;
        }
    }
    const joined = jb[0..jn];
    for (joined_rules) |r| {
        if (std.mem.indexOf(u8, joined, r.needle) != null) return r.key;
    }

    // Słowa (granice: wszystko poza [A-Za-z0-9]).
    var it = std.mem.tokenizeAny(u8, s, " \t,.;:/\\()[]-_");
    var first: ?[]const u8 = null;
    while (it.next()) |w| {
        for (token_rules) |r| {
            if (std.ascii.eqlIgnoreCase(w, r.needle)) return r.key;
        }
        if (first == null) {
            var generic = false;
            for (generic_first) |g| {
                if (std.ascii.eqlIgnoreCase(w, g)) generic = true;
            }
            if (!generic) first = w;
        }
    }

    // Numer modelu dysku bez nazwy producenta (np. „ST12000NM0127”).
    // Słowa dzielone tylko po spacjach, żeby „MZ-V8V1T0” zachował myślnik.
    var it2 = std.mem.tokenizeAny(u8, s, " \t");
    while (it2.next()) |w| {
        var generic = false;
        for (generic_first) |g| {
            if (std.ascii.eqlIgnoreCase(w, g)) generic = true;
        }
        if (generic) continue;
        return prefixKey(w);
    }
    return null;
}

// ---------------------------------------------------------------------------
// PCI i CPUID
// ---------------------------------------------------------------------------

/// Identyfikator producenta PCI → klucz (sprawdzone z db/source/pci/pci.ids).
pub fn pciVendor(vid: u16) ?[]const u8 {
    return switch (vid) {
        // 0x1002 to „AMD/ATI” — urządzenia sprzed 2006 r. są ATI, ale bez
        // identyfikatora urządzenia nie da się tego rozstrzygnąć: zawsze „amd”.
        0x1022, 0x1002 => "amd",
        0x8086 => "intel",
        0x10DE => "nvidia",
        0x1106 => "via",
        0x1039 => "sis",
        0x10B9 => "ali", // Acer Labs, od 2003 ULi Electronics
        0x1166 => "serverworks", // w pci.ids „Broadcom” (dawny ServerWorks)
        0x14E4 => "broadcom",
        0x1D17 => "zhaoxin",
        0x1D94 => "hygon", // Chengdu Haiguang IC Design
        0x121A => "3dfx",
        0x102B => "matrox",
        0x5333 => "s3",
        0x18CA => "xgi",
        0x1010 => "powervr", // Video Logic (PowerVR)
        0x1078 => "cyrix",
        0x100B => "nsc", // National Semiconductor
        else => null,
    };
}

/// Producent karty graficznej z identyfikatora producenta podsystemu PCI
/// (SUBSYS_ddddvvvv → vvvv). Każdy identyfikator sprawdzony z
/// db/source/pci/pci.ids. Identyfikatory producentów chipów (1002, 10DE, 8086)
/// nie są tu mapowane — to karty referencyjne (`isReference`).
pub fn gpuPartner(subvendor: u16) ?[]const u8 {
    return switch (subvendor) {
        0x1849 => "asrock", // ASRock Incorporation
        0x1043 => "asus", // ASUSTeK Computer Inc.
        0x1462 => "msi", // Micro-Star International Co., Ltd. [MSI]
        0x1458 => "gigabyte", // Gigabyte Technology Co., Ltd
        0x1DA2, 0x174B => "sapphire", // Sapphire Technology Limited; PC Partner Limited / Sapphire Technology
        0x148C => "powercolor", // Tul Corporation / PowerColor
        0x1682 => "xfx", // XFX Pine Group Inc.
        0x19DA => "zotac", // ZOTAC International (MCO) Ltd.
        0x1569 => "palit", // Palit Microsystems Inc.
        0x10B0 => "gainward", // CardExpert Technology (marka Gainward)
        0x196E => "pny", // PNY
        0x3842 => "evga", // EVGA Corporation
        0x1771 => "inno3d", // InnoVISION Multimedia Ltd. (Inno3D)
        0x1B4C => "galax", // GALAX (także KFA2)
        0x7377 => "colorful", // Shenzhen Colorful Yugong Technology and Development Co.
        0x1ED3 => "yeston", // Yeston
        0x6688 => "maxsun", // Guangzhou Maxsun Information Technology Co., Ltd.
        0x1565 => "biostar", // Biostar Microtech Int'l Corp
        0x17AF, 0x1787 => "his", // Hightech Information System Ltd. (HIS)
        0x1028 => "dell", // Dell
        0x103C => "hp", // Hewlett-Packard Company
        0x17AA => "lenovo", // Lenovo
        0x1025 => "acer", // Acer Incorporated [ALI]
        else => null,
    };
}

/// Karta referencyjna: podsystem równy producentowi chipu albo pusty.
pub fn isReference(chip_vendor: u16, subvendor: u16) bool {
    return subvendor == 0 or subvendor == chip_vendor;
}

/// Producent podsystemu z pola SUBSYS (np. 0x53041849 → 0x1849).
pub fn subsystemVendor(subsys: u32) u16 {
    return @truncate(subsys);
}

const CpuId = struct { id: []const u8, key: []const u8 };

const cpu_vendor_strings = [_]CpuId{
    .{ .id = "AuthenticAMD", .key = "amd" },
    .{ .id = "AMDisbetter!", .key = "amd" }, // wczesne próbki K5
    .{ .id = "GenuineIntel", .key = "intel" },
    .{ .id = "CyrixInstead", .key = "cyrix" },
    .{ .id = "CentaurHauls", .key = "centaur" },
    .{ .id = "VIA VIA VIA ", .key = "via" },
    .{ .id = "GenuineTMx86", .key = "transmeta" },
    .{ .id = "TransmetaCPU", .key = "transmeta" },
    .{ .id = "NexGenDriven", .key = "nexgen" },
    .{ .id = "RiseRiseRise", .key = "rise" },
    .{ .id = "Geode by NSC", .key = "nsc" },
    .{ .id = "  Shanghai  ", .key = "zhaoxin" },
    .{ .id = "HygonGenuine", .key = "hygon" },
    .{ .id = "UMC UMC UMC ", .key = "umc" },
    .{ .id = "SiS SiS SiS ", .key = "sis" },
    .{ .id = "Vortex86 SoC", .key = "vortex86" },
};

/// Napis producenta z CPUID (12 znaków) → klucz. Porównanie dokładne,
/// a gdy się nie uda — po obcięciu spacji (np. „Shanghai”).
pub fn cpuVendor(vendor_string: []const u8) ?[]const u8 {
    for (cpu_vendor_strings) |c| {
        if (std.mem.eql(u8, c.id, vendor_string)) return c.key;
    }
    const t = trim(vendor_string);
    if (t.len == 0) return null;
    for (cpu_vendor_strings) |c| {
        if (std.mem.eql(u8, trim(c.id), t)) return c.key;
    }
    return null;
}

// ---------------------------------------------------------------------------
// Łańcuch obrazów i logo
// ---------------------------------------------------------------------------

pub const Category = enum {
    board,
    chipset,
    memory,
    storage,
    cpu,
    gpu,

    fn dir(self: Category) []const u8 {
        return switch (self) {
            .board => "board\\",
            .chipset => "chipset\\",
            .memory => "memory\\",
            .storage => "storage\\",
            .cpu => "cpu\\",
            .gpu => "gpu\\",
        };
    }
};

pub const ChainBuf = struct {
    storage: [3][128]u8 = undefined,
    images: [3][]const u8 = undefined,
    logos: [2][]const u8 = undefined,
};

pub const Chain = struct {
    /// Ścieżki względem `data\images\`, w kolejności prób.
    images: []const []const u8,
    /// Klucze logo dołączonych (`assets/logos/<klucz>.png`), od najbardziej szczegółowego.
    logos: []const []const u8,
};

/// Nazwa pliku: małe litery, ciągi znaków spoza [a-z0-9] → pojedynczy `-`.
fn stem(out: []u8, s: []const u8) []const u8 {
    var n: usize = 0;
    var dash = false;
    for (s) |c| {
        if (std.ascii.isAlphanumeric(c)) {
            if (dash and n > 0 and n < out.len) {
                out[n] = '-';
                n += 1;
            }
            dash = false;
            if (n < out.len) {
                out[n] = std.ascii.toLower(c);
                n += 1;
            }
        } else dash = true;
    }
    return out[0..n];
}

/// Łańcuch: obrazy użytkownika `<kategoria>\<klucz>-<model>.png` →
/// `<kategoria>\<klucz>.png` (bez klucza: `<kategoria>\<model>.png`), potem
/// logo dołączone `<klucz>` (dla chipsetu NVIDIA najpierw `nvidia-nforce`).
/// Pusta lista logo = rysowana plakietka z `displayName`.
pub fn logoChain(category: Category, key: ?[]const u8, model: []const u8, b: *ChainBuf) Chain {
    var ni: usize = 0;
    var ms: [96]u8 = undefined;
    const m = stem(&ms, model);
    const d = category.dir();
    if (key) |k| {
        if (m.len > 0) {
            if (std.fmt.bufPrint(&b.storage[ni], "{s}{s}-{s}.png", .{ d, k, m })) |s| {
                b.images[ni] = s;
                ni += 1;
            } else |_| {}
        }
        if (std.fmt.bufPrint(&b.storage[ni], "{s}{s}.png", .{ d, k })) |s| {
            b.images[ni] = s;
            ni += 1;
        } else |_| {}
    } else if (m.len > 0) {
        if (std.fmt.bufPrint(&b.storage[ni], "{s}{s}.png", .{ d, m })) |s| {
            b.images[ni] = s;
            ni += 1;
        } else |_| {}
    }

    var nl: usize = 0;
    if (key) |k| {
        if (category == .chipset and std.mem.eql(u8, k, "nvidia")) {
            b.logos[nl] = "nvidia-nforce";
            nl += 1;
        }
        b.logos[nl] = k;
        nl += 1;
        if (std.mem.eql(u8, k, "nvidia-nforce")) {
            b.logos[nl] = "nvidia";
            nl += 1;
        }
    }
    return .{ .images = b.images[0..ni], .logos = b.logos[0..nl] };
}

// ---------------------------------------------------------------------------
// Testy
// ---------------------------------------------------------------------------

const testing = std.testing;

fn hasDisplayName(key: []const u8) bool {
    for (display_names) |d| {
        if (std.mem.eql(u8, d.key, key)) return true;
    }
    return false;
}

fn expectKey(expected: ?[]const u8, raw: []const u8) !void {
    const got = normalize(raw);
    if (expected) |e| {
        if (got == null) {
            std.debug.print("normalize(\"{s}\") = null, oczekiwano {s}\n", .{ raw, e });
            return error.TestExpectedEqual;
        }
        try testing.expectEqualStrings(e, got.?);
    } else {
        if (got != null) {
            std.debug.print("normalize(\"{s}\") = {s}, oczekiwano null\n", .{ raw, got.? });
            return error.TestExpectedEqual;
        }
    }
}

test "vendors: producenci płyt głównych (SMBIOS typ 2)" {
    try expectKey("asrock", "ASRock");
    try expectKey("asus", "ASUSTeK COMPUTER INC.");
    try expectKey("asus", "ASUS");
    try expectKey("msi", "Micro-Star International Co., Ltd.");
    try expectKey("msi", "MSI");
    try expectKey("gigabyte", "Gigabyte Technology Co., Ltd.");
    try expectKey("biostar", "BIOSTAR Group");
    try expectKey("evga", "EVGA");
    try expectKey("supermicro", "Supermicro");
    try expectKey("supermicro", "Super Micro Computer, Inc.");
}

test "vendors: producenci pamięci (nazwy)" {
    try expectKey("gskill", "G.Skill");
    try expectKey("gskill", "G Skill Intl");
    try expectKey("corsair", "Corsair");
    try expectKey("kingston", "Kingston");
    try expectKey("samsung", "Samsung");
    try expectKey("skhynix", "SK Hynix");
    try expectKey("skhynix", "Hynix Semiconductor");
    try expectKey("micron", "Micron Technology");
    try expectKey("crucial", "Crucial Technology");
    try expectKey("teamgroup", "Team Group Inc.");
    try expectKey("teamgroup", "TEAMGROUP");
    try expectKey("adata", "A-DATA Technology");
    try expectKey("patriot", "Patriot Memory");
}

test "vendors: kody JEDEC JEP106" {
    try expectKey("gskill", "04CD");
    try expectKey("corsair", "029E");
    try expectKey("kingston", "0198");
    try expectKey("samsung", "80CE");
    try expectKey("samsung", "00CE"); // bank 1 bez bitu nieparzystości
    try expectKey("samsung", "CE");
    try expectKey("samsung", "CE00000000000000");
    try expectKey("samsung", "80CE000080CE");
    try expectKey("skhynix", "80AD");
    try expectKey("skhynix", "AD");
    try expectKey("micron", "802C");
    try expectKey("micron", "2C");
    try expectKey("crucial", "859B");
    try expectKey("adata", "04CB");
    try expectKey("teamgroup", "04EF");
    try expectKey("patriot", "8502");
    // Niejednoznaczne bez banku — pominięte celowo.
    try expectKey(null, "98");
    try expectKey(null, "9E");
    try expectKey(null, "9B");
    // Nieznany kod.
    try expectKey(null, "8001");
}

test "vendors: modele dysków" {
    try expectKey("samsung", "Samsung SSD 860 EVO 250GB");
    try expectKey("western-digital", "WDC WD40EFRX-68N32N0");
    try expectKey("western-digital", "WD_BLACK SN850X");
    try expectKey("western-digital", "WD40EFRX-68N32N0");
    try expectKey("western-digital", "Western Digital");
    try expectKey("seagate", "ST12000NM0127");
    try expectKey("seagate", "ATA ST2000DM008-2FR102");
    try expectKey("kingston", "KINGSTON SKC3000D2048G");
    try expectKey("kingston", "SA400S37240G");
    try expectKey("crucial", "CT1000P3SSD8");
    try expectKey("kioxia", "KIOXIA-EXCERIA SATA SSD");
    try expectKey("toshiba", "TOSHIBA DT01ACA300");
    try expectKey("toshiba", "DT01ACA300");
    try expectKey("lexar", "Lexar SSD NM620 1TB");
    try expectKey("skhynix", "SKHynix_HFS512GDE9X081N");
    try expectKey("skhynix", "HFS512GDE9X081N");
    try expectKey("micron", "MTFDKBA512TFH");
    try expectKey("samsung", "MZVL2512HCJQ-00B00");
    try expectKey("samsung", "MZ-V8V1T0");
    try expectKey("sandisk", "SanDisk SDSSDH3 1T00");
    try expectKey("seagate", "Seagate BarraCuda");
}

test "vendors: wartości zastępcze i nieznane" {
    try expectKey(null, "Unknown");
    try expectKey(null, "To Be Filled By O.E.M.");
    try expectKey(null, "00000000");
    try expectKey(null, "0000");
    try expectKey(null, "FFFF");
    try expectKey(null, "Default string");
    try expectKey(null, "Manufacturer00");
    try expectKey(null, "");
    try expectKey(null, "   ");
    try expectKey(null, "Fujitsu");
    try expectKey(null, "Generic Flash Disk");
    // Krótkie nazwy nie trafiają w środek słów.
    try expectKey(null, "Transmissive");
}

test "vendors: chipsety i stare marki z nazw" {
    try expectKey("via", "VIA Technologies, Inc.");
    try expectKey("sis", "Silicon Integrated Systems [SiS]");
    try expectKey("ali", "Acer Laboratories Inc.");
    try expectKey("uli", "ULi Electronics Inc.");
    try expectKey("ati", "ATI Technologies Inc");
    try expectKey("amd", "Advanced Micro Devices, Inc.");
    try expectKey("nvidia", "NVIDIA Corporation");
    try expectKey("intel", "Intel Corporation");
    try expectKey("matrox", "Matrox Electronics Systems Ltd.");
    try expectKey("3dfx", "3Dfx Interactive, Inc.");
    try expectKey("s3", "S3 Graphics Ltd.");
    try expectKey("xgi", "XGI Technology Inc.");
}

test "vendors: identyfikatory PCI" {
    const cases = [_]struct { vid: u16, key: []const u8 }{
        .{ .vid = 0x1022, .key = "amd" },      .{ .vid = 0x1002, .key = "amd" },
        .{ .vid = 0x8086, .key = "intel" },    .{ .vid = 0x10DE, .key = "nvidia" },
        .{ .vid = 0x1106, .key = "via" },      .{ .vid = 0x1039, .key = "sis" },
        .{ .vid = 0x10B9, .key = "ali" },      .{ .vid = 0x1166, .key = "serverworks" },
        .{ .vid = 0x14E4, .key = "broadcom" }, .{ .vid = 0x1D17, .key = "zhaoxin" },
        .{ .vid = 0x1D94, .key = "hygon" },    .{ .vid = 0x121A, .key = "3dfx" },
        .{ .vid = 0x102B, .key = "matrox" },   .{ .vid = 0x5333, .key = "s3" },
        .{ .vid = 0x18CA, .key = "xgi" },      .{ .vid = 0x1010, .key = "powervr" },
        .{ .vid = 0x1078, .key = "cyrix" },    .{ .vid = 0x100B, .key = "nsc" },
    };
    for (cases) |c| try testing.expectEqualStrings(c.key, pciVendor(c.vid).?);
    try testing.expect(pciVendor(0x0000) == null);
    try testing.expect(pciVendor(0xFFFF) == null);
}

test "vendors: producenci kart graficznych (podsystem PCI)" {
    // Karta użytkownika: fixture asrock_b550_5800x3d_rx7900xtx.sysimg,
    // wiersz „gpu 1002 744c 53041849” — RX 7900 XTX od ASRock.
    const subsys: u32 = 0x53041849;
    const sv = subsystemVendor(subsys);
    try testing.expectEqual(@as(u16, 0x1849), sv);
    try testing.expect(!isReference(0x1002, sv));
    try testing.expectEqualStrings("asrock", gpuPartner(sv).?);
    try testing.expectEqualStrings("ASRock", displayName(gpuPartner(sv).?));

    const cases = [_]struct { sv: u16, key: []const u8 }{
        .{ .sv = 0x1043, .key = "asus" },     .{ .sv = 0x1462, .key = "msi" },
        .{ .sv = 0x1458, .key = "gigabyte" }, .{ .sv = 0x1DA2, .key = "sapphire" },
        .{ .sv = 0x174B, .key = "sapphire" }, .{ .sv = 0x148C, .key = "powercolor" },
        .{ .sv = 0x1682, .key = "xfx" },      .{ .sv = 0x19DA, .key = "zotac" },
        .{ .sv = 0x1569, .key = "palit" },    .{ .sv = 0x10B0, .key = "gainward" },
        .{ .sv = 0x196E, .key = "pny" },      .{ .sv = 0x3842, .key = "evga" },
        .{ .sv = 0x1771, .key = "inno3d" },   .{ .sv = 0x1B4C, .key = "galax" },
        .{ .sv = 0x7377, .key = "colorful" }, .{ .sv = 0x1ED3, .key = "yeston" },
        .{ .sv = 0x6688, .key = "maxsun" },   .{ .sv = 0x1565, .key = "biostar" },
        .{ .sv = 0x17AF, .key = "his" },      .{ .sv = 0x1028, .key = "dell" },
        .{ .sv = 0x103C, .key = "hp" },       .{ .sv = 0x17AA, .key = "lenovo" },
        .{ .sv = 0x1025, .key = "acer" },
    };
    for (cases) |c| try testing.expectEqualStrings(c.key, gpuPartner(c.sv).?);

    // Karta referencyjna: podsystem = producent chipu.
    try testing.expect(isReference(0x1002, 0x1002));
    try testing.expect(isReference(0x10DE, 0x10DE));
    try testing.expect(isReference(0x1002, 0x0000));
    try testing.expect(gpuPartner(0x1002) == null);
    try testing.expect(gpuPartner(0x10DE) == null);
    try testing.expect(gpuPartner(0x8086) == null);
    // Nieznany.
    try testing.expect(gpuPartner(0x0000) == null);
    try testing.expect(gpuPartner(0xABCD) == null);

    var v: u32 = 0;
    while (v <= 0xFFFF) : (v += 1) {
        if (gpuPartner(@intCast(v))) |k| try testing.expect(hasDisplayName(k));
    }
}

test "vendors: napisy producenta CPUID" {
    const cases = [_]struct { s: []const u8, key: []const u8 }{
        .{ .s = "AuthenticAMD", .key = "amd" },
        .{ .s = "GenuineIntel", .key = "intel" },
        .{ .s = "CyrixInstead", .key = "cyrix" },
        .{ .s = "CentaurHauls", .key = "centaur" },
        .{ .s = "GenuineTMx86", .key = "transmeta" },
        .{ .s = "TransmetaCPU", .key = "transmeta" },
        .{ .s = "NexGenDriven", .key = "nexgen" },
        .{ .s = "RiseRiseRise", .key = "rise" },
        .{ .s = "Geode by NSC", .key = "nsc" },
        .{ .s = "  Shanghai  ", .key = "zhaoxin" },
        .{ .s = "Shanghai", .key = "zhaoxin" },
        .{ .s = "HygonGenuine", .key = "hygon" },
        .{ .s = "UMC UMC UMC ", .key = "umc" },
        .{ .s = "SiS SiS SiS ", .key = "sis" },
        .{ .s = "Vortex86 SoC", .key = "vortex86" },
        .{ .s = "VIA VIA VIA ", .key = "via" },
    };
    for (cases) |c| try testing.expectEqualStrings(c.key, cpuVendor(c.s).?);
    try testing.expect(cpuVendor("KVMKVMKVM\x00\x00\x00") == null);
    try testing.expect(cpuVendor("") == null);
}

test "vendors: nazwy wyświetlane" {
    try testing.expectEqualStrings("SiS", displayName("sis"));
    try testing.expectEqualStrings("VIA", displayName("via"));
    try testing.expectEqualStrings("ALi", displayName("ali"));
    try testing.expectEqualStrings("3dfx", displayName("3dfx"));
    try testing.expectEqualStrings("SK hynix", displayName("skhynix"));
    try testing.expectEqualStrings("G.SKILL", displayName("gskill"));
    try testing.expectEqualStrings("WD", displayName("western-digital"));
    try testing.expectEqualStrings("cos-nowego", displayName("cos-nowego"));
    // Klucze logo dostarczonych przez użytkownika (assets/logos) też mają nazwy.
    for ([_][]const u8{ "biostar", "hygon", "yeston", "gskill", "colorful", "maxsun", "powervr" }) |k| try testing.expect(hasDisplayName(k));
    // Każdy klucz zwracany przez normalize/pciVendor/cpuVendor ma nazwę wyświetlaną.
    for (joined_rules) |r| try testing.expect(hasDisplayName(r.key));
    for (token_rules) |r| try testing.expect(hasDisplayName(r.key));
    for (model_prefixes) |r| try testing.expect(hasDisplayName(r.key));
    for (jedec_codes) |r| try testing.expect(hasDisplayName(r.key));
    for (cpu_vendor_strings) |r| try testing.expect(hasDisplayName(r.key));
    var vid: u32 = 0;
    while (vid <= 0xFFFF) : (vid += 1) {
        if (pciVendor(@intCast(vid))) |k| try testing.expect(hasDisplayName(k));
    }
}

test "vendors: łańcuch obrazów i logo" {
    var b: ChainBuf = .{};
    const c = logoChain(.board, "asrock", "X570 Taichi", &b);
    try testing.expectEqual(@as(usize, 2), c.images.len);
    try testing.expectEqualStrings("board\\asrock-x570-taichi.png", c.images[0]);
    try testing.expectEqualStrings("board\\asrock.png", c.images[1]);
    try testing.expectEqual(@as(usize, 1), c.logos.len);
    try testing.expectEqualStrings("asrock", c.logos[0]);

    var b2: ChainBuf = .{};
    const c2 = logoChain(.memory, normalize("04CD"), "", &b2);
    try testing.expectEqual(@as(usize, 1), c2.images.len);
    try testing.expectEqualStrings("memory\\gskill.png", c2.images[0]);
    try testing.expectEqualStrings("gskill", c2.logos[0]);

    var b3: ChainBuf = .{};
    const c3 = logoChain(.storage, normalize("WDC WD40EFRX-68N32N0"), "WDC WD40EFRX-68N32N0", &b3);
    try testing.expectEqualStrings("storage\\western-digital-wdc-wd40efrx-68n32n0.png", c3.images[0]);
    try testing.expectEqualStrings("storage\\western-digital.png", c3.images[1]);
    try testing.expectEqualStrings("western-digital", c3.logos[0]);

    // Chipset NVIDIA: najpierw nForce, potem NVIDIA.
    var b4: ChainBuf = .{};
    const c4 = logoChain(.chipset, pciVendor(0x10DE), "", &b4);
    try testing.expectEqualStrings("chipset\\nvidia.png", c4.images[0]);
    try testing.expectEqual(@as(usize, 2), c4.logos.len);
    try testing.expectEqualStrings("nvidia-nforce", c4.logos[0]);
    try testing.expectEqualStrings("nvidia", c4.logos[1]);

    // Nieznany producent: tylko obraz po modelu, bez logo → rysowana plakietka.
    var b5: ChainBuf = .{};
    const c5 = logoChain(.storage, normalize("Generic Flash Disk"), "Generic Flash Disk", &b5);
    try testing.expectEqual(@as(usize, 1), c5.images.len);
    try testing.expectEqualStrings("storage\\generic-flash-disk.png", c5.images[0]);
    try testing.expectEqual(@as(usize, 0), c5.logos.len);

    // Nic nie wiadomo: pusto.
    var b6: ChainBuf = .{};
    const c6 = logoChain(.board, normalize("To Be Filled By O.E.M."), "", &b6);
    try testing.expectEqual(@as(usize, 0), c6.images.len);
    try testing.expectEqual(@as(usize, 0), c6.logos.len);

    // CPU z CPUID.
    var b7: ChainBuf = .{};
    const c7 = logoChain(.cpu, cpuVendor("CyrixInstead"), "6x86MX", &b7);
    try testing.expectEqualStrings("cpu\\cyrix-6x86mx.png", c7.images[0]);
    try testing.expectEqualStrings("cyrix", c7.logos[0]);
}
