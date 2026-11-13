# Builds one release of Founderizer for Windows on the Windows computer (~/dev/founderizer-plans/
# windows-app-release-design.md, sections 4 and 5; README.md in this folder): for each kind of PC, the zip of the
# build and its setup file, with the version and the build number in the build's build.json, and every .exe and
# .dll signed. Self-contained with JIT, not Native AOT (that needs Visual Studio's C++ build tools).
#
#   build-release.ps1 -Source C:\fz\src\windows -Version 0.2.3 -Build 23 [-Arch arm64,x64] [-Out C:\fz\release]
#                     [-Thumbprint <certificate>] [-Proofs] [-Reuse]
#
# -Source      the folder app/windows of the repository: Founderizer.Windows, Founderizer.Install,
#              Founderizer.Launcher, Founderizer.Core, Directory.Build.props, global.json and nuget.config.
# -Thumbprint  the code signing certificate, in Cert:\CurrentUser\My or Cert:\LocalMachine\My. Without it, the build
#              VM's test certificate (vm/setup/build-window.ps1 makes it). Azure Artifact Signing (plan decision D2)
#              takes this step's place, with a timestamp.
# -Proofs      the proofs' build (-p:FounderizerProofs=true, Founderizer.Windows/Proofs.cs); never a release.
# -Reuse       takes the app and the launcher from the last publish in <Out>\stage-<arch> instead of publishing
#              again: only build.json, the signatures, the zip and the setup are new. The proofs make builds N+1 and
#              N+2 of the same code with it.
#
# It writes <Out>\<version>-<build>\:
#   Founderizer-<version>-<arch>.zip          the build: Founderizer.App.exe and its files, Founderizer.exe (the
#                                             launcher), build.json
#   Founderizer-Setup-<version>-<arch>.exe    the setup: the launcher with that zip inside
#   builds.json                               each file's name, size and SHA-256, for the Mac's release job

