//! Ręczne deklaracje Win32 dla GUI FerrumScope.
//!
//! Tylko to, czego GUI faktycznie używa. Świadomie bez `std.os.windows`: tam
//! nie ma user32/comctl32, a mieszanie dwóch zestawów typów `HWND` kończy się
//! rzutowaniami w każdej linii. Wszystkie funkcje to warianty `W` (UTF-16) —
//! inaczej polskie znaki przechodziłyby przez stronę kodową ANSI i ginęły.
//!
//! Układ struktur odpowiada nagłówkom Windows SDK (Vista+, bo comctl32 v6).
//! Rozmiary krytycznych struktur są sprawdzane w `comptime` na dole pliku —
//! zły rozmiar `NONCLIENTMETRICSW` to cichy błąd: funkcja po prostu zwraca 0.

pub const BOOL = i32;
pub const WPARAM = usize;
pub const LPARAM = isize;
pub const LRESULT = isize;

pub const HWND = *opaque {};
pub const HINSTANCE = *opaque {};
pub const HMENU = *opaque {};
pub const HICON = *opaque {};
pub const HCURSOR = *opaque {};
pub const HBRUSH = *opaque {};
pub const HFONT = *opaque {};
pub const HIMAGELIST = *opaque {};

pub const WNDPROC = *const fn (HWND, u32, WPARAM, LPARAM) callconv(.winapi) LRESULT;

pub const POINT = extern struct { x: i32, y: i32 };
pub const RECT = extern struct { left: i32, top: i32, right: i32, bottom: i32 };

pub const MSG = extern struct {
    hwnd: ?HWND,
    message: u32,
    wParam: WPARAM,
    lParam: LPARAM,
    time: u32,
    pt: POINT,
    lPrivate: u32,
};

pub const WNDCLASSEXW = extern struct {
    cbSize: u32 = @sizeOf(WNDCLASSEXW),
    style: u32 = 0,
    lpfnWndProc: WNDPROC,
    cbClsExtra: i32 = 0,
    cbWndExtra: i32 = 0,
    hInstance: ?HINSTANCE = null,
    hIcon: ?HICON = null,
    hCursor: ?HCURSOR = null,
    hbrBackground: ?HBRUSH = null,
    lpszMenuName: ?[*:0]const u16 = null,
    lpszClassName: [*:0]const u16,
    hIconSm: ?HICON = null,
};

pub const MINMAXINFO = extern struct {
    ptReserved: POINT,
    ptMaxSize: POINT,
    ptMaxPosition: POINT,
    ptMinTrackSize: POINT,
    ptMaxTrackSize: POINT,
};

pub const NMHDR = extern struct {
    hwndFrom: ?HWND,
    idFrom: usize,
    code: u32,
};

pub const INITCOMMONCONTROLSEX = extern struct {
    dwSize: u32 = @sizeOf(INITCOMMONCONTROLSEX),
    dwICC: u32,
};

pub const LOGFONTW = extern struct {
    lfHeight: i32 = 0,
    lfWidth: i32 = 0,
    lfEscapement: i32 = 0,
    lfOrientation: i32 = 0,
    lfWeight: i32 = 0,
    lfItalic: u8 = 0,
    lfUnderline: u8 = 0,
    lfStrikeOut: u8 = 0,
    lfCharSet: u8 = 0,
    lfOutPrecision: u8 = 0,
    lfClipPrecision: u8 = 0,
    lfQuality: u8 = 0,
    lfPitchAndFamily: u8 = 0,
    lfFaceName: [32]u16 = @splat(0),
};

