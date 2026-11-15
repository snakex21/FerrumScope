@echo off
REM ===========================================================================
REM Podpisanie testowe wg procedury WDK.
REM
REM UWAGA: to podpisanie TESTOWE. Zmienia BCD? NIE. Laduje sterownik? NIE.
REM ===========================================================================
call "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat" >nul 2>&1
set "KBIN=C:\Program Files (x86)\Windows Kits\10\bin\10.0.26100.0\x64"
set "OUT=%~dp0build"
set "CN=FerrumScope MSR DEV"

echo === 1. certyfikat testowy (makecert) ===
del /q "%OUT%..\FerrumScopeTestCert.cer" 2>nul
"%KBIN%\makecert.exe" /n "%CN%" /r /h0 /e /sk /ss PrivateCertStore /sr LocalMachine "%OUT%..\FerrumScopeTestCert.cer"
if errorlevel 1 (
    echo SIGNFAIL: makecert
    exit /b 1
)

echo === 2. podpisujemy .sys (authenticode, SHA-256) ===
"%KBIN%\signtool.exe" sign /v /fd SHA256 /a /n "%CN%" /s My /t /r LocalMachine "%OUT%\FerrumScopeMsr.sys"
if errorlevel 1 (
    echo SIGNFAIL: signtool sign
    exit /b 1
)

echo === 3. weryfikacja podpisu narzedziem Microsoftu ===
"%KBIN%\signtool.exe" verify /v /pa "%OUT%\FerrumScopeMsr.sys"

echo === 4. certyfikat w sklepie (CurrentUser\My) ===
certutil -user -store My 2>nul | findstr /C:"FerrumScope"

echo === SIGN-DONE ===
