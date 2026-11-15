@echo off
REM ===========================================================================
REM FerrumScope — budowa sterownika x64
REM
REM Kolejność: najpierw kompilacja z /W4 (bez /WX), zeby zobaczyc WSZYSTKIE
REM ostrzezenia do analizy, a nie tylko te, ktore blokuja build.
REM ===========================================================================
setlocal enabledelayedexpansion

set "VCTOOLS=C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat"
set "KITSROOT=C:\Program Files (x86)\Windows Kits\10"
set "KDKVER=10.0.26100.0"
set "HERE=%~dp0"
REM Katalog wynikowy mozna nadpisac: set FERRUM_DRIVER_OUT=... (np. katalog tymczasowy).
if defined FERRUM_DRIVER_OUT (set "OUT=%FERRUM_DRIVER_OUT%") else (set "OUT=%HERE%build")

if not exist "%OUT%" mkdir "%OUT%"

call "%VCTOOLS%" >nul
if errorlevel 1 (
    echo BUILDFAIL: vcvars64 failed
    exit /b 1
)

echo === MSVC ===
echo MSVC_TOOLSET: 14.44.35207 (cl.exe ponizej)
echo CL_PATH: %VSCMD_ARG_TGT_ARCH%
cl 2>&1 | findstr /C:"Version"
echo === KITS === %KDKVER%

REM UWAGA: /kernel SAM definiuje _KERNEL_MODE i makra architektury (_AMD64_ itd.).
REM Wczesniejsza wersja tego skryptu przekazywala /D_KERNEL_MODE /DAMD64
REM recznie. /D_KERNEL_MODE wywolywalo ostrzezenie C4117 ("nazwa makra jest
REM zarezerwowana"), a celnikiem koncowym byl komunikat "No Target
REM Architecture" — to byla wina skryptu, nie sterownika.
REM /D_AMD64_ jest WYMAGANE w tym toolchainu. Zmierzone (jednorazowa sonda, usunieta):
REM   bez /D_AMD64_ -> ntdef.h(197): #error "No Target Architecture"
REM   z    /D_AMD64_ -> RC=0, naglowki jadra wlaczone
REM Kompilator to MSVC 19.44.35227 Hostx64\x64, banner "dla x64", a mimo to
REM _AMD64_ nie jest zdefiniowane (oprócz _WIN64, które jest). Zmienne CL/_CL_
REM z vcvars sa puste, wiec nikt tego nie miesza. To wlasnie powod, dla
REM ktorego oficjalna sciezka MSBuild+WDK (MSB8020) tez zawodla.
REM NTDDI_VERSION >= NTDDI_WIN7 jest WYMAGANE: API processor groups
REM (KPROCESSOR_NUMBER, GROUP_AFFINITY, KeGetProcessorNumberEx,
REM KeSetSystemGroupAffinityThread, KeRevertToGroupAffinity,
REM KeQueryActiveProcessorCountEx) sa bramkowane dokladnie taDyF. Bez tego
REM flagi kompilator zglasza C4013 "niezdefiniowany KeGetProcessorNumberEx"
REM i nastepuja bledy "niezadeklarowany identyfikator ProcNum".
REM Bezposrednia kompilacja bez systemu buildow WDK nie dostarcza tej flagi.
REM WAZNE: przekazanie /DNTDDI_VERSION=NTDDI_WIN10 NIE DZIALA.
REM NTDDI_WIN10 jest makrem o wartosci 0x0A000000 — ale gdy zostanie podstawione
REM jako identyfikator, preprocesor widzi w #if nieznana nazwe i traktuje ja
REM jako 0. Bramka "NTDDI_VERSION >= NTDDI_WIN7" daje wtedy fałsz i API
REM processor groups pozostaja niezadeklarowane. Dlatego liczba, nie nazwa.
set NTDDI=0x0A000000

echo === COMPILE /c ===
cl /nologo /c /kernel /D_AMD64_ /DNTDDI_VERSION=%NTDDI% /W4 /GS /Oi /Zl /GR- /std:c17 ^
   /I"%KITSROOT%\Include\%KDKVER%\km" ^
   /I"%KITSROOT%\Include\%KDKVER%\shared" ^
   /I"%KITSROOT%\Include\%KDKVER%\um" ^
   /Fo"%OUT%\ferrum_msr.obj" ^
   /Fd"%OUT%\ferrum_msr.pdb" ^
   "%HERE%ferrum_msr.c"
if errorlevel 1 (
    echo BUILDFAIL: compile
    exit /b 1
)

echo === LINK ===
REM BufferOverflowK.lib dostarcza __security_cookie / __security_check_cookie
REM dla trybu jadra. Bez niej link konczy sie LNK2019. Uzywamy jej zamiast
REM /GS- — wylaczenie ochrony buforow byloby pozornym rozwiazaniem.
REM /optref usuniete: to opcja MinGW/GCC, nie MSVC (link dal LNK4044).
link /nologo /driver /subsystem:native /entry:DriverEntry /machine:x64 ^
   /out:"%OUT%\FerrumScopeMsr.sys" /pdb:"%OUT%\FerrumScopeMsr.pdb" ^
   /debug ^
   /libpath:"%KITSROOT%\Lib\%KDKVER%\km\x64" ^
   /libpath:"%KITSROOT%\Lib\%KDKVER%\um\x64" ^
   "%OUT%\ferrum_msr.obj" ^
   ntoskrnl.lib hal.lib wmilib.lib wdmsec.lib BufferOverflowK.lib
if errorlevel 1 (
    echo BUILDFAIL: link
    exit /b 1
)

echo === BUILT ===
dir /b "%OUT%"
exit /b 0
