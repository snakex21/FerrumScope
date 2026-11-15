@echo off
rem FerrumScope GUI: buduje projekt (jesli trzeba) i uruchamia okno.
rem Uzycie: ferrumscope-gui.bat [--tab=sensors]
setlocal
cd /d "%~dp0"

set "ZIG=%~dp0tools\zig\zig-x86_64-windows-0.15.2\zig.exe"
set "GUI=%~dp0zig-out\bin\ferrumscope-gui.exe"

if not exist "%ZIG%" (
    echo [blad] Nie znaleziono zig.exe: %ZIG%
    pause
    exit /b 1
)

echo Buduje FerrumScope...
"%ZIG%" build
if errorlevel 1 (
    echo [blad] Budowanie nie powiodlo sie - szczegoly powyzej.
    pause
    exit /b 1
)

if not exist "%GUI%" (
    echo [blad] Brak %GUI% po budowaniu.
    pause
    exit /b 1
)

start "" "%GUI%" %*
endlocal