pub const NONCLIENTMETRICSW = extern struct {
    cbSize: u32 = @sizeOf(NONCLIENTMETRICSW),
    iBorderWidth: i32 = 0,
    iScrollWidth: i32 = 0,
    iScrollHeight: i32 = 0,
    iCaptionWidth: i32 = 0,
    iCaptionHeight: i32 = 0,
    lfCaptionFont: LOGFONTW = .{},
    iSmCaptionWidth: i32 = 0,
    iSmCaptionHeight: i32 = 0,
    lfSmCaptionFont: LOGFONTW = .{},
    iMenuWidth: i32 = 0,
    iMenuHeight: i32 = 0,
    lfMenuFont: LOGFONTW = .{},
    lfStatusFont: LOGFONTW = .{},
    lfMessageFont: LOGFONTW = .{},
    iPaddedBorderWidth: i32 = 0,
};

pub const LVCOLUMNW = extern struct {
    mask: u32 = 0,
    fmt: i32 = 0,
    cx: i32 = 0,
    pszText: ?[*:0]u16 = null,
    cchTextMax: i32 = 0,
    iSubItem: i32 = 0,
    iImage: i32 = 0,
    iOrder: i32 = 0,
    cxMin: i32 = 0,
    cxDefault: i32 = 0,
    cxIdeal: i32 = 0,
};

pub const LVITEMW = extern struct {
    mask: u32 = 0,
    iItem: i32 = 0,
    iSubItem: i32 = 0,
    state: u32 = 0,
    stateMask: u32 = 0,
    pszText: ?[*:0]u16 = null,
    cchTextMax: i32 = 0,
    iImage: i32 = 0,
    lParam: LPARAM = 0,
    iIndent: i32 = 0,
    iGroupId: i32 = 0,
    cColumns: u32 = 0,
    puColumns: ?*u32 = null,
    piColFmt: ?*i32 = null,
    iGroup: i32 = 0,
};

pub const NMCUSTOMDRAW = extern struct {
    hdr: NMHDR,
    dwDrawStage: u32,
    hdc: ?*anyopaque,
    rc: RECT,
    dwItemSpec: usize,
    uItemState: u32,
    lItemlParam: LPARAM,
};

pub const NMLVCUSTOMDRAW = extern struct {
    nmcd: NMCUSTOMDRAW,
    clrText: u32,
    clrTextBk: u32,
    iSubItem: i32,
    dwItemType: u32,
    clrFace: u32,
    iIconEffect: i32,
    iIconPhase: i32,
    iPartId: i32,
    iStateId: i32,
    rcText: RECT,
    uAlign: u32,
};

pub const LVGROUP = extern struct {
    cbSize: u32 = @sizeOf(LVGROUP),
    mask: u32 = 0,
    pszHeader: ?[*:0]u16 = null,
    cchHeader: i32 = 0,
    pszFooter: ?[*:0]u16 = null,
    cchFooter: i32 = 0,
    iGroupId: i32 = 0,
    stateMask: u32 = 0,
    state: u32 = 0,
    uAlign: u32 = 0,
    pszSubtitle: ?[*:0]u16 = null,
    cchSubtitle: u32 = 0,
    pszTask: ?[*:0]u16 = null,
    cchTask: u32 = 0,
    pszDescriptionTop: ?[*:0]u16 = null,
    cchDescriptionTop: u32 = 0,
    pszDescriptionBottom: ?[*:0]u16 = null,
    cchDescriptionBottom: u32 = 0,
    iTitleImage: i32 = 0,
    iExtendedImage: i32 = 0,
    iFirstItem: i32 = 0,
    cItems: u32 = 0,
    pszSubsetTitle: ?[*:0]u16 = null,
    cchSubsetTitle: u32 = 0,
};

pub const TCITEMW = extern struct {
    mask: u32 = 0,
    dwState: u32 = 0,
    dwStateMask: u32 = 0,
    pszText: ?[*:0]u16 = null,
    cchTextMax: i32 = 0,
    iImage: i32 = -1,
    lParam: LPARAM = 0,
};

