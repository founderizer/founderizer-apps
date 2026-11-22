# The build of build-setup.sh, in the build VM's SSH session. The caller sets $version, $build and $arch ("arm64" or
# "arm64,x64"). It runs C:\fz\proof-a\build-release-welcome.ps1 (the copy of release/build-release.ps1 with
# -p:FounderizerWelcome=true, in no commit) on C:\fz\proof-a\src\windows, into C:\fz\proof-a\release, and checks what it
# made.
$ErrorActionPreference = 'Stop'
# No variable whose name starts with Founderizer, in any scope: MSBuild takes such a variable as the property of the
# same name (FounderizerProofsOn=true turns the proofs' parts on; FounderizerWelcome turns the welcome page off).
$found = foreach ($scope in 'Machine', 'User', 'Process') {
    [Environment]::GetEnvironmentVariables($scope).Keys | Where-Object { $_ -like 'Founderizer*' } | ForEach-Object { "$scope $_" }
}
if ($found) { throw ('the build VM has variables that change the build: ' + ($found -join ', ') + '. Remove them, then build again.') }
'no variable whose name starts with Founderizer (machine, user, process)'
# A reused MSBuild node keeps the environment of the build that started it.
$env:MSBUILDDISABLENODEREUSE = '1'
& "$env:ProgramFiles\dotnet\dotnet.exe" build-server shutdown | Out-Null
$out = 'C:\fz\proof-a\release'
$arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', 'C:\fz\proof-a\build-release-welcome.ps1',
               '-Source', 'C:\fz\proof-a\src\windows', '-Version', $version, '-Build', $build, '-Arch', $arch, '-Out', $out)
& powershell.exe @arguments
if ($LASTEXITCODE -ne 0) { throw "the build failed: exit $LASTEXITCODE" }
$release = Join-Path $out "$version-$build"
$builds = Get-Content -Raw (Join-Path $release 'builds.json') | ConvertFrom-Json
if ($builds.proofs -ne $false) { throw 'builds.json does not say proofs: false' }
foreach ($a in ($arch -split ',')) {
    $dll = Join-Path $out "stage-$a\build\Founderizer.App.dll"
    $bytes = [IO.File]::ReadAllBytes($dll)
    # A name of the metadata is UTF-8, a string of the code UTF-16: both are searched, at both alignments.
    $latin = [Text.Encoding]::GetEncoding(28591).GetString($bytes)
    $wide = [Text.Encoding]::Unicode.GetString($bytes) + [Text.Encoding]::Unicode.GetString($bytes, 1, $bytes.Length - 1)
    if ($latin.Contains('GetEnvironmentVariable') -or $wide.Contains('GetEnvironmentVariable')) {
        throw "Founderizer.App.dll for $a names GetEnvironmentVariable"
    }
    "Founderizer.App.dll for ${a}: names no GetEnvironmentVariable ($($bytes.Length) bytes)"
    $ssh = (Get-Item (Join-Path $out "stage-$a\build\Renci.SshNet.dll")).VersionInfo
    "Renci.SshNet.dll for ${a}: SSH.NET $($ssh.ProductVersion)"
    $setup = Join-Path $release "Founderizer-Setup-$version-$a.exe"
    $signature = Get-AuthenticodeSignature -FilePath $setup
    if ($signature.Status -ne 'Valid') { throw "the setup for $a has no valid signature: $($signature.Status)" }
    "setup for ${a}: signature Valid, $($signature.SignerCertificate.Subject)"
}
$certificate = Get-ChildItem -Path Cert:\LocalMachine\My -CodeSigningCert |
    Where-Object Subject -eq 'CN=Founderizer Test Signing (build VM)' | Select-Object -First 1
Export-Certificate -Cert $certificate -FilePath (Join-Path $release 'founderizer-test-signing.cer') -Type CERT | Out-Null
Set-Content -Path (Join-Path $release 'founderizer-test-signing.thumbprint') -Value $certificate.Thumbprint -Encoding ascii
"certificate $($certificate.Thumbprint): its public part exported"
