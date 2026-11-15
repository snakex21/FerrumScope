# FerrumScope - zrzuty ekranu WŁASNEGO okna GUI (bez klikania po współrzędnych).
#
#  * okno uruchamiane przez ten skrypt; zamykane wyłącznie po jego PID,
#  * zakładki przełączane przez natywne UI Automation (tools/uia_select_tab.zig,
#    SelectionItemPattern.Select na elemencie TabItem),
#  * obraz z PrintWindow(PW_RENDERFULLCONTENT) na uchwycie okna - nie zrzut pulpitu,
#  * żadnych SendKeys ani symulowanych kliknięć.
#
# Przygotowanie:  tools\zig\zig-x86_64-windows-0.15.2\zig.exe build uia-tool
# Użycie:
#   powershell -ExecutionPolicy Bypass -File tools\gui_screenshots.ps1 -OutDir docs\screenshots
#   -NonElevated       okno bez uprawnień administratora (runas /trustlevel:0x20000)
#   -View list         widok „Pełna lista” (domyślnie: structured)
#   -Prefix admin_     prefiks nazw plików
#   -Tabs "Dyski"      tylko wybrane zakładki
param(
    [string]$Exe = "zig-out\bin\ferrumscope-gui.exe",
    [string]$Uia = "zig-out\bin\uia-select-tab.exe",
    [Parameter(Mandatory = $true)][string]$OutDir,
    [switch]$NonElevated,
    [ValidateSet("structured", "list")][string]$View = "structured",
    [string]$Prefix = "",
    [string[]]$Tabs = @("CPU", "Cache", "Płyta główna", "Pamięć", "Grafika", "Dyski", "Czujniki", "Bench", "O programie")
)
$ErrorActionPreference = "Stop"
# -Tabs "A,B" z powershell -File przychodzi jako jeden napis.
$Tabs = @($Tabs | ForEach-Object { $_ -split "," } | Where-Object { $_ })
Add-Type -AssemblyName System.Drawing
Add-Type @"
using System; using System.Runtime.InteropServices;
public static class FsWin {
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint f);
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
}
"@
[FsWin]::SetProcessDPIAware() | Out-Null

$exePath = (Resolve-Path $Exe).Path
$uiaPath = (Resolve-Path $Uia).Path
New-Item -ItemType Directory -Force $OutDir | Out-Null
$viewArg = if ($View -eq "list") { "--list" } else { "--structured" }
$started = Get-Date

if ($NonElevated) {
    # runas zwraca od razu; własny proces rozpoznajemy po ścieżce i czasie startu.
    Start-Process -FilePath "runas.exe" -ArgumentList "/trustlevel:0x20000", "`"\`"$exePath\`" $viewArg`"" -WindowStyle Hidden
    $proc = $null
    for ($i = 0; $i -lt 50 -and -not $proc; $i++) {
        Start-Sleep -Milliseconds 200
        $proc = Get-Process -Name "ferrumscope-gui" -ErrorAction SilentlyContinue |
            Where-Object { $_.Path -eq $exePath -and $_.StartTime -ge $started } | Select-Object -First 1
    }
} else {
    $proc = Start-Process -FilePath $exePath -ArgumentList $viewArg -PassThru
}
if (-not $proc) { throw "nie udało się uruchomić $exePath" }
$procId = $proc.Id
"PID=$procId widok=$View"

for ($i = 0; $i -lt 50 -and $proc.MainWindowHandle -eq 0; $i++) { Start-Sleep -Milliseconds 200; $proc.Refresh() }
Start-Sleep -Milliseconds 2500
$proc.Refresh()
$h = $proc.MainWindowHandle
if ($h -eq 0) { throw "okno nie powstało" }

$names = @{ "CPU" = "cpu"; "Cache" = "caches"; "Płyta główna" = "board"; "Pamięć" = "memory"; "Grafika" = "graphics";
            "Dyski" = "storage"; "Czujniki" = "sensors"; "Bench" = "bench"; "O programie" = "about" }
try {
    foreach ($t in $Tabs) {
        & $uiaPath ([string][int64]$h) $t
        if ($LASTEXITCODE -ne 0) { "UIA: nie wybrano zakładki '$t' (kod $LASTEXITCODE)"; continue }
        Start-Sleep -Milliseconds 1800
        $r = New-Object FsWin+RECT
        [FsWin]::GetWindowRect($h, [ref]$r) | Out-Null
        $wd = $r.R - $r.L; $ht = $r.B - $r.T
        $bmp = New-Object System.Drawing.Bitmap $wd, $ht
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $hdc = $g.GetHdc()
        $ok = [FsWin]::PrintWindow($h, $hdc, 2)
        $g.ReleaseHdc($hdc); $g.Dispose()
        $out = Join-Path $OutDir ("{0}{1}.png" -f $Prefix, $names[$t])
        $bmp.Save($out, [System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
        "zapisano $out ($wd x $ht, PrintWindow=$ok)"
    }
} finally {
    # Zamykamy wyłącznie własny proces, po PID.
    $p = Get-Process -Id $procId -ErrorAction SilentlyContinue
    if ($p) {
        $p.CloseMainWindow() | Out-Null
        if (-not $p.WaitForExit(4000)) { Stop-Process -Id $procId }
    }
    "zamknięto PID=$procId"
}