// --- style okien ------------------------------------------------------------
pub const WS_OVERLAPPEDWINDOW: u32 = 0x00CF_0000;
pub const WS_CHILD: u32 = 0x4000_0000;
pub const WS_VISIBLE: u32 = 0x1000_0000;
pub const WS_CLIPSIBLINGS: u32 = 0x0400_0000;
pub const WS_CLIPCHILDREN: u32 = 0x0200_0000;
pub const WS_TABSTOP: u32 = 0x0001_0000;
pub const WS_EX_CLIENTEDGE: u32 = 0x0000_0200;
pub const CW_USEDEFAULT: i32 = @bitCast(@as(u32, 0x8000_0000));

pub const SS_LEFT: u32 = 0x0000;
pub const SS_RIGHT: u32 = 0x0002;
pub const SS_NOPREFIX: u32 = 0x0080;
pub const SS_ENDELLIPSIS: u32 = 0x4000;

pub const SW_HIDE: i32 = 0;
pub const SW_SHOW: i32 = 5;

pub const SWP_NOSIZE: u32 = 0x0001;
pub const SWP_NOMOVE: u32 = 0x0002;
pub const SWP_NOZORDER: u32 = 0x0004;
pub const SWP_NOACTIVATE: u32 = 0x0010;

pub const COLOR_WINDOW: i32 = 5;
pub const COLOR_WINDOWTEXT: i32 = 8;
pub const COLOR_BTNFACE: i32 = 15;
pub const IDC_ARROW: usize = 32512;
pub const SPI_GETNONCLIENTMETRICS: u32 = 0x0029;
pub const CLEARTYPE_QUALITY: u8 = 5;
pub const FW_NORMAL: i32 = 400;
pub const FW_SEMIBOLD: i32 = 600;

// --- komunikaty -------------------------------------------------------------
pub const WM_CREATE: u32 = 0x0001;
pub const WM_DESTROY: u32 = 0x0002;
pub const WM_SIZE: u32 = 0x0005;
pub const WM_GETMINMAXINFO: u32 = 0x0024;
pub const WM_SETFONT: u32 = 0x0030;
pub const WM_NOTIFY: u32 = 0x004E;
pub const WM_TIMER: u32 = 0x0113;
pub const WM_CTLCOLORSTATIC: u32 = 0x0138;
pub const WM_DPICHANGED: u32 = 0x02E0;

// --- common controls --------------------------------------------------------
pub const ICC_LISTVIEW_CLASSES: u32 = 0x0001;
pub const ICC_TAB_CLASSES: u32 = 0x0008;

pub const LVS_REPORT: u32 = 0x0001;
pub const LVS_SINGLESEL: u32 = 0x0004;
pub const LVS_SHOWSELALWAYS: u32 = 0x0008;
/// Lista nie niszczy image listy przy zamknięciu — jedna lista dla dwóch kontrolek.
pub const LVS_SHAREIMAGELISTS: u32 = 0x0040;
pub const LVS_NOSORTHEADER: u32 = 0x8000;
pub const LVS_EX_GRIDLINES: u32 = 0x0000_0001;
pub const LVS_EX_FULLROWSELECT: u32 = 0x0000_0020;
pub const LVS_EX_LABELTIP: u32 = 0x0000_4000;
pub const LVS_EX_DOUBLEBUFFER: u32 = 0x0001_0000;

pub const LVCF_WIDTH: u32 = 0x0002;
pub const LVCF_TEXT: u32 = 0x0004;
pub const LVCF_SUBITEM: u32 = 0x0008;
pub const LVIF_TEXT: u32 = 0x0001;
pub const LVIF_GROUPID: u32 = 0x0100;
pub const LVGF_HEADER: u32 = 0x0001;
pub const LVGF_STATE: u32 = 0x0004;
pub const LVGF_GROUPID: u32 = 0x0010;
pub const LVGS_COLLAPSIBLE: u32 = 0x0008;
pub const LVSIL_SMALL: usize = 1;
pub const ILC_COLOR32: u32 = 0x0020;

