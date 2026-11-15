@echo off
REM Tworzy katalog .cat dla paczki sterownika i podpisuje go testowo.
REM NIE zmienia BCD. NIE instaluje. NIE laduje sterownika. NIE restartuje.
REM Wejscie: driver\ferrum_msr.inf + driver\build\FerrumScopeMsr.sys (juz podpisany).
REM Wyjscie: driver\package\{FerrumScopeMsr.inf, FerrumScopeMsr.sys, FerrumScopeMsr.cat}
setlocal
set HERE=%~dp0
set PKG=%HERE%package
set BIN=C:\Program Files (x86)\Windows Kits\10\bin\10.0.26100.0
set THUMB=B8078EAF
if not exist "%PKG%" mkdir "%PKG%"
copy /Y "%HERE%ferrum_msr.inf" "%PKG%\FerrumScopeMsr.inf" >nul || (echo COPYFAIL inf & exit /b 1)
copy /Y "%HERE%build\FerrumScopeMsr.sys" "%PKG%\FerrumScopeMsr.sys" >nul || (echo COPYFAIL sys & exit /b 1)

echo === INF2CAT ===
"%BIN%\x86\Inf2Cat.exe" /driver:"%PKG%" /os:10_X64 /verbose
if errorlevel 1 (echo INF2CATFAIL & exit /b 1)

echo === SIGN CAT ===
for /f "usebackq delims=" %%T in (`powershell -NoProfile -Command "(Get-ChildItem Cert:\CurrentUser\My | Where-Object { $_.Subject -eq 'CN=FerrumScope MSR DEV' } | Select-Object -First 1).Thumbprint"`) do set FULLTHUMB=%%T
if "%FULLTHUMB%"=="" (echo NOCERT & exit /b 1)
echo Thumbprint: %FULLTHUMB%
"%BIN%\x64\signtool.exe" sign /fd SHA256 /sha1 %FULLTHUMB% "%PKG%\FerrumScopeMsr.cat"
if errorlevel 1 (echo SIGNFAIL & exit /b 1)

echo === VERIFY ===
"%BIN%\x64\signtool.exe" verify /v /pa /c "%PKG%\FerrumScopeMsr.cat" "%PKG%\FerrumScopeMsr.sys"
echo verify exit=%errorlevel% (oczekiwane !=0: root testowy nie jest zaufany)
dir "%PKG%"
echo === CAT-DONE ===
