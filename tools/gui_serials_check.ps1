# FerrumScope — test przełącznika „Pokaż numery seryjne” w działającym GUI.
#
# Dla zakładek Płyta główna, Pamięć i Dyski:
#  1. uruchamia WŁASNY proces GUI (`--structured --tab=<id>`),
#  2. odczytuje pola wartości (WM_GETTEXT) i wybiera zamaskowane (same `*`),
#  3. zaznacza pole wyboru „Pokaż numery seryjne” przez natywne UI Automation
#     (`uia-select-tab <hwnd> toggle:104` = TogglePattern.Toggle, bez klikania),
#     sprawdza, że te same pola pokazują teraz jawną wartość tej samej długości,
#  4. odznacza je i sprawdza, że wróciło dokładnie to samo maskowanie.
# Bez restartu programu. Numerów nie wypisuje (tylko długości). Zamyka tylko własny PID.
#
# Użycie:
#   tools\zig\zig-x86_64-windows-0.15.2\zig.exe build uia-tool install --prefix <katalog>
#   powershell -ExecutionPolicy Bypass -File tools\gui_serials_check.ps1 -Exe <katalog>\bin\ferrumscope-gui.exe -Uia <katalog>\bin\uia-select-tab.exe
# Kod wyjścia: 0 = przełącznik działa, 1 = błąd.
param(
    [string]$Exe = "zig-out\bin\ferrumscope-gui.exe",
    [string]$Uia = "zig-out\bin\uia-select-tab.exe",
    [string[]]$Tabs = @("board", "memory", "storage"),
    [string]$Lang = "pl",
    # Brak zamaskowanego pola (np. zaślepka firmware zamiast numeru modułu w
    # SMBIOS — pokazywana jawnie, bo to nie jest numer) = błąd zamiast pominięcia.
    [switch]$Strict
)
$ErrorActionPreference = "Stop"
$Tabs = @($Tabs | ForEach-Object { $_ -split "," } | Where-Object { $_ })
Add-Type @"
using System; using System.Collections.Generic; using System.Runtime.InteropServices; using System.Text;
public static class FsSer {
  public delegate bool EnumProc(IntPtr h, IntPtr p);
  [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr h, EnumProc cb, IntPtr p);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern int GetDlgCtrlID(IntPtr h);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr SendMessage(IntPtr h, uint m, IntPtr w, StringBuilder l);
  [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
  public static string Cls(IntPtr h) { var s = new StringBuilder(64); GetClassName(h, s, 64); return s.ToString(); }
  public static string Txt(IntPtr h) { var s = new StringBuilder(1024); SendMessage(h, 0x000D, new IntPtr(1024), s); return s.ToString(); }
  public static List<IntPtr> Children(IntPtr root) {
    var l = new List<IntPtr>(); EnumChildWindows(root, (h, p) => { l.Add(h); return true; }, IntPtr.Zero); return l;
  }
}
"@
$exePath = (Resolve-Path $Exe).Path
$uiaPath = (Resolve-Path $Uia).Path
$failures = 0

function VisibleEdits([IntPtr]$h) { @([FsSer]::Children($h) | Where-Object { [FsSer]::Cls($_) -eq "Edit" -and [FsSer]::IsWindowVisible($_) }) }
function IsMasked([string]$s) { $s.Length -gt 0 -and $s -match '^\*+$' }
function Checked([IntPtr]$chk) { [int][FsSer]::SendMessage($chk, 0x00F0, [IntPtr]::Zero, [IntPtr]::Zero) }  # BM_GETCHECK

foreach ($tab in $Tabs) {
    $proc = Start-Process -FilePath $exePath -ArgumentList "--structured", "--lang=$Lang", "--tab=$tab" -PassThru
    $procId = $proc.Id
    try {
        for ($i = 0; $i -lt 50 -and $proc.MainWindowHandle -eq 0; $i++) { Start-Sleep -Milliseconds 200; $proc.Refresh() }
        $h = $proc.MainWindowHandle
        for ($i = 0; $i -lt 100 -and -not [FsSer]::IsWindowVisible($h); $i++) { Start-Sleep -Milliseconds 200 }
        Start-Sleep -Milliseconds 1500
        $chk = [FsSer]::Children($h) | Where-Object { [FsSer]::GetDlgCtrlID($_) -eq 104 -and [FsSer]::Cls($_) -eq "Button" } | Select-Object -First 1
        if (-not $chk) { "[$tab] BŁĄD: brak pola Pokaż numery seryjne (ID 104)"; $failures++; continue }
        if ((Checked $chk) -ne 0) { "[$tab] BŁĄD: przełącznik zaznaczony na starcie"; $failures++ }
        $masked = @(VisibleEdits $h | Where-Object { IsMasked ([FsSer]::Txt($_)) })
        if ($masked.Count -eq 0) {
            if ($Strict) { "[$tab] BŁĄD: brak zamaskowanego pola"; $failures++ }
            else { "[$tab] POMINIĘTE: brak zamaskowanego numeru (np. zaślepka firmware w SMBIOS) — nic do odsłonięcia" }
            continue
        }
        $before = @($masked | ForEach-Object { [FsSer]::Txt($_) })

        & $uiaPath ([string][int64]$h) "toggle:104" | Out-Null
        if ($LASTEXITCODE -ne 0) { "[$tab] BŁĄD: UIA Toggle (kod $LASTEXITCODE)"; $failures++; continue }
        Start-Sleep -Milliseconds 800
        $on = Checked $chk
        $shown = @($masked | ForEach-Object { [FsSer]::Txt($_) })
        for ($k = 0; $k -lt $masked.Count; $k++) {
            $ok = $on -eq 1 -and -not (IsMasked $shown[$k]) -and $shown[$k].Trim().Length -eq $before[$k].Length
            "[$tab] zaznaczone: pole $k — " + $(if ($ok) { "odsłonięte ($($shown[$k].Trim().Length) znaków) OK" } else { "BŁĄD (stan=$on, nadal maska lub inna długość)" })
            if (-not $ok) { $failures++ }
        }

        & $uiaPath ([string][int64]$h) "toggle:104" | Out-Null
        Start-Sleep -Milliseconds 800
        $off = Checked $chk
        $again = @($masked | ForEach-Object { [FsSer]::Txt($_) })
        for ($k = 0; $k -lt $masked.Count; $k++) {
            $ok = $off -eq 0 -and $again[$k] -eq $before[$k]
            "[$tab] odznaczone: pole $k — " + $(if ($ok) { "zamaskowane ponownie OK" } else { "BŁĄD (stan=$off)" })
            if (-not $ok) { $failures++ }
        }
    } finally {
        $p = Get-Process -Id $procId -ErrorAction SilentlyContinue
        if ($p) { $p.CloseMainWindow() | Out-Null; if (-not $p.WaitForExit(4000)) { Stop-Process -Id $procId } }
    }
}
if ($failures -gt 0) { "WYNIK: $failures problemów"; exit 1 } else { "WYNIK: przełącznik numerów seryjnych działa"; exit 0 }