/// `NM_FIRST - 12`, gdzie `NM_FIRST = 0U`.
pub const NM_CUSTOMDRAW: u32 = @bitCast(@as(i32, -12));
pub const CDDS_PREPAINT: u32 = 0x0000_0001;
pub const CDDS_ITEMPREPAINT: u32 = 0x0001_0001;
pub const CDDS_SUBITEM: u32 = 0x0002_0000;
pub const CDRF_DODEFAULT: LRESULT = 0x00;
pub const CDRF_NEWFONT: LRESULT = 0x02;
pub const CDRF_NOTIFYITEMDRAW: LRESULT = 0x20;
pub const CDRF_NOTIFYSUBITEMDRAW: LRESULT = 0x20;
pub const LVCDI_ITEM: u32 = 0;
pub const LVSCW_AUTOSIZE_USEHEADER: isize = -2;

const LVM_FIRST: u32 = 0x1000;
pub const LVM_SETIMAGELIST: u32 = LVM_FIRST + 3;
pub const LVM_SETCOLUMNWIDTH: u32 = LVM_FIRST + 30;
pub const LVM_SETEXTENDEDLISTVIEWSTYLE: u32 = LVM_FIRST + 54;
pub const LVM_INSERTITEMW: u32 = LVM_FIRST + 77;
pub const LVM_INSERTCOLUMNW: u32 = LVM_FIRST + 97;
pub const LVM_SETITEMTEXTW: u32 = LVM_FIRST + 116;
pub const LVM_INSERTGROUP: u32 = LVM_FIRST + 145;
pub const LVM_ENABLEGROUPVIEW: u32 = LVM_FIRST + 157;

pub const TCIF_TEXT: u32 = 0x0001;
const TCM_FIRST: u32 = 0x1300;
pub const TCM_GETCURSEL: u32 = TCM_FIRST + 11;
pub const TCM_SETCURSEL: u32 = TCM_FIRST + 12;
pub const TCM_ADJUSTRECT: u32 = TCM_FIRST + 40;
pub const TCM_INSERTITEMW: u32 = TCM_FIRST + 62;
/// `TCN_FIRST - 1`, gdzie `TCN_FIRST = 0U - 550U`.
pub const TCN_SELCHANGE: u32 = @bitCast(@as(i32, -551));

// --- user32 -----------------------------------------------------------------
pub extern "user32" fn RegisterClassExW(*const WNDCLASSEXW) callconv(.winapi) u16;
pub extern "user32" fn CreateWindowExW(
    ex_style: u32,
    class_name: [*:0]const u16,
    window_name: ?[*:0]const u16,
    style: u32,
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    parent: ?HWND,
    menu: ?HMENU,
    instance: ?HINSTANCE,
    param: ?*anyopaque,
) callconv(.winapi) ?HWND;
pub extern "user32" fn DefWindowProcW(HWND, u32, WPARAM, LPARAM) callconv(.winapi) LRESULT;
pub extern "user32" fn GetMessageW(*MSG, ?HWND, u32, u32) callconv(.winapi) BOOL;
pub extern "user32" fn TranslateMessage(*const MSG) callconv(.winapi) BOOL;
pub extern "user32" fn DispatchMessageW(*const MSG) callconv(.winapi) LRESULT;
pub extern "user32" fn PostQuitMessage(exit_code: i32) callconv(.winapi) void;
pub extern "user32" fn ShowWindow(HWND, cmd_show: i32) callconv(.winapi) BOOL;
pub extern "user32" fn UpdateWindow(HWND) callconv(.winapi) BOOL;
pub extern "user32" fn SendMessageW(HWND, u32, WPARAM, LPARAM) callconv(.winapi) LRESULT;
pub extern "user32" fn SetTimer(?HWND, id: usize, elapse_ms: u32, func: ?*const anyopaque) callconv(.winapi) usize;
pub extern "user32" fn KillTimer(?HWND, id: usize) callconv(.winapi) BOOL;
pub extern "user32" fn GetClientRect(HWND, *RECT) callconv(.winapi) BOOL;
pub extern "user32" fn MoveWindow(HWND, x: i32, y: i32, w: i32, h: i32, repaint: BOOL) callconv(.winapi) BOOL;
pub extern "user32" fn SetWindowPos(HWND, after: ?HWND, x: i32, y: i32, cx: i32, cy: i32, flags: u32) callconv(.winapi) BOOL;
pub extern "user32" fn SetWindowTextW(HWND, [*:0]const u16) callconv(.winapi) BOOL;
pub extern "user32" fn LoadCursorW(?HINSTANCE, name: ?*const anyopaque) callconv(.winapi) ?HCURSOR;
pub extern "user32" fn GetSysColorBrush(index: i32) callconv(.winapi) ?HBRUSH;
pub extern "user32" fn GetSysColor(index: i32) callconv(.winapi) u32;
/// Windows 10 1607+. Starsze systemy nie są celem GUI.
pub extern "user32" fn GetDpiForWindow(HWND) callconv(.winapi) u32;
/// Windows 10 1607+. Metryki czcionki dla konkretnego DPI monitora.
pub extern "user32" fn SystemParametersInfoForDpi(action: u32, param: u32, pv: ?*anyopaque, win_ini: u32, dpi: u32) callconv(.winapi) BOOL;

