# Podpisanie testowe wg procedury WDK.
# NIE zmienia BCD. NIE ładuje sterownika. NIE restartuje.
# Poprzednia wersja (makecert + `signtool /t /r ...`) padala: `/t` przyjmuje
# URL timestampu jako argument i pochlonilo `/r` -> "Invalid Timestamp URL: /r".
# makecert jest przestarzaly i odrzucil kombinacje argumentow, wiec idziemy na
# wspierana sciezke PowerShell + signtool po odcisku palca.

$ErrorActionPreference = 'Stop'
$bin = 'C:\Program Files (x86)\Windows Kits\10\bin\10.0.26100.0\x64'
$sys = Join-Path $PSScriptRoot 'build\FerrumScopeMsr.sys'
$cn  = 'FerrumScope MSR DEV'

Write-Output '=== 1. usuwamy poprzedni certyfikat testowy (idempotencja) ==='
Get-ChildItem Cert:\CurrentUser\My | Where-Object { $_.Subject -eq "CN=$cn" } | ForEach-Object {
    Write-Output ("  usuwam: " + $_.Thumbprint)
    Remove-Item $_.PSPath
}

Write-Output '=== 2. tworzymy certyfikat podpisu kodu (self-signed, SHA-256/RSA-2048) ==='
$cert = New-SelfSignedCertificate `
    -Type CodeSigningCert `
    -Subject "CN=$cn" `
    -CertStoreLocation Cert:\CurrentUser\My `
    -KeyAlgorithm RSA -KeyLength 2048 -HashAlgorithm SHA256 `
    -KeyUsage DigitalSignature `
    -NotAfter (Get-Date).AddYears(3)
Write-Output ("  CN       : " + $cert.Subject)
Write-Output ("  Thumbprint: " + $cert.Thumbprint)
Write-Output ("  NotAfter : " + $cert.NotAfter)

Write-Output '=== 3. podpisujemy .sys (Authenticode, SHA-256, bez timestampu) ==='
# Bez /t: podpis testowy i tak nie trafi do dystrybucji, a /t wymaga
# osiagalnego serwera timestampingowego.
& "$bin\signtool.exe" sign /v /fd SHA256 /a /sha1 $cert.Thumbprint $sys
if ($LASTEXITCODE -ne 0) { Write-Output "SIGNFAIL signtool=$LASTEXITCODE"; exit 1 }

Write-Output '=== 4. weryfikacja podpisu narzedziem Microsoftu ==='
& "$bin\signtool.exe" verify /v /pa $sys
Write-Output ("  verify exit=" + $LASTEXITCODE)

Write-Output '=== 5. podsumowanie podpisu ==='
$sig = Get-AuthenticodeSignature $sys
Write-Output ("  Status        : " + $sig.Status)
Write-Output ("  StatusMessage : " + $sig.StatusMessage)
Write-Output ("  Signer        : " + $sig.SignerCertificate.Subject)
Write-Output ("  Thumbprint    : " + $sig.SignerCertificate.Thumbprint)
Write-Output ("  TimeStamper   : " + $(if ($null -eq $sig.TimeStamperCertificate) { 'brak (bez timestampu)' } else { $sig.TimeStamperCertificate.Subject }))
Write-Output '=== SIGN-DONE ==='
