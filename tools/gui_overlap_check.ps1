# FerrumScope — test regresji układu GUI (nakładanie się kontrolek zakładek).
#
# Dla każdej zakładki (wybieranej przez natywne UI Automation, bez klikania):
#  1. wylicza widoczne okna potomne (IsWindowVisible, cały łańcuch rodziców),
#  2. sprawdza, że widoczny jest najwyżej JEDEN kontener zakładki
#     (okno klasy FerrumScopePanel, którego rodzic też jest FerrumScopePanel),
#  3. sprawdza, że żadne dwie widoczne kontrolki się nie nakładają — poza ramkami
#     grup (BS_GROUPBOX), kontenerami, tab control i elementami wewnętrznymi
#     list/kombi (nagłówek listy, edycja/lista kombi),
#  4. robi PRAWDZIWY zrzut obszaru ekranu okna (CopyFromScreen po przeniesieniu
#     WŁASNEGO okna na wierzch) oraz zrzut PrintWindow — do porównania.
# Okno jest uruchamiane przez skrypt i zamykane wyłącznie po jego PID.
#
# Użycie (lokalnie, wymaga pulpitu; nie w CI bez sesji interaktywnej):
#   tools\zig\zig-x86_64-windows-0.15.2\zig.exe build uia-tool
#   powershell -ExecutionPolicy Bypass -File tools\gui_overlap_check.ps1 -OutDir <katalog> [-Lang en] [-View list]
# Kod wyjścia: 0 = brak nakładania, 1 = wykryto problem.
param(
    [string]$Exe = "zig-out\bin\ferrumscope-gui.exe",
    [string]$Uia = "zig-out\bin\uia-select-tab.exe",
    [Parameter(Mandatory = $true)][string]$OutDir,
    [string]$Lang = "pl",
    [ValidateSet("structured", "list")][string]$View = "structured",
    [int]$Tabs = 9
)
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Drawing
Add-Type @"
using System; using System.Collections.Generic; using System.Runtime.InteropServices; using System.Text;
public static class FsChk {
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
  public delegate bool EnumProc(IntPtr h, IntPtr p);
  [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr h, EnumProc cb, IntPtr p);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern IntPtr GetParent(IntPtr h);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr h, int i);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
  [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint f);
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  public static string Cls(IntPtr h) { var s = new StringBuilder(64); GetClassName(h, s, 64); return s.ToString(); }
  public static string Txt(IntPtr h) { var s = new StringBuilder(128); GetWindowText(h, s, 128); return s.ToString(); }
  public static List<IntPtr> Children(IntPtr root) {
    var l = new List<IntPtr>(); EnumChildWindows(root, (h, p) => { l.Add(h); return true; }, IntPtr.Zero); return l;
  }
}
"@
[FsChk]::SetProcessDPIAware() | Out-Null
$exePath = (Resolve-Path $Exe).Path
$uiaPath = (Resolve-Path $Uia).Path
New-Item -ItemType Directory -Force $OutDir | Out-Null
$viewArg = if ($View -eq "list") { "--list" } else { "--structured" }
$proc = Start-Process -FilePath $exePath -ArgumentList $viewArg, "--lang=$Lang" -PassThru
$procId = $proc.Id
for ($i = 0; $i -lt 50 -and $proc.MainWindowHandle -eq 0; $i++) { Start-Sleep -Milliseconds 200; $proc.Refresh() }
Start-Sleep -Milliseconds 2500
$proc.Refresh()
$h = $proc.MainWindowHandle
$failures = 0

function Skip([IntPtr]$w) {
    $c = [FsChk]::Cls($w)
    if ($c -in @("FerrumScopePanel", "SysTabControl32", "SysHeader32", "ComboLBox", "tooltips_class32", "msctls_updown32")) { return $true }
    $p = [FsChk]::GetParent($w)
    if ($p -ne [IntPtr]::Zero) {
        $pc = [FsChk]::Cls($p)
        if ($pc -in @("ComboBox", "SysListView32")) { return $true }
    }
    if ($c -eq "Button") {
        $style = [FsChk]::GetWindowLong($w, -16)
        if (($style -band 0xF) -eq 7) { return $true }   # BS_GROUPBOX
    }
    return $false
}