// --- gdi32 ------------------------------------------------------------------
pub extern "gdi32" fn CreateFontIndirectW(*const LOGFONTW) callconv(.winapi) ?HFONT;
pub extern "gdi32" fn DeleteObject(?*anyopaque) callconv(.winapi) BOOL;
pub extern "gdi32" fn SetBkColor(hdc: ?*anyopaque, color: u32) callconv(.winapi) u32;
pub extern "gdi32" fn SetTextColor(hdc: ?*anyopaque, color: u32) callconv(.winapi) u32;

// --- uxtheme ----------------------------------------------------------------
/// Motyw „Explorer" dla list: nowoczesne zaznaczenie i nagłówki grup.
pub extern "uxtheme" fn SetWindowTheme(HWND, app_name: ?[*:0]const u16, id_list: ?[*:0]const u16) callconv(.winapi) i32;

// --- comctl32 ---------------------------------------------------------------
pub extern "comctl32" fn InitCommonControlsEx(*const INITCOMMONCONTROLSEX) callconv(.winapi) BOOL;
pub extern "comctl32" fn ImageList_Create(cx: i32, cy: i32, flags: u32, initial: i32, grow: i32) callconv(.winapi) ?HIMAGELIST;
pub extern "comctl32" fn ImageList_Destroy(?HIMAGELIST) callconv(.winapi) BOOL;

comptime {
    // Rozmiary z SDK. Niezgodność = funkcja odrzuca strukturę bez komunikatu.
    if (@sizeOf(LOGFONTW) != 92) @compileError("LOGFONTW: zły rozmiar");
    if (@sizeOf(NONCLIENTMETRICSW) != 504) @compileError("NONCLIENTMETRICSW: zły rozmiar");
    if (@sizeOf(usize) == 8 and @sizeOf(LVITEMW) != 88) @compileError("LVITEMW: zły rozmiar");
    if (@sizeOf(usize) == 8 and @sizeOf(MSG) != 48) @compileError("MSG: zły rozmiar");
    if (@sizeOf(usize) == 8 and @sizeOf(NMCUSTOMDRAW) != 80) @compileError("NMCUSTOMDRAW: zły rozmiar");
    if (@sizeOf(usize) == 8 and @sizeOf(NMLVCUSTOMDRAW) != 136) @compileError("NMLVCUSTOMDRAW: zły rozmiar");
    if (@sizeOf(usize) == 8 and @sizeOf(LVGROUP) != 152) @compileError("LVGROUP: zły rozmiar");
}

