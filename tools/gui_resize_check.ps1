# FerrumScope — test regresji GUI przy zmianie szerokości okna.
#
# Dla każdej kombinacji język × widok × zakładka:
#  1. uruchamia WŁASNY proces GUI (`--lang=<kod> --structured|--list --tab=<id>`)
#     i odsuwa okno od kursora (bez ruszania myszą — żeby nie wyskakiwały podpowiedzi);
#  2. robi zrzut odniesienia obszaru klienta (CopyFromScreen, prawdziwy ekran)
#     w rozmiarze startowym — „świeży start”;
#  3. zmienia szerokość WŁASNEGO okna przez SetWindowPos (po uchwycie z własnego
#     PID): min, 800, 1000, 1400, max, i z powrotem w dół; szerokości w pikselach
#     logicznych (96 DPI), przeliczane przez DPI okna; „min” = minimalny rozmiar
#     okna (WM_GETMINMAXINFO), „max” = szerokość obszaru roboczego ekranu;
#  4. po każdej zmianie sprawdza:
#       * nakładanie widocznych kontrolek (poza ramkami grup i kontenerami),
#       * wychodzenie kontrolek poza obszar rodzica,
#       * ucięcie tekstu: szerokość tekstu etykiety / przycisku / pola wyboru /
#         tytułu ramki (GetTextExtentPoint32, czcionka okna przy jego DPI) ≤
#         szerokość kontrolki,
#     i zapisuje zrzut ekranu;
#  5. wraca do rozmiaru startowego i porównuje zrzut z odniesieniem: poza
#     wnętrzami pól wartości (zmieniają się co sekundę) i listy muszą być
#     praktycznie identyczne — „duchy” starych napisów i ramek to różnica.
# Bez klikania po współrzędnych i bez SendKeys; zamykane są wyłącznie własne PID.
#
# Użycie (lokalnie, wymaga pulpitu):
#   tools\zig\zig-x86_64-windows-0.15.2\zig.exe build uia-tool install --prefix <katalog>
#   powershell -ExecutionPolicy Bypass -File tools\gui_resize_check.ps1 -Exe <katalog>\bin\ferrumscope-gui.exe -OutDir <katalog wyników>
#   [-Langs pl,en,de] [-Views structured,list] [-Tabs cpu,board] [-Widths min,800,1000,1400,max,1400,1000,800,min]
# Kod wyjścia: 0 = brak problemów, 1 = wykryto problem, 2 = część kombinacji
# nierozstrzygnięta (np. okno zasłonięte przez inne okno zawsze-na-wierzchu).
param(
    [string]$Exe = "zig-out\bin\ferrumscope-gui.exe",
    [Parameter(Mandatory = $true)][string]$OutDir,
    [string[]]$Langs = @("pl", "en", "de"),
    [string[]]$Views = @("structured", "list"),
    [string[]]$Tabs = @("cpu", "caches", "board", "memory", "graphics", "storage", "sensors", "bench", "about"),
    [string[]]$Widths = @("min", "800", "1000", "1400", "max", "1400", "1000", "800", "min"),
    # Dopuszczalny udział różniących się pikseli (poza obszarami zmiennymi) po powrocie do rozmiaru startowego.
    [double]$MaxDiff = 0.001,
    [int]$SettleMs = 700
)
$ErrorActionPreference = "Stop"
# "a,b" z powershell -File przychodzi jako jeden napis.
$Langs = @($Langs | ForEach-Object { $_ -split "," } | Where-Object { $_ })
$Views = @($Views | ForEach-Object { $_ -split "," } | Where-Object { $_ })
$Tabs = @($Tabs | ForEach-Object { $_ -split "," } | Where-Object { $_ })
$Widths = @($Widths | ForEach-Object { $_ -split "," } | Where-Object { $_ })
Add-Type -AssemblyName System.Drawing
Add-Type -ReferencedAssemblies System.Drawing @"
using System; using System.Collections.Generic; using System.Drawing; using System.Drawing.Imaging;
using System.Runtime.InteropServices; using System.Text;
public static class FsRz {
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
  [StructLayout(LayoutKind.Sequential)] public struct SIZE { public int cx, cy; }
  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] public struct LOGFONT {
    public int lfHeight, lfWidth, lfEscapement, lfOrientation, lfWeight;
    public byte lfItalic, lfUnderline, lfStrikeOut, lfCharSet, lfOutPrecision, lfClipPrecision, lfQuality, lfPitchAndFamily;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string lfFaceName;
  }
  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] public struct NONCLIENTMETRICS {
    public int cbSize, iBorderWidth, iScrollWidth, iScrollHeight, iCaptionWidth, iCaptionHeight;
    public LOGFONT lfCaptionFont; public int iSmCaptionWidth, iSmCaptionHeight; public LOGFONT lfSmCaptionFont;
    public int iMenuWidth, iMenuHeight; public LOGFONT lfMenuFont, lfStatusFont, lfMessageFont; public int iPaddedBorderWidth;
  }
  public delegate bool EnumProc(IntPtr h, IntPtr p);
  [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr h, EnumProc cb, IntPtr p);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h, ref POINT p);
  [DllImport("user32.dll")] public static extern IntPtr GetParent(IntPtr h);
  [DllImport("user32.dll")] public static extern int GetDlgCtrlID(IntPtr h);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr SendMessage(IntPtr h, uint m, IntPtr w, StringBuilder l);
  [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr h, int i);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint f);
  [DllImport("user32.dll")] public static extern bool RedrawWindow(IntPtr h, IntPtr r, IntPtr rgn, uint f);
  [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
  [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(POINT p);
  [DllImport("user32.dll")] public static extern IntPtr GetAncestor(IntPtr h, uint f);
  /// Czy okno `h` jest naprawdę na wierzchu w całym obszarze klienta (siatka 5×5
  /// punktów) — inaczej zrzut z ekranu pokazałby cudze okno, a nie artefakt.
  public static bool OnTop(IntPtr h) {
    var c = Client(h);
    for (int i = 0; i < 5; i++) for (int j = 0; j < 5; j++) {
      var p = new POINT { X = c.L + 2 + (c.R - c.L - 4) * i / 4, Y = c.T + 2 + (c.B - c.T - 4) * j / 4 };
      if (GetAncestor(WindowFromPoint(p), 2) != h) return false;
    }
    return true;
  }
  [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern int GetSystemMetricsForDpi(int i, uint dpi);
  [DllImport("user32.dll")] public static extern bool SystemParametersInfoForDpi(uint a, uint p, ref NONCLIENTMETRICS m, uint w, uint dpi);
  [DllImport("user32.dll")] public static extern IntPtr SetProcessDpiAwarenessContext(IntPtr c);
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] public static extern IntPtr GetDC(IntPtr h);
  [DllImport("user32.dll")] public static extern int ReleaseDC(IntPtr h, IntPtr dc);
  [DllImport("gdi32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr CreateFontIndirect(ref LOGFONT lf);
  [DllImport("gdi32.dll")] public static extern IntPtr SelectObject(IntPtr dc, IntPtr o);
  [DllImport("gdi32.dll")] public static extern bool DeleteObject(IntPtr o);
  [DllImport("gdi32.dll", CharSet = CharSet.Unicode)] public static extern bool GetTextExtentPoint32(IntPtr dc, string s, int n, out SIZE sz);

  public static void DpiAware() { if (SetProcessDpiAwarenessContext(new IntPtr(-4)) == IntPtr.Zero) SetProcessDPIAware(); }
  public static string Cls(IntPtr h) { var s = new StringBuilder(64); GetClassName(h, s, 64); return s.ToString(); }
  public static string Txt(IntPtr h) { var s = new StringBuilder(2048); SendMessage(h, 0x000D, new IntPtr(2048), s); return s.ToString(); }
  public static List<IntPtr> Children(IntPtr root) {
    var l = new List<IntPtr>(); EnumChildWindows(root, (h, p) => { l.Add(h); return true; }, IntPtr.Zero); return l;
  }
  public static RECT Client(IntPtr h) {
    RECT c; GetClientRect(h, out c); var p = new POINT(); ClientToScreen(h, ref p);
    return new RECT { L = p.X, T = p.Y, R = p.X + c.R, B = p.Y + c.B };
  }
  /// Szerokość tekstu w czcionce wiadomości (tej samej co okno) przy danym DPI.
  public static int TextWidth(string s, uint dpi) {
    var m = new NONCLIENTMETRICS(); m.cbSize = Marshal.SizeOf(typeof(NONCLIENTMETRICS));
    if (!SystemParametersInfoForDpi(0x29, (uint)m.cbSize, ref m, 0, dpi)) return -1;
    var f = CreateFontIndirect(ref m.lfMessageFont); var dc = GetDC(IntPtr.Zero); var old = SelectObject(dc, f);
    SIZE sz; GetTextExtentPoint32(dc, s, s.Length, out sz);
    SelectObject(dc, old); ReleaseDC(IntPtr.Zero, dc); DeleteObject(f);
    return sz.cx;
  }
  public static Bitmap Capture(RECT r) {
    var b = new Bitmap(r.R - r.L, r.B - r.T, PixelFormat.Format32bppArgb);
    using (var g = Graphics.FromImage(b)) g.CopyFromScreen(r.L, r.T, 0, 0, new Size(r.R - r.L, r.B - r.T));
    return b;
  }
  /// Liczba różniących się pikseli (poza prostokątami `skip`, we współrzędnych
  /// obrazu); `diff` dostaje obraz z różnicami na czerwono.
  public static long Diff(Bitmap a, Bitmap b, List<Rectangle> skip, out long compared, out Bitmap diff, out Rectangle box) {
    int w = Math.Min(a.Width, b.Width), h = Math.Min(a.Height, b.Height);
    diff = new Bitmap(w, h, PixelFormat.Format32bppArgb);
    var ra = a.LockBits(new Rectangle(0, 0, w, h), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
    var rb = b.LockBits(new Rectangle(0, 0, w, h), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
    var rd = diff.LockBits(new Rectangle(0, 0, w, h), ImageLockMode.WriteOnly, PixelFormat.Format32bppArgb);
    var pa = new int[w * h]; var pb = new int[w * h]; var pd = new int[w * h];
    for (int y = 0; y < h; y++) {
      Marshal.Copy(ra.Scan0 + y * ra.Stride, pa, y * w, w); Marshal.Copy(rb.Scan0 + y * rb.Stride, pb, y * w, w);
    }
    var mask = new bool[w * h];
    foreach (var s in skip) for (int y = Math.Max(0, s.Top); y < Math.Min(h, s.Bottom); y++) for (int x = Math.Max(0, s.Left); x < Math.Min(w, s.Right); x++) mask[y * w + x] = true;
    long n = 0; compared = 0; int x0 = w, y0 = h, x1 = -1, y1 = -1;
    for (int i = 0; i < w * h; i++) {
      int ca = pa[i], cb = pb[i];
      int g = (((ca >> 16) & 255) + ((ca >> 8) & 255) + (ca & 255)) / 3;
      if (mask[i]) { pd[i] = unchecked((int)0xFF000000) | (0x40 << 16) | (0x40 << 8) | 0x40; continue; }
      compared++;
      int d = Math.Max(Math.Abs(((ca >> 16) & 255) - ((cb >> 16) & 255)), Math.Max(Math.Abs(((ca >> 8) & 255) - ((cb >> 8) & 255)), Math.Abs((ca & 255) - (cb & 255))));
      if (d > 40) {
        n++; pd[i] = unchecked((int)0xFFFF0000);
        int x = i % w, y = i / w; if (x < x0) x0 = x; if (y < y0) y0 = y; if (x > x1) x1 = x; if (y > y1) y1 = y;
      } else { int l = 160 + g * 95 / 255; pd[i] = unchecked((int)0xFF000000) | (l << 16) | (l << 8) | l; }
    }
    for (int y = 0; y < h; y++) Marshal.Copy(pd, y * w, rd.Scan0 + y * rd.Stride, w);
    a.UnlockBits(ra); b.UnlockBits(rb); diff.UnlockBits(rd);
    box = x1 < 0 ? Rectangle.Empty : Rectangle.FromLTRB(x0, y0, x1 + 1, y1 + 1);
    return n;
  }
}
"@
[FsRz]::DpiAware()
$exePath = (Resolve-Path $Exe).Path
New-Item -ItemType Directory -Force $OutDir | Out-Null
Add-Type -AssemblyName System.Windows.Forms
$wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea

$SWP_NOSIZE = 0x1; $SWP_NOMOVE = 0x2; $SWP_NOZORDER = 0x4; $SWP_NOACTIVATE = 0x10
$HWND_TOPMOST = [IntPtr]::new(-1); $HWND_NOTOPMOST = [IntPtr]::new(-2)

function Skip([IntPtr]$w) {
    $c = [FsRz]::Cls($w)
    if ($c -in @("FerrumScopePanel", "SysTabControl32", "SysHeader32", "ComboLBox", "tooltips_class32", "msctls_updown32")) { return $true }
    $p = [FsRz]::GetParent($w)
    if ($p -ne [IntPtr]::Zero -and ([FsRz]::Cls($p) -in @("ComboBox", "SysListView32"))) { return $true }
    if ($c -eq "Button" -and (([FsRz]::GetWindowLong($w, -16) -band 0xF) -eq 7)) { return $true }   # BS_GROUPBOX
    return $false
}

function Rect([IntPtr]$w) { $r = New-Object FsRz+RECT; [FsRz]::GetWindowRect($w, [ref]$r) | Out-Null; $r }

# Kontrole układu w bieżącym rozmiarze; zwraca listę opisów problemów.
function Check([IntPtr]$h, [uint32]$dpi) {
    $errs = @()
    $all = @([FsRz]::Children($h) | Where-Object { [FsRz]::IsWindowVisible($_) })
    $tabPanels = @($all | Where-Object { [FsRz]::Cls($_) -eq "FerrumScopePanel" -and [FsRz]::Cls([FsRz]::GetParent($_)) -eq "FerrumScopePanel" })
    if ($tabPanels.Count -gt 1) { $errs += "widocznych kontenerów zakładek: $($tabPanels.Count)" }
    $items = @()
    $s = $dpi / 96.0
    foreach ($w in $all) {
        $r = Rect $w
        if (($r.R - $r.L) -le 0 -or ($r.B - $r.T) -le 0) { continue }
        $cls = [FsRz]::Cls($w); $txt = [FsRz]::Txt($w); $style = [FsRz]::GetWindowLong($w, -16)
        $par = [FsRz]::GetParent($w)
        # Kontrolka w całości w obszarze rodzica (nie licząc list rozwijanych kombi).
        if ($cls -ne "ComboLBox" -and $cls -ne "ComboBox" -and $par -ne [IntPtr]::Zero) {
            $pc = [FsRz]::Client($par)
            if ($r.L -lt $pc.L - 1 -or $r.T -lt $pc.T - 1 -or $r.R -gt $pc.R + 1 -or $r.B -gt $pc.B + 1) {
                if (-not ([FsRz]::Cls($par) -in @("ComboBox", "SysListView32"))) {
                    $errs += "poza rodzicem: '${cls}:$txt' [$($r.L),$($r.T),$($r.R),$($r.B)] rodzic [$($pc.L),$($pc.T),$($pc.R),$($pc.B)]"
                }
            }
        }
        # Ucięcie tekstu.
        if ($txt.Length -gt 0) {
            $cw = $r.R - $r.L
            $need = -1
            if ($cls -eq "Static" -and ($style -band 0xC000) -ne 0 -and [FsRz]::GetDlgCtrlID($w) -ne 108) {
                $need = [FsRz]::TextWidth($txt, $dpi)                       # etykieta (SS_ENDELLIPSIS), bez tytułu strony
            } elseif ($cls -eq "Button") {
                $bs = $style -band 0xF
                if ($bs -eq 7) { $need = [FsRz]::TextWidth($txt, $dpi) + [int](16 * $s) }                     # tytuł ramki
                elseif ($bs -in @(2, 3, 5, 6)) { $need = [FsRz]::TextWidth($txt, $dpi) + [FsRz]::GetSystemMetricsForDpi(71, $dpi) + [int](4 * $s) }  # pole wyboru
                elseif ($bs -in @(0, 1)) { $need = [FsRz]::TextWidth($txt, $dpi) + [int](10 * $s) }           # przycisk
            }
            if ($need -gt $cw) { $errs += "ucięty tekst: '${cls}:$txt' potrzeba $need px, jest $cw px" }
        }
        if (Skip $w) { continue }
        $items += [pscustomobject]@{ R = $r; C = $cls; X = $txt }
    }
    for ($a = 0; $a -lt $items.Count; $a++) {
        for ($b = $a + 1; $b -lt $items.Count; $b++) {
            $p = $items[$a].R; $q = $items[$b].R
            $ix = [Math]::Min($p.R, $q.R) - [Math]::Max($p.L, $q.L)
            $iy = [Math]::Min($p.B, $q.B) - [Math]::Max($p.T, $q.T)
            if ($ix -gt 2 -and $iy -gt 2) { $errs += "nakładanie '$($items[$a].C):$($items[$a].X)' i '$($items[$b].C):$($items[$b].X)' (${ix}x${iy} px)" }
        }
    }
    return , $errs
}

# Obszary zmienne w czasie (wartości odświeżane co sekundę): pola edycji i lista.
function VolatileRects([IntPtr]$h, $client) {
    $l = New-Object 'System.Collections.Generic.List[System.Drawing.Rectangle]'
    foreach ($w in [FsRz]::Children($h)) {
        if (-not [FsRz]::IsWindowVisible($w)) { continue }
        $c = [FsRz]::Cls($w)
        if ($c -eq "Edit" -or $c -eq "SysListView32") {
            $r = Rect $w
            $l.Add([System.Drawing.Rectangle]::FromLTRB($r.L - $client.L, $r.T - $client.T, $r.R - $client.L, $r.B - $client.T))
        }
    }
    return , $l
}

# Zrzut obszaru klienta z ekranu. Okno jest ustawiane jako TOPMOST i dopiero gdy
# WindowFromPoint potwierdzi, że nic go nie zasłania, robimy zrzut (do 20 prób);
# inaczej wyjątek — zasłonięte okno to wynik niepewny, a nie artefakt.
function Shot([IntPtr]$h, [string]$path) {
    $ok = $false
    for ($i = 0; $i -lt 20 -and -not $ok; $i++) {
        [FsRz]::SetWindowPos($h, $HWND_TOPMOST, 0, 0, 0, 0, $SWP_NOMOVE -bor $SWP_NOSIZE -bor $SWP_NOACTIVATE) | Out-Null
        Start-Sleep -Milliseconds 250
        $ok = [FsRz]::OnTop($h)
    }
    if (-not $ok) { throw "okno zasłonięte przez inne okno — zrzut niemożliwy" }
    $c = [FsRz]::Client($h)
    $bmp = [FsRz]::Capture($c)
    if ($path) { $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png) }
    return $bmp
}

$failures = 0
$inconclusive = 0
$summary = @()
foreach ($lang in $Langs) {
    foreach ($view in $Views) {
        foreach ($tab in $Tabs) {
            $tag = "${lang}_${view}_${tab}"
            $viewArg = if ($view -eq "list") { "--list" } else { "--structured" }
            $proc = Start-Process -FilePath $exePath -ArgumentList $viewArg, "--lang=$lang", "--tab=$tab" -PassThru
            $procId = $proc.Id
            try {
                for ($i = 0; $i -lt 50 -and $proc.MainWindowHandle -eq 0; $i++) { Start-Sleep -Milliseconds 200; $proc.Refresh() }
                $h = $proc.MainWindowHandle
                if ($h -eq 0) { throw "okno nie powstało ($tag)" }
                # Okno jest pokazywane dopiero po pierwszym odczycie danych.
                for ($i = 0; $i -lt 100 -and -not [FsRz]::IsWindowVisible($h); $i++) { Start-Sleep -Milliseconds 200 }
                $dpi = [FsRz]::GetDpiForWindow($h)
                $r0 = Rect $h
                $w0 = $r0.R - $r0.L; $h0 = $r0.B - $r0.T
                # Tylko przesunięcie (bez zmiany rozmiaru): odniesienie = świeży start.
                $cur = New-Object FsRz+POINT; [FsRz]::GetCursorPos([ref]$cur) | Out-Null
                $y = if ($cur.Y -gt $wa.Top + $wa.Height / 2) { $wa.Top } else { [Math]::Max($wa.Top, $wa.Bottom - $h0) }
                [FsRz]::SetWindowPos($h, [IntPtr]::Zero, $wa.Left, $y, 0, 0, $SWP_NOSIZE -bor $SWP_NOZORDER -bor $SWP_NOACTIVATE) | Out-Null
                Start-Sleep -Milliseconds 1800
                $client0 = [FsRz]::Client($h)
                $ref = Shot $h (Join-Path $OutDir "${tag}_0_fresh.png")
                $errs0 = Check $h $dpi
                $line = "[$tag] start ${w0}x${h0} (DPI $dpi): " + $(if ($errs0.Count) { "$($errs0.Count) problemów" } else { "OK" })
                $line; $errs0 | ForEach-Object { "    $_" }
                $failures += $errs0.Count
                $step = 0
                foreach ($wspec in $Widths) {
                    $step++
                    $target = switch ($wspec) { "min" { 100 } "max" { $wa.Width } default { [int]([int]$wspec * $dpi / 96) } }
                    [FsRz]::SetWindowPos($h, [IntPtr]::Zero, $wa.Left, $y, $target, $h0, $SWP_NOZORDER -bor $SWP_NOACTIVATE) | Out-Null
                    Start-Sleep -Milliseconds $SettleMs
                    $r = Rect $h
                    $ww = $r.R - $r.L
                    $errs = Check $h $dpi
                    $bmp = Shot $h (Join-Path $OutDir ("{0}_{1}_{2}.png" -f $tag, $step, $wspec))
                    $bmp.Dispose()
                    $state = if ($errs.Count) { "$($errs.Count) problemów" } else { "OK" }
                    "  $wspec -> szer. $ww px (logicznie $([int]($ww * 96 / $dpi))): $state"
                    $errs | ForEach-Object { "    $_" }
                    $failures += $errs.Count
                    $summary += [pscustomobject]@{ Lang = $lang; View = $view; Tab = $tab; Width = $wspec; Px = $ww; Problems = $errs.Count }
                }
                # Powrót do rozmiaru startowego i porównanie ze świeżym startem.
                [FsRz]::SetWindowPos($h, [IntPtr]::Zero, $wa.Left, $y, $w0, $h0, $SWP_NOZORDER -bor $SWP_NOACTIVATE) | Out-Null
                Start-Sleep -Milliseconds ($SettleMs + 500)
                $back = Shot $h (Join-Path $OutDir "${tag}_9_back.png")
                $skip = VolatileRects $h $client0
                $cmp = 0; $dimg = $null; $box = [System.Drawing.Rectangle]::Empty
                $n = [FsRz]::Diff($ref, $back, $skip, [ref]$cmp, [ref]$dimg, [ref]$box)
                $ratio = if ($cmp -gt 0) { $n / $cmp } else { 0 }
                $dimg.Save((Join-Path $OutDir "${tag}_diff.png"), [System.Drawing.Imaging.ImageFormat]::Png); $dimg.Dispose()
                $ref.Dispose(); $back.Dispose()
                $ok = $ratio -le $MaxDiff
                "  powrót do ${w0} px vs świeży start: różnych pikseli $n z $cmp ($([Math]::Round($ratio * 100, 3))%)" + $(if ($n -gt 0) { " obszar $($box.X),$($box.Y) $($box.Width)x$($box.Height)" } else { "" }) + $(if ($ok) { " OK" } else { " BŁĄD" })
                if (-not $ok) { $failures++ }
                $summary += [pscustomobject]@{ Lang = $lang; View = $view; Tab = $tab; Width = "back"; Px = $w0; Problems = $(if ($ok) { 0 } else { 1 }); Diff = $ratio }
            } catch {
                # Np. okno zasłonięte przez inne okno — wynik niepewny, nie artefakt.
                "  [$tag] NIEROZSTRZYGNIĘTE: $_"
                $inconclusive++
            } finally {
                $p = Get-Process -Id $procId -ErrorAction SilentlyContinue
                if ($p) { $p.CloseMainWindow() | Out-Null; if (-not $p.WaitForExit(4000)) { Stop-Process -Id $procId } }
            }
        }
    }
}
$summary | Export-Csv -NoTypeInformation -Encoding UTF8 (Join-Path $OutDir "summary.csv")
if ($failures -gt 0) { "WYNIK: $failures problemów"; exit 1 }
if ($inconclusive -gt 0) { "WYNIK: brak problemów, ale $inconclusive kombinacji nierozstrzygniętych"; exit 2 }
"WYNIK: brak problemów"; exit 0