try {
    for ($t = 0; $t -lt $Tabs; $t++) {
        & $uiaPath ([string][int64]$h) "#$t" | Out-Null
        Start-Sleep -Milliseconds 1500
        $all = [FsChk]::Children($h) | Where-Object { [FsChk]::IsWindowVisible($_) }
        # 1 kontener zakładki
        $tabPanels = @($all | Where-Object { [FsChk]::Cls($_) -eq "FerrumScopePanel" -and [FsChk]::Cls([FsChk]::GetParent($_)) -eq "FerrumScopePanel" })
        if ($tabPanels.Count -gt 1) { "BŁĄD zakładka #${t}: widocznych kontenerów zakładek: $($tabPanels.Count)"; $failures++ }
        # nakładanie
        $items = @()
        foreach ($w in $all) {
            if (Skip $w) { continue }
            $r = New-Object FsChk+RECT; [FsChk]::GetWindowRect($w, [ref]$r) | Out-Null
            if (($r.R - $r.L) -le 0 -or ($r.B - $r.T) -le 0) { continue }
            $items += [pscustomobject]@{ H = $w; R = $r; C = [FsChk]::Cls($w); X = [FsChk]::Txt($w) }
        }
        for ($a = 0; $a -lt $items.Count; $a++) {
            for ($b = $a + 1; $b -lt $items.Count; $b++) {
                $p = $items[$a].R; $q = $items[$b].R
                $ix = [Math]::Min($p.R, $q.R) - [Math]::Max($p.L, $q.L)
                $iy = [Math]::Min($p.B, $q.B) - [Math]::Max($p.T, $q.T)
                if ($ix -gt 2 -and $iy -gt 2) {
                    "BŁĄD zakładka #${t}: nakładanie '$($items[$a].C):$($items[$a].X)' i '$($items[$b].C):$($items[$b].X)' (${ix}x${iy} px)"
                    $failures++
                }
            }
        }
        # zrzuty: prawdziwy ekran + PrintWindow
        [FsChk]::BringWindowToTop($h) | Out-Null; [FsChk]::SetForegroundWindow($h) | Out-Null
        Start-Sleep -Milliseconds 500
        $r = New-Object FsChk+RECT; [FsChk]::GetWindowRect($h, [ref]$r) | Out-Null
        $wd = $r.R - $r.L; $ht = $r.B - $r.T
        $bmp = New-Object System.Drawing.Bitmap $wd, $ht
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.CopyFromScreen($r.L, $r.T, 0, 0, (New-Object System.Drawing.Size $wd, $ht))
        $g.Dispose(); $bmp.Save((Join-Path $OutDir ("screen_{0}_{1}_{2}.png" -f $Lang, $View, $t)), [System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
        $bmp = New-Object System.Drawing.Bitmap $wd, $ht
        $g = [System.Drawing.Graphics]::FromImage($bmp); $hdc = $g.GetHdc()
        [FsChk]::PrintWindow($h, $hdc, 2) | Out-Null; $g.ReleaseHdc($hdc); $g.Dispose()
        $bmp.Save((Join-Path $OutDir ("print_{0}_{1}_{2}.png" -f $Lang, $View, $t)), [System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
        "zakładka #${t}: widocznych kontrolek $($items.Count), kontenerów $($tabPanels.Count)"
    }
} finally {
    $p = Get-Process -Id $procId -ErrorAction SilentlyContinue
    if ($p) { $p.CloseMainWindow() | Out-Null; if (-not $p.WaitForExit(4000)) { Stop-Process -Id $procId } }
    "zamknięto PID=$procId"
}
if ($failures -gt 0) { "WYNIK: $failures problemów"; exit 1 } else { "WYNIK: brak nakładania"; exit 0 }