// --- dodatki dla zakładek systemowych, przycisków i eksportu ----------------
pub const WM_COMMAND: u32 = 0x0111;
pub const BN_CLICKED: u32 = 0;
pub const BS_PUSHBUTTON: u32 = 0x0000;
pub const BS_AUTOCHECKBOX: u32 = 0x0003;
pub const BM_GETCHECK: u32 = 0x00F0;
pub const BST_CHECKED: LRESULT = 1;
pub const LVM_DELETEALLITEMS: u32 = LVM_FIRST + 9;
pub const LVM_GETITEMCOUNT: u32 = LVM_FIRST + 4;
pub const LVM_REMOVEALLGROUPS: u32 = LVM_FIRST + 160;
pub const LVM_GETTOPINDEX: u32 = LVM_FIRST + 39;
pub const LVM_ENSUREVISIBLE: u32 = LVM_FIRST + 19;
pub const WM_SETREDRAW: u32 = 0x000B;
pub const SW_SHOWNORMAL: i32 = 1;
pub const MB_OK: u32 = 0x0000;
pub const MB_ICONINFORMATION: u32 = 0x0040;
pub const MB_ICONWARNING: u32 = 0x0030;
pub const OFN_OVERWRITEPROMPT: u32 = 0x0000_0002;
pub const OFN_PATHMUSTEXIST: u32 = 0x0000_0800;
pub const OFN_NOCHANGEDIR: u32 = 0x0000_0008;

pub const OPENFILENAMEW = extern struct {
    lStructSize: u32 = @sizeOf(OPENFILENAMEW),
    hwndOwner: ?HWND = null,
    hInstance: ?HINSTANCE = null,
    lpstrFilter: ?[*]const u16 = null,
    lpstrCustomFilter: ?[*]u16 = null,
    nMaxCustFilter: u32 = 0,
    nFilterIndex: u32 = 0,
    lpstrFile: [*]u16,
    nMaxFile: u32,
    lpstrFileTitle: ?[*]u16 = null,
    nMaxFileTitle: u32 = 0,
    lpstrInitialDir: ?[*:0]const u16 = null,
    lpstrTitle: ?[*:0]const u16 = null,
    Flags: u32 = 0,
    nFileOffset: u16 = 0,
    nFileExtension: u16 = 0,
    lpstrDefExt: ?[*:0]const u16 = null,
    lCustData: LPARAM = 0,
    lpfnHook: ?*anyopaque = null,
    lpTemplateName: ?[*:0]const u16 = null,
    pvReserved: ?*anyopaque = null,
    dwReserved: u32 = 0,
    FlagsEx: u32 = 0,
};

pub extern "comdlg32" fn GetSaveFileNameW(*OPENFILENAMEW) callconv(.winapi) BOOL;
pub extern "shell32" fn ShellExecuteW(?HWND, ?[*:0]const u16, [*:0]const u16, ?[*:0]const u16, ?[*:0]const u16, i32) callconv(.winapi) ?*anyopaque;
pub extern "user32" fn MessageBoxW(?HWND, [*:0]const u16, [*:0]const u16, u32) callconv(.winapi) i32;
pub extern "user32" fn EnableWindow(HWND, BOOL) callconv(.winapi) BOOL;
pub extern "user32" fn InvalidateRect(?HWND, ?*const RECT, BOOL) callconv(.winapi) BOOL;

comptime {
    if (@sizeOf(usize) == 8 and @sizeOf(OPENFILENAMEW) != 152) @compileError("OPENFILENAMEW: zły rozmiar");
}

