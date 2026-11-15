//! uia-select-tab — wybiera zakładkę w oknie przez natywne UI Automation.
//!
//! Narzędzie testowe do zrzutów ekranu GUI: zamiast klikać po współrzędnych
//! albo wysyłać klawisze, prosi UI Automation (UIAutomationCore, COM
//! IUIAutomation) o element `TabItem` o danej nazwie w oknie o danym
//! uchwycie i wywołuje `SelectionItemPattern.Select()`.
//!
//! Zarządzany klient UIA z .NET Framework (System.Windows.Automation) nie
//! rozpoznaje kontrolek Win32 bez działających proxy po stronie klienta —
//! natywny UIA ma je wbudowane.
//!
//! Użycie: uia-select-tab <hwnd dziesiętnie> <nazwa zakładki | #indeks>
//! `#3` wybiera czwartą zakładkę (indeks od 0) niezależnie od języka
//! interfejsu — do zrzutów ekranu w dowolnym języku.
//! Kod wyjścia: 0 = wybrano, 1 = błąd UIA, 2 = brak zakładki, 3 = złe argumenty.

const std = @import("std");

const HRESULT = i32;
const GUID = extern struct { d1: u32, d2: u16, d3: u16, d4: [8]u8 };
const ComObj = extern struct { vtbl: [*]const *const anyopaque };

const VARIANT = extern struct {
    vt: u16 = 0,
    r1: u16 = 0,
    r2: u16 = 0,
    r3: u16 = 0,
    val: i64 = 0,
    pad: i64 = 0,
};

extern "ole32" fn CoInitializeEx(?*anyopaque, u32) callconv(.winapi) HRESULT;
extern "ole32" fn CoCreateInstance(*const GUID, ?*anyopaque, u32, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT;
extern "oleaut32" fn SysStringLen(?[*]const u16) callconv(.winapi) u32;
extern "oleaut32" fn SysFreeString(?[*]const u16) callconv(.winapi) void;

const CLSID_CUIAutomation = GUID{ .d1 = 0xff48dba4, .d2 = 0x60ef, .d3 = 0x4201, .d4 = .{ 0xaa, 0x87, 0x54, 0x10, 0x3e, 0xef, 0x59, 0x4e } };
const IID_IUIAutomation = GUID{ .d1 = 0x30cbe57d, .d2 = 0xd9d0, .d3 = 0x452a, .d4 = .{ 0xab, 0x13, 0x7a, 0xc5, 0xac, 0x48, 0x25, 0xee } };
const IID_SelectionItem = GUID{ .d1 = 0xa8efa66a, .d2 = 0x0fda, .d3 = 0x421a, .d4 = .{ 0x91, 0x94, 0x38, 0x02, 0x1f, 0x35, 0x78, 0xea } };

const UIA_ControlTypePropertyId: i32 = 30003;
const UIA_TabItemControlTypeId: i32 = 50019;
const UIA_SelectionItemPatternId: i32 = 10010;
const TreeScope_Descendants: i32 = 4;
const VT_I4: u16 = 3;

fn method(o: *ComObj, comptime T: type, idx: usize) T {
    return @ptrCast(o.vtbl[idx]);
}

fn release(o: *ComObj) void {
    _ = method(o, *const fn (*ComObj) callconv(.winapi) u32, 2)(o);
}

pub fn main() !u8 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const args = try std.process.argsAlloc(arena.allocator());
    if (args.len < 3) return 3;
    const hwnd_val = std.fmt.parseInt(usize, args[1], 10) catch return 3;
    // `#n` = zakładka o indeksie n (kolejność UIA = kolejność zakładek).
    const want_index: ?i32 = if (args[2].len > 1 and args[2][0] == '#')
        (std.fmt.parseInt(i32, args[2][1..], 10) catch return 3)
    else
        null;
    const want = try std.unicode.utf8ToUtf16LeAlloc(arena.allocator(), args[2]);

    _ = CoInitializeEx(null, 2);
    var uia_ptr: ?*anyopaque = null;
    if (CoCreateInstance(&CLSID_CUIAutomation, null, 1, &IID_IUIAutomation, &uia_ptr) < 0) return 1;
    const uia: *ComObj = @ptrCast(@alignCast(uia_ptr.?));
    defer release(uia);

    var root_ptr: ?*anyopaque = null;
    const fromHandle = method(uia, *const fn (*ComObj, usize, *?*anyopaque) callconv(.winapi) HRESULT, 6);
    if (fromHandle(uia, hwnd_val, &root_ptr) < 0 or root_ptr == null) return 1;
    const root: *ComObj = @ptrCast(@alignCast(root_ptr.?));
    defer release(root);

    var cond_ptr: ?*anyopaque = null;
    const createCond = method(uia, *const fn (*ComObj, i32, VARIANT, *?*anyopaque) callconv(.winapi) HRESULT, 23);
    if (createCond(uia, UIA_ControlTypePropertyId, .{ .vt = VT_I4, .val = UIA_TabItemControlTypeId }, &cond_ptr) < 0) return 1;
    const cond: *ComObj = @ptrCast(@alignCast(cond_ptr.?));
    defer release(cond);

    var arr_ptr: ?*anyopaque = null;
    const findAll = method(root, *const fn (*ComObj, i32, *ComObj, *?*anyopaque) callconv(.winapi) HRESULT, 6);
    if (findAll(root, TreeScope_Descendants, cond, &arr_ptr) < 0 or arr_ptr == null) return 1;
    const arr: *ComObj = @ptrCast(@alignCast(arr_ptr.?));
    defer release(arr);

    var len: i32 = 0;
    _ = method(arr, *const fn (*ComObj, *i32) callconv(.winapi) HRESULT, 3)(arr, &len);
    var i: i32 = 0;
    while (i < len) : (i += 1) {
        var el_ptr: ?*anyopaque = null;
        if (method(arr, *const fn (*ComObj, i32, *?*anyopaque) callconv(.winapi) HRESULT, 4)(arr, i, &el_ptr) < 0) continue;
        const el: *ComObj = @ptrCast(@alignCast(el_ptr.?));
        defer release(el);
        if (want_index) |wi| {
            if (i != wi) continue;
        } else {
            var name: ?[*]const u16 = null;
            if (method(el, *const fn (*ComObj, *?[*]const u16) callconv(.winapi) HRESULT, 23)(el, &name) < 0) continue;
            defer SysFreeString(name);
            const n = SysStringLen(name);
            if (name == null or !std.mem.eql(u16, name.?[0..n], want)) continue;
        }

        var pat_unk: ?*anyopaque = null;
        if (method(el, *const fn (*ComObj, i32, *?*anyopaque) callconv(.winapi) HRESULT, 16)(el, UIA_SelectionItemPatternId, &pat_unk) < 0 or pat_unk == null) return 1;
        const unk: *ComObj = @ptrCast(@alignCast(pat_unk.?));
        defer release(unk);
        var pat_ptr: ?*anyopaque = null;
        if (method(unk, *const fn (*ComObj, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT, 0)(unk, &IID_SelectionItem, &pat_ptr) < 0) return 1;
        const pat: *ComObj = @ptrCast(@alignCast(pat_ptr.?));
        defer release(pat);
        return if (method(pat, *const fn (*ComObj) callconv(.winapi) HRESULT, 3)(pat) < 0) 1 else 0;
    }
    return 2;
}
