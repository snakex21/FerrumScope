//! Wbudowana baza PCI ID (kompilowana z `db/source/pci/pci.ids` w trakcie
//! builda przez `tools/pciids_compile.zig`, moduł `pciids_embedded`).
//!
//! Licencja danych: PCI ID Repository, GPL-2.0-or-later LUB BSD-3-Clause
//! (nagłówek pliku źródłowego jest osadzony w `attribution`).

const pciids = @import("../sys/pciids.zig");
const embedded = @import("pciids_embedded");

pub const attribution: []const u8 = embedded.attribution;

var cached: ?pciids.Db = null;
var failed = false;

/// Otwiera bazę raz i zapamiętuje wynik. `null`, gdy obraz jest uszkodzony
/// (wtedy nazwy urządzeń pokazujemy z opisów sterowników Windows).
pub fn get() ?*const pciids.Db {
    if (cached == null and !failed) {
        cached = pciids.Db.load(embedded.bytes) catch blk: {
            failed = true;
            break :blk null;
        };
    }
    if (cached) |*db| return db;
    return null;
}