// --- widok uporządkowany: ramki, pola tylko-do-odczytu, listy, podpowiedzi ---
pub const BS_GROUPBOX: u32 = 0x0007;
pub const ES_MULTILINE: u32 = 0x0004;
pub const ES_AUTOHSCROLL: u32 = 0x0080;
pub const ES_READONLY: u32 = 0x0800;
pub const WS_BORDER: u32 = 0x0080_0000;
pub const WS_VSCROLL: u32 = 0x0020_0000;
pub const CBS_DROPDOWNLIST: u32 = 0x0003;
pub const CB_ADDSTRING: u32 = 0x0143;
pub const CB_GETCURSEL: u32 = 0x0147;
pub const CB_RESETCONTENT: u32 = 0x014B;
pub const CB_SETCURSEL: u32 = 0x014E;
pub const CB_GETCOUNT: u32 = 0x0146;
pub const CBN_SELCHANGE: u32 = 1;
pub const WM_CTLCOLOREDIT: u32 = 0x0133;
pub const WM_KEYDOWN: u32 = 0x0100;
pub const VK_CONTROL: i32 = 0x11;
pub const VK_F5: usize = 0x74;
pub const ICC_BAR_CLASSES: u32 = 0x0004;
pub const ICC_STANDARD_CLASSES: u32 = 0x4000;

pub const TTS_ALWAYSTIP: u32 = 0x01;
pub const TTS_NOPREFIX: u32 = 0x02;
pub const TTF_IDISHWND: u32 = 0x0001;
pub const TTF_SUBCLASS: u32 = 0x0010;
pub const TTM_SETMAXTIPWIDTH: u32 = 0x0400 + 24;
pub const TTM_SETDELAYTIME: u32 = 0x0400 + 3;
pub const TTM_ADDTOOLW: u32 = 0x0400 + 50;
pub const TTDT_AUTOPOP: usize = 2;
/// `TTN_FIRST - 10`, `TTN_FIRST = 0U - 520U`.
pub const TTN_GETDISPINFOW: u32 = @bitCast(@as(i32, -530));
pub const LPSTR_TEXTCALLBACKW: usize = std.math.maxInt(usize);

pub const TTTOOLINFOW = extern struct {
    cbSize: u32 = @sizeOf(TTTOOLINFOW),
    uFlags: u32 = 0,
    hwnd: ?HWND = null,
    uId: usize = 0,
    rect: RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
    hinst: ?HINSTANCE = null,
    lpszText: usize = 0,
    lParam: LPARAM = 0,
    lpReserved: ?*anyopaque = null,
};

pub const NMTTDISPINFOW = extern struct {
    hdr: NMHDR,
    lpszText: ?[*:0]const u16,
    szText: [80]u16,
    hinst: ?HINSTANCE,
    uFlags: u32,
    lParam: LPARAM,
};

pub const HKEY = *opaque {};
pub const HKEY_CURRENT_USER: HKEY = @ptrFromInt(0x8000_0001);
pub const RRF_RT_REG_DWORD: u32 = 0x0000_0010;
pub const REG_DWORD: u32 = 4;
pub extern "advapi32" fn RegGetValueW(HKEY, [*:0]const u16, [*:0]const u16, u32, ?*u32, ?*anyopaque, ?*u32) callconv(.winapi) i32;
pub extern "advapi32" fn RegSetKeyValueW(HKEY, [*:0]const u16, [*:0]const u16, u32, ?*const anyopaque, u32) callconv(.winapi) i32;
pub extern "user32" fn GetKeyState(i32) callconv(.winapi) i16;
pub extern "gdi32" fn CreateSolidBrush(u32) callconv(.winapi) ?HBRUSH;
pub extern "user32" fn SetFocus(?HWND) callconv(.winapi) ?HWND;

comptime {
    if (@sizeOf(usize) == 8 and @sizeOf(TTTOOLINFOW) != 72) @compileError("TTTOOLINFOW: zły rozmiar");
    if (@sizeOf(usize) == 8 and @sizeOf(NMTTDISPINFOW) != 216) @compileError("NMTTDISPINFOW: zły rozmiar");
}
const std = @import("std");