param(
    [Parameter(Mandatory = $true)][string]$Source,
    [Parameter(Mandatory = $true)][string]$Version,
    [Parameter(Mandatory = $true)][long]$Build,
    [string[]]$Arch = @('arm64', 'x64'),
    [string]$Out = 'C:\fz\release',
    [string]$Thumbprint = '',
    [switch]$Proofs,
    [switch]$Reuse
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
$env:DOTNET_NOLOGO = '1'
$dotnet = "$env:ProgramFiles\dotnet\dotnet.exe"
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem

function Step([string]$name) { Write-Output ("== {0} {1}" -f (Get-Date -Format o), $name) }

if ($Version -notmatch '^[A-Za-z0-9][A-Za-z0-9._+-]{0,40}$') { throw "the version $Version is not a version name" }
if ($Build -lt 1 -or $Build -gt 2000000000) { throw "the build number $Build is not between 1 and 2000000000" }
# powershell -File gives a list as one word: "arm64,x64".
$Arch = @($Arch | ForEach-Object { $_ -split ',' } | Where-Object { $_ })
foreach ($a in $Arch) { if ($a -notin 'arm64', 'x64') { throw "the kind of PC $a is not arm64 or x64" } }

if ($Thumbprint) {
    $certificate = Get-ChildItem -Path Cert:\CurrentUser\My, Cert:\LocalMachine\My -CodeSigningCert |
        Where-Object Thumbprint -eq $Thumbprint | Select-Object -First 1
} else {
    $certificate = Get-ChildItem -Path Cert:\LocalMachine\My -CodeSigningCert |
        Where-Object Subject -eq 'CN=Founderizer Test Signing (build VM)' | Select-Object -First 1
}
if (-not $certificate) { throw 'no code signing certificate: give -Thumbprint, or run vm/setup/build-window.ps1 once' }
Write-Output "signs with $($certificate.Subject) ($($certificate.Thumbprint))"

$app = Join-Path $Source 'Founderizer.Windows\Founderizer.Windows.csproj'
$launcher = Join-Path $Source 'Founderizer.Launcher\Founderizer.Launcher.csproj'
$extra = @(if ($Proofs) { '-p:FounderizerProofs=true' })
$release = Join-Path $Out "$Version-$Build"
New-Item -ItemType Directory -Force -Path $release | Out-Null

function Sign([string[]]$files) {
    foreach ($file in $files) {
        $result = Set-AuthenticodeSignature -FilePath $file -Certificate $certificate -HashAlgorithm SHA256
        if ($result.Status -ne 'Valid') { throw "signing $file failed: $($result.Status) $($result.StatusMessage)" }
    }
}

$listed = @()
foreach ($a in $Arch) {
    $platform = if ($a -eq 'arm64') { 'ARM64' } else { 'x64' }
    $stage = Join-Path $Out "stage-$a"
    $published = Join-Path $stage 'app'
    $launched = Join-Path $stage 'launcher'
    if (-not $Reuse -or -not (Test-Path (Join-Path $published 'Founderizer.App.exe'))) {
        Step "publish the app for $a"
        if (Test-Path $stage) { Remove-Item -Recurse -Force $stage }
        & $dotnet publish $app -c Release -r "win-$a" "-p:Platform=$platform" -o $published -nologo -clp:NoSummary @extra
        if ($LASTEXITCODE -ne 0) { throw "the app's publish for $a failed: exit $LASTEXITCODE" }
        Step "publish the launcher for $a"
        & $dotnet publish $launcher -c Release -r "win-$a" -o $launched -nologo -clp:NoSummary
        if ($LASTEXITCODE -ne 0) { throw "the launcher's publish for $a failed: exit $LASTEXITCODE" }
    }
    $one = Join-Path $launched 'Founderizer.exe'
    if ((Get-Item $one).Length -gt 40MB) { throw "the launcher for $a is $((Get-Item $one).Length) bytes: does it carry a build?" }

    Step "the build $Version ($Build) for $a"
    $files = Join-Path $stage 'build'
    if (Test-Path $files) { Remove-Item -Recurse -Force $files }
    Copy-Item -Recurse -Path $published -Destination $files
    Get-ChildItem -Path $files -Recurse -Filter '*.pdb' | Remove-Item -Force
    Copy-Item -Path $one -Destination (Join-Path $files 'Founderizer.exe')
    $json = '{"version":"' + $Version + '","build":' + $Build + ',"arch":"' + $a + '"}' + "`n"
    [IO.File]::WriteAllText((Join-Path $files 'build.json'), $json, (New-Object Text.UTF8Encoding $false))

    $signed = Get-ChildItem -Path $files -Recurse -File | Where-Object { $_.Extension -in '.exe', '.dll' }
    Step "sign $($signed.Count) .exe and .dll files for $a"
    Sign ($signed | ForEach-Object FullName)

    $zip = Join-Path $release "Founderizer-$Version-$a.zip"
    if (Test-Path $zip) { Remove-Item -Force $zip }
    Step "zip for $a"
    $archive = [IO.Compression.ZipFile]::Open($zip, [IO.Compression.ZipArchiveMode]::Create)
    try {
        $top = (Resolve-Path $files).Path.TrimEnd('\') + '\'
        foreach ($file in (Get-ChildItem -Path $files -Recurse -File | Sort-Object FullName)) {
            $name = $file.FullName.Substring($top.Length).Replace('\', '/')
            [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $file.FullName, $name, [IO.Compression.CompressionLevel]::Optimal) | Out-Null
        }
    } finally {
        $archive.Dispose()
    }

    Step "the setup for $a"
    $setupStage = Join-Path $stage 'setup'
    if (Test-Path $setupStage) { Remove-Item -Recurse -Force $setupStage }
    # Its own intermediate folders: the launcher without a build is never built from the setup's objects.
    & $dotnet publish $launcher -c Release -r "win-$a" "-p:BuildZip=$zip" "-p:IntermediateOutputPath=obj\setup\$a\" `
        "-p:OutputPath=bin\setup\$a\" -o $setupStage -nologo -clp:NoSummary
    if ($LASTEXITCODE -ne 0) { throw "the setup's publish for $a failed: exit $LASTEXITCODE" }
    $setup = Join-Path $release "Founderizer-Setup-$Version-$a.exe"
    Copy-Item -Force -Path (Join-Path $setupStage 'Founderizer.exe') -Destination $setup
    if ((Get-Item $setup).Length -le (Get-Item $zip).Length) { throw "the setup for $a does not carry its build" }
    Sign @($setup)

    foreach ($file in $zip, $setup) {
        $item = Get-Item $file
        $listed += [ordered]@{ name = $item.Name; arch = $a; size = $item.Length; sha256 = (Get-FileHash -Algorithm SHA256 $file).Hash.ToLowerInvariant() }
    }
    Write-Output ("{0}: {1} files in the build, zip {2:F1} MB, setup {3:F1} MB" -f $a, (Get-ChildItem -Path $files -Recurse -File).Count,
        ((Get-Item $zip).Length / 1MB), ((Get-Item $setup).Length / 1MB))
}

$builds = [ordered]@{ version = $Version; build = $Build; proofs = [bool]$Proofs; files = $listed }
[IO.File]::WriteAllText((Join-Path $release 'builds.json'), ($builds | ConvertTo-Json -Depth 4), (New-Object Text.UTF8Encoding $false))
Step "done: $release"
