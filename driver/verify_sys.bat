@echo off
REM Weryfikacja zbudowanego .sys: czy to NAPRAWDĘ sterownik x64, a nie plik
REM user-mode, który tylko tak się nazywa.
call "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat" >nul 2>&1
set "OUT=%~dp0build"

echo === PE headers (machine / subsystem / entry) ===
dumpbin /nologo /headers "%OUT%\FerrumScopeMsr.sys" | findstr /C:"machine" /C:"subsystem" /C:"entry point" /C:"Subsystem" /C:" 14C" /C:"8664" /C:" 2" /C:"driver"

echo === imports (musi byc ntoskrnl/hal, NIE kernel32) ===
dumpbin /nologo /imports "%OUT%\FerrumScopeMsr.sys" | findstr /C:"ntoskrnl" /C:"hal.lib" /C:"HAL." /C:"kernel32"

echo === exports (sterownik NIE powinien eksportowac nic) ===
dumpbin /nologo /exports "%OUT%\FerrumScopeMsr.sys"

echo === rozmiar i SHA-256 ===
for %%F in ("%OUT%\FerrumScopeMsr.sys" "%OUT%\FerrumScopeMsr.pdb") do (
  for %%I in ("%%~fF") do echo %%~nxI  bytes=%%~zI
  certutil -hashfile "%%~fF" SHA256 | findstr /C:":" 
)
echo === DONE ===
