//! Wczytywanie PNG przez Windows Imaging Component (WIC) do bitmapy DIB
//! 32 bpp z kanałem alfa (premultiplied BGRA) — do rysowania przez AlphaBlend.
//!
//! Źródła: plik (obraz użytkownika z `data\images\`) albo pamięć (logo
//! osadzone w programie). Każdy błąd = `null`; GUI rysuje wtedy plakietkę.

const std = @import("std");

const HRESULT = i32;
const GUID = extern struct { d1: u32, d2: u16, d3: u16, d4: [8]u8 };
const ComObj = extern struct { vtbl: [*]const *const anyopaque };
pub const HBITMAP = *opaque {};

const BITMAPINFOHEADER = extern struct {
    biSize: u32 = @sizeOf(BITMAPINFOHEADER),
    biWidth: i32,
    biHeight: i32,
    biPlanes: u16 = 1,
    biBitCount: u16 = 32,
    biCompression: u32 = 0,
    biSizeImage: u32 = 0,
    biXPelsPerMeter: i32 = 0,
    biYPelsPerMeter: i32 = 0,
    biClrUsed: u32 = 0,
    biClrImportant: u32 = 0,
};

extern "ole32" fn CoInitializeEx(?*anyopaque, u32) callconv(.winapi) HRESULT;
extern "ole32" fn CoCreateInstance(*const GUID, ?*anyopaque, u32, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT;
extern "gdi32" fn CreateDIBSection(?*anyopaque, *const BITMAPINFOHEADER, u32, *?*anyopaque, ?*anyopaque, u32) callconv(.winapi) ?HBITMAP;
pub extern "gdi32" fn DeleteObject(?*anyopaque) callconv(.winapi) i32;

const CLSID_WICImagingFactory = GUID{ .d1 = 0xcacaf262, .d2 = 0x9370, .d3 = 0x4615, .d4 = .{ 0xa1, 0x3b, 0x9f, 0x55, 0x39, 0xda, 0x4c, 0x0a } };
const IID_IWICImagingFactory = GUID{ .d1 = 0xec5ec8a9, .d2 = 0xc395, .d3 = 0x4314, .d4 = .{ 0x9c, 0x77, 0x54, 0xd7, 0xa9, 0x35, 0xff, 0x70 } };
const GUID_WICPixelFormat32bppPBGRA = GUID{ .d1 = 0x6fddc324, .d2 = 0x4e03, .d3 = 0x4bfe, .d4 = .{ 0xb1, 0x85, 0x3d, 0x77, 0x76, 0x8d, 0xc9, 0x10 } };

pub const Image = struct {
    bmp: HBITMAP,
    w: u32,
    h: u32,

    pub fn deinit(self: *Image) void {
        _ = DeleteObject(self.bmp);
    }
};

fn m(o: *ComObj, comptime T: type, idx: usize) T {
    return @ptrCast(o.vtbl[idx]);
}

fn release(o: *ComObj) void {
    _ = m(o, *const fn (*ComObj) callconv(.winapi) u32, 2)(o);
}

var factory: ?*ComObj = null;

fn getFactory() ?*ComObj {
    if (factory) |f| return f;
    _ = CoInitializeEx(null, 2); // apartament STA wątku GUI; S_FALSE gdy już był
    var p: ?*anyopaque = null;
    if (CoCreateInstance(&CLSID_WICImagingFactory, null, 1, &IID_IWICImagingFactory, &p) < 0 or p == null) return null;
    factory = @ptrCast(@alignCast(p.?));
    return factory;
}

/// Maksymalny akceptowany rozmiar obrazu (bezpiecznik dla plików użytkownika).
const max_dim: u32 = 4096;

/// Wymiary po dopasowaniu `w`×`h` do pudełka `bw`×`bh` z zachowaniem proporcji.
pub fn fit(w: u32, h: u32, bw: u32, bh: u32) struct { w: u32, h: u32 } {
    if (w == 0 or h == 0 or bw == 0 or bh == 0) return .{ .w = 0, .h = 0 };
    const sx = @as(f64, @floatFromInt(bw)) / @as(f64, @floatFromInt(w));
    const sy = @as(f64, @floatFromInt(bh)) / @as(f64, @floatFromInt(h));
    const sc = @min(sx, sy);
    return .{ .w = @max(1, @as(u32, @intFromFloat(@as(f64, @floatFromInt(w)) * sc))), .h = @max(1, @as(u32, @intFromFloat(@as(f64, @floatFromInt(h)) * sc))) };
}

test "image: dopasowanie zachowuje proporcje" {
    const r = fit(960, 240, 120, 60);
    try std.testing.expectEqual(@as(u32, 120), r.w);
    try std.testing.expectEqual(@as(u32, 30), r.h);
    const q = fit(960, 960, 120, 60);
    try std.testing.expectEqual(@as(u32, 60), q.w);
}

fn fromDecoder(dec: *ComObj, bw: u32, bh: u32) ?Image {
    const f = factory.?;
    var frame_p: ?*anyopaque = null;
    // IWICBitmapDecoder::GetFrame = 13
    if (m(dec, *const fn (*ComObj, u32, *?*anyopaque) callconv(.winapi) HRESULT, 13)(dec, 0, &frame_p) < 0 or frame_p == null) return null;
    const frame: *ComObj = @ptrCast(@alignCast(frame_p.?));
    defer release(frame);
    var fw: u32 = 0;
    var fh: u32 = 0;
    if (m(frame, *const fn (*ComObj, *u32, *u32) callconv(.winapi) HRESULT, 3)(frame, &fw, &fh) < 0) return null;
    if (fw == 0 or fh == 0 or fw > max_dim or fh > max_dim) return null;
    // Skalowanie WIC (interpolacja Fant) do docelowego pudełka — lepsze niż
    // rozciąganie przez AlphaBlend przy rysowaniu.
    const t = fit(fw, fh, bw, bh);
    var sc_p: ?*anyopaque = null;
    // IWICImagingFactory::CreateBitmapScaler = 11
    if (m(f, *const fn (*ComObj, *?*anyopaque) callconv(.winapi) HRESULT, 11)(f, &sc_p) < 0 or sc_p == null) return null;
    const scaler: *ComObj = @ptrCast(@alignCast(sc_p.?));
    defer release(scaler);
    // IWICBitmapScaler::Initialize = 8 (źródło, w, h, WICBitmapInterpolationModeFant = 3)
    if (m(scaler, *const fn (*ComObj, *ComObj, u32, u32, u32) callconv(.winapi) HRESULT, 8)(scaler, frame, t.w, t.h, 3) < 0) return null;
    var conv_p: ?*anyopaque = null;
    // IWICImagingFactory::CreateFormatConverter = 10
    if (m(f, *const fn (*ComObj, *?*anyopaque) callconv(.winapi) HRESULT, 10)(f, &conv_p) < 0 or conv_p == null) return null;
    const conv: *ComObj = @ptrCast(@alignCast(conv_p.?));
    defer release(conv);
    // IWICFormatConverter::Initialize = 8 (źródło, format, dither none, paleta null, alfa 0, paleta custom)
    if (m(conv, *const fn (*ComObj, *ComObj, *const GUID, u32, ?*anyopaque, f64, u32) callconv(.winapi) HRESULT, 8)(conv, scaler, &GUID_WICPixelFormat32bppPBGRA, 0, null, 0.0, 0) < 0) return null;
    var w: u32 = 0;
    var h: u32 = 0;
    // IWICBitmapSource::GetSize = 3
    if (m(conv, *const fn (*ComObj, *u32, *u32) callconv(.winapi) HRESULT, 3)(conv, &w, &h) < 0) return null;
    if (w == 0 or h == 0 or w > max_dim or h > max_dim) return null;
    const bih: BITMAPINFOHEADER = .{ .biWidth = @intCast(w), .biHeight = -@as(i32, @intCast(h)) };
    var bits: ?*anyopaque = null;
    const bmp = CreateDIBSection(null, &bih, 0, &bits, null, 0) orelse return null;
    // IWICBitmapSource::CopyPixels = 7
    const stride = w * 4;
    if (m(conv, *const fn (*ComObj, ?*const anyopaque, u32, u32, [*]u8) callconv(.winapi) HRESULT, 7)(conv, null, stride, stride * h, @ptrCast(bits.?)) < 0) {
        _ = DeleteObject(bmp);
        return null;
    }
    return .{ .bmp = bmp, .w = w, .h = h };
}

/// PNG z pliku (UTF-16, zakończony zerem).
pub fn loadFile(path: [*:0]const u16, bw: u32, bh: u32) ?Image {
    const f = getFactory() orelse return null;
    var dec_p: ?*anyopaque = null;
    // IWICImagingFactory::CreateDecoderFromFilename = 3 (GENERIC_READ, cache on demand)
    if (m(f, *const fn (*ComObj, [*:0]const u16, ?*const GUID, u32, u32, *?*anyopaque) callconv(.winapi) HRESULT, 3)(f, path, null, 0x8000_0000, 0, &dec_p) < 0 or dec_p == null) return null;
    const dec: *ComObj = @ptrCast(@alignCast(dec_p.?));
    defer release(dec);
    return fromDecoder(dec, bw, bh);
}

/// PNG z pamięci (logo osadzone w programie).
pub fn loadMemory(bytes: []const u8, bw: u32, bh: u32) ?Image {
    const f = getFactory() orelse return null;
    var st_p: ?*anyopaque = null;
    // IWICImagingFactory::CreateStream = 14
    if (m(f, *const fn (*ComObj, *?*anyopaque) callconv(.winapi) HRESULT, 14)(f, &st_p) < 0 or st_p == null) return null;
    const st: *ComObj = @ptrCast(@alignCast(st_p.?));
    defer release(st);
    // IWICStream::InitializeFromMemory = 16
    if (m(st, *const fn (*ComObj, [*]const u8, u32) callconv(.winapi) HRESULT, 16)(st, bytes.ptr, @intCast(bytes.len)) < 0) return null;
    var dec_p: ?*anyopaque = null;
    // IWICImagingFactory::CreateDecoderFromStream = 4
    if (m(f, *const fn (*ComObj, *ComObj, ?*const GUID, u32, *?*anyopaque) callconv(.winapi) HRESULT, 4)(f, st, null, 0, &dec_p) < 0 or dec_p == null) return null;
    const dec: *ComObj = @ptrCast(@alignCast(dec_p.?));
    defer release(dec);
    return fromDecoder(dec, bw, bh);
}
