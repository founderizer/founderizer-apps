# Builds one release of Founderizer for Windows on the Windows computer (~/dev/founderizer-plans/
# windows-app-release-design.md, sections 4 and 5; README.md in this folder): for each kind of PC, the zip of the
# build and its setup file, with the version and the build number in the build's build.json, and every .exe and
# .dll signed. Self-contained with JIT, not Native AOT (that needs Visual Studio's C++ build tools).
#
#   build-release.ps1 -Source C:\fz\src\windows -Version 0.2.3 -Build 23 [-Arch arm64,x64] [-Out C:\fz\release]
#                     [-Thumbprint <certificate>] [-Proofs] [-Reuse] [-Tester]
#
# -Source      the folder app/windows of the repository: Founderizer.Windows, Founderizer.Install,
#              Founderizer.Launcher, Founderizer.Core, Founderizer.Owner, Founderizer.Remote, Founderizer.Setup,
#              Directory.Build.props, nuget.config and release\global.json.
# -Thumbprint  the code signing certificate, in Cert:\CurrentUser\My or Cert:\LocalMachine\My. Without it, the build
#              VM's test certificate (vm/setup/build-window.ps1 makes it). Azure Artifact Signing (plan decision D2)
#              takes this step's place, with a timestamp.
# -Proofs      the proofs' build (-p:FounderizerProofs=true, Founderizer.Windows/Proofs.cs); never a release.
# -Reuse       takes the app and the launcher from the last publish in <Out>\stage-<arch> instead of publishing
#              again: only build.json, the signatures, the zip and the setup are new. The proofs make builds N+1 and
#              N+2 of the same code with it.
# -Tester      a tester build (windows-app-plan-v2.md, section 4, rule 20, and piece T1): -p:FounderizerTester=true in
#              each of its three publishes, no signature on any file, "tester": true in build.json, its own stage
#              folders (stage-tester-<arch>). Every other build says -p:FounderizerTester=false. Not with -Thumbprint.
#
# One exact SDK makes each release: the one of release\global.json, with no roll forward. Every dotnet command runs in
# that folder, so the SDK of another global.json never builds a release (this Mac's tests run another SDK). It stops
# when that SDK's .NET runtime, which each build carries, is not the one of Directory.Build.props
# (FounderizerReleaseRuntime, which the lock files name) or is before 10.0.14 (GHSA-p3jp-9v83-76w9). Before any publish
# it restores the app and the launcher, with all of their projects, in locked mode (dotnet restore --locked-mode --force),
# and no publish restores again (--no-restore): a lock file that does not match its project, or a package whose hash is
# not the one of its lock file, stops the build, also in a folder that an earlier build restored.
#
# It writes <Out>\<version>-<build>\ (<Out>\<version>-<build>-tester\ for a tester build):
#   Founderizer-<version>-<arch>.zip          the build: Founderizer.App.exe and its files, Founderizer.exe (the
#                                             launcher), build.json
#   Founderizer-Setup-<version>-<arch>.exe    the setup: the launcher with that zip inside
#   builds.json                               each file's name, size and SHA-256, for the Mac's release job, and the
#                                             kind, the welcome page and the proofs as the built files say them
#
# The kind is checked by the built bytes (test 2 of T1): read-constants.cs reads the constants that the compiler put into
# Founderizer.App.dll (BuildKind.Tester, FirstRunSwitch.Welcome, Proofs.On), and the build stops when one is not what
# its command line asked. No file of a signed build holds the tester manifest's first line or the tester key, in UTF-8
# or UTF-16, and its launcher holds no BouncyCastle; a tester build's Founderizer.Core.dll holds both, its key is the
# line of tester-key.pub, and none of our own files has a signature. No build starts while a variable whose name starts
# with Founderizer, or one named DefineConstants, is in the machine's, the user's or this process's environment: MSBuild
# takes its properties from there (the names are compared with no case, so the proofs' FOUNDERIZER_UPDATE_* count).

param(
    [Parameter(Mandatory = $true)][string]$Source,
    [Parameter(Mandatory = $true)][string]$Version,
    [Parameter(Mandatory = $true)][long]$Build,
    [string[]]$Arch = @('arm64', 'x64'),
    [string]$Out = 'C:\fz\release',
    [string]$Thumbprint = '',
    [switch]$Proofs,
    [switch]$Reuse,
    [switch]$Tester
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

if ($Tester -and $Thumbprint) { throw 'a tester build signs nothing: -Tester and -Thumbprint do not go together' }
$found = foreach ($scope in 'Machine', 'User', 'Process') {
    [Environment]::GetEnvironmentVariables($scope).Keys | Where-Object { $_ -like 'Founderizer*' -or $_ -eq 'DefineConstants' } |
        ForEach-Object { "$_ ($scope)" }
}
if ($found) { throw ('variables that change a build are set: ' + ($found -join ', ') + '. Remove them, then build again.') }
# A reused MSBuild node keeps the environment of the build that started it.
$env:MSBUILDDISABLENODEREUSE = '1'
& $dotnet build-server shutdown | Out-Null

if ($Tester) {
    $certificate = $null
    Write-Output 'a tester build: no file is signed'
} else {
    if ($Thumbprint) {
        $certificate = Get-ChildItem -Path Cert:\CurrentUser\My, Cert:\LocalMachine\My -CodeSigningCert |
            Where-Object Thumbprint -eq $Thumbprint | Select-Object -First 1
    } else {
        $certificate = Get-ChildItem -Path Cert:\LocalMachine\My -CodeSigningCert |
            Where-Object Subject -eq 'CN=Founderizer Test Signing (build VM)' | Select-Object -First 1
    }
    if (-not $certificate) { throw 'no code signing certificate: give -Thumbprint, or run vm/setup/build-window.ps1 once' }
    Write-Output "signs with $($certificate.Subject) ($($certificate.Thumbprint))"
}

$app = Join-Path $Source 'Founderizer.Windows\Founderizer.Windows.csproj'
$launcher = Join-Path $Source 'Founderizer.Launcher\Founderizer.Launcher.csproj'

# The release SDK (see the top): its folder is the working folder of every dotnet command below.
$sdkFolder = Join-Path $Source 'release'
$pinned = (Get-Content -Raw (Join-Path $sdkFolder 'global.json') | ConvertFrom-Json).sdk
if ($pinned.version -notmatch '^\d+\.\d+\.\d+$' -or $pinned.rollForward -ne 'disable') {
    throw 'release\global.json does not name one exact SDK with "rollForward": "disable"'
}
Set-Location $sdkFolder
$sdk = & $dotnet --version
if ($LASTEXITCODE -ne 0 -or "$sdk".Trim() -ne $pinned.version) {
    throw "the release SDK $($pinned.version) of release\global.json is not installed on this computer (vm/setup/install-dotnet.ps1 -Version $($pinned.version))"
}
$runtime = "$(& $dotnet msbuild $launcher -nologo -getProperty:BundledNETCoreAppPackageVersion)".Trim()
$wanted = "$(& $dotnet msbuild $launcher -nologo -getProperty:FounderizerReleaseRuntime)".Trim()
if ($runtime -notmatch '^\d+\.\d+\.\d+$' -or [version]$runtime -lt [version]'10.0.14') {
    throw "SDK $sdk carries the .NET runtime $runtime, before 10.0.14 (GHSA-p3jp-9v83-76w9)"
}
if ($runtime -ne $wanted) {
    throw "SDK $sdk carries the .NET runtime $runtime, and Directory.Build.props (FounderizerReleaseRuntime) names $wanted"
}
Write-Output "SDK $sdk, .NET runtime $runtime"
# One restore, in locked mode, at the runtimes that each project declares (the app's, the launcher's and Install's
# win-arm64 and win-x64), before the publishes. A publish's own restore is not it: its -r gives its one runtime to every
# project of the graph, the libraries among them, whose lock files name no runtime. --force: NuGet reads each lock file
# again also in a folder that an earlier build restored (no "no-op" restore).
Step 'restore in locked mode'
foreach ($project in $app, $launcher) {
    & $dotnet restore $project --locked-mode --force -nologo
    if ($LASTEXITCODE -ne 0) {
        throw "the locked restore of $(Split-Path $project -Leaf) failed: a lock file does not match its project, or a package does not match its lock file"
    }
}
$restore = '--no-restore'
# No release has the first run's welcome page before pieces U3, U4 and U5 of step 2 (windows-app-plan-v2.md, section
# 13): every build of a release says so on the command line (Founderizer.Windows/Fleet/FirstRunSwitch.cs). Nor the
# proofs' parts (the stand-ins of the providers and of the manager's setup): a build without -Proofs says that too.
$extra = @('-p:FounderizerWelcome=false') + @(if ($Proofs) { '-p:FounderizerProofs=true' } else { '-p:FounderizerProofs=false' })
# The kind, in all three publishes (the app's, the launcher's and the setup's).
$kind = if ($Tester) { '-p:FounderizerTester=true' } else { '-p:FounderizerTester=false' }
$welcome = [bool]($extra | Where-Object { $_ -match '^-p:FounderizerWelcome=true$' })
$prefix = 'founderizer-windows-tester-1'
$keyLine = (Get-Content -Raw (Join-Path $sdkFolder 'tester-key.pub')).Trim()
if ($keyLine -notmatch '^[A-Za-z0-9+/]{43}=$') { throw 'release\tester-key.pub does not hold one Ed25519 key line' }
$reader = Join-Path $sdkFolder 'read-constants.cs'
$latin = [Text.Encoding]::GetEncoding(28591)

# The texts of $texts that the file holds, in UTF-8 or in UTF-16 (a .NET string), at any byte.
function Holds([string]$file, [string[]]$texts) {
    $bytes = $latin.GetString([IO.File]::ReadAllBytes($file))
    foreach ($text in $texts) {
        foreach ($form in [Text.Encoding]::UTF8, [Text.Encoding]::Unicode) {
            if ($bytes.IndexOf($latin.GetString($form.GetBytes($text)), [StringComparison]::Ordinal) -ge 0) { $text; break }
        }
    }
}

# The constants that the compiler put into a built file, by read-constants.cs (name -> value).
function Constants([string]$file, [string[]]$names) {
    # Its own scope: a line on standard error is part of what it said, not an error that stops the script.
    $ErrorActionPreference = 'Continue'
    $said = & $dotnet run --file $reader -- $file @names 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { throw "read-constants.cs could not read $file`: $said" }
    $values = @{}
    foreach ($line in ($said -split "`r?`n")) { if ($line -match '^([A-Za-z0-9_.]+)=(.*)$') { $values[$Matches[1]] = $Matches[2] } }
    foreach ($name in $names) { if (-not $values.ContainsKey($name)) { throw "read-constants.cs gave no $name for $file`: $said" } }
    $values
}
$release = Join-Path $Out ("$Version-$Build" + $(if ($Tester) { '-tester' } else { '' }))
New-Item -ItemType Directory -Force -Path $release | Out-Null

function Sign([string[]]$files) {
    foreach ($file in $files) {
        $result = Set-AuthenticodeSignature -FilePath $file -Certificate $certificate -HashAlgorithm SHA256
        if ($result.Status -ne 'Valid') { throw "signing $file failed: $($result.Status) $($result.StatusMessage)" }
    }
}

$listed = @()
$kinds = @()
foreach ($a in $Arch) {
    $platform = if ($a -eq 'arm64') { 'ARM64' } else { 'x64' }
    $stage = Join-Path $Out $(if ($Tester) { "stage-tester-$a" } else { "stage-$a" })
    $published = Join-Path $stage 'app'
    $launched = Join-Path $stage 'launcher'
    if (-not $Reuse -or -not (Test-Path (Join-Path $published 'Founderizer.App.exe'))) {
        Step "publish the app for $a"
        if (Test-Path $stage) { Remove-Item -Recurse -Force $stage }
        & $dotnet publish $app -c Release -r "win-$a" "-p:Platform=$platform" -o $published -nologo -clp:NoSummary $restore $kind @extra
        if ($LASTEXITCODE -ne 0) { throw "the app's publish for $a failed: exit $LASTEXITCODE" }
        Step "publish the launcher for $a"
        & $dotnet publish $launcher -c Release -r "win-$a" -o $launched -nologo -clp:NoSummary $restore $kind
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
    $json = '{"version":"' + $Version + '","build":' + $Build + ',"arch":"' + $a + '"' + $(if ($Tester) { ',"tester":true' } else { '' }) + '}' + "`n"
    [IO.File]::WriteAllText((Join-Path $files 'build.json'), $json, (New-Object Text.UTF8Encoding $false))

    Step "the kind of the build for $a, by its bytes"
    $built = Constants (Join-Path $files 'Founderizer.App.dll') @('Founderizer.Windows.BuildKind.Tester',
        'Founderizer.Windows.Fleet.FirstRunSwitch.Welcome', 'Founderizer.Windows.Proofs.On')
    $saysTester = $built['Founderizer.Windows.BuildKind.Tester'] -eq 'true'
    $saysWelcome = $built['Founderizer.Windows.Fleet.FirstRunSwitch.Welcome'] -eq 'true'
    $saysProofs = $built['Founderizer.Windows.Proofs.On'] -eq 'true'
    Write-Output "Founderizer.App.dll for ${a}: Tester $saysTester, Welcome $saysWelcome, Proofs $saysProofs"
    if ($saysTester -ne [bool]$Tester) {
        throw "Founderizer.App.dll for $a is $(if ($saysTester) { 'a tester' } else { 'a signed' }) build, and its build.json says $(if ($Tester) { 'tester' } else { 'signed' })"
    }
    if ($saysWelcome -ne $welcome) { throw "Founderizer.App.dll for $a says Welcome $saysWelcome, and its command line $welcome" }
    if ($saysProofs -ne [bool]$Proofs) { throw "Founderizer.App.dll for $a says Proofs $saysProofs, and its command line $([bool]$Proofs)" }
    $ours = @(Get-ChildItem -Path $files -Recurse -File | Where-Object { $_.Name -like 'Founderizer*' -and $_.Extension -in '.exe', '.dll' })
    if ($Tester) {
        $core = Join-Path $files 'Founderizer.Core.dll'
        $held = @(Holds $core @($prefix, $keyLine))
        if ($held.Count -ne 2) { throw "Founderizer.Core.dll of the tester build for $a does not hold the tester manifest's first line and key" }
        $tested = Constants $core @('Founderizer.Core.TesterManifest.SignedPrefix', 'Founderizer.Core.TesterManifest.KeyLine')
        if ($tested['Founderizer.Core.TesterManifest.SignedPrefix'] -cne $prefix -or $tested['Founderizer.Core.TesterManifest.KeyLine'] -cne $keyLine) {
            throw "Founderizer.Core.dll of the tester build for $a has another first line or key than tester-key.pub"
        }
        $withSignature = @($ours | Where-Object { (Get-AuthenticodeSignature -FilePath $_.FullName).Status -ne 'NotSigned' })
        if ($withSignature) { throw "a tester build signs none of its files, and these have a signature: $($withSignature.Name -join ', ')" }
        Write-Output "tester build for ${a}: Founderizer.Core.dll holds the first line and the key of tester-key.pub; $($ours.Count) of our files, none signed"
    } else {
        $all = @(Get-ChildItem -Path $files -Recurse -File)
        foreach ($file in $all) {
            $held = @(Holds $file.FullName @($prefix, $keyLine))
            if ($held) { throw "$($file.Name) of the signed build for $a holds $($held -join ' and ')" }
        }
        if (@(Holds $one @('Org.BouncyCastle')).Count) { throw "the launcher of the signed build for $a holds BouncyCastle" }
        Write-Output "signed build for ${a}: none of its $($all.Count) files holds the tester's first line or key; its launcher holds no BouncyCastle"
    }
    $kinds += [ordered]@{ tester = $saysTester; welcome = $saysWelcome; proofs = $saysProofs }

    if ($Tester) {
        Step "no signature for the tester build for $a"
    } else {
        $signed = Get-ChildItem -Path $files -Recurse -File | Where-Object { $_.Extension -in '.exe', '.dll' }
        Step "sign $($signed.Count) .exe and .dll files for $a"
        Sign ($signed | ForEach-Object FullName)
    }

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
    $setupFolder = if ($Tester) { 'setup-tester' } else { 'setup' }
    & $dotnet publish $launcher -c Release -r "win-$a" "-p:BuildZip=$zip" "-p:IntermediateOutputPath=obj\$setupFolder\$a\" `
        "-p:OutputPath=bin\$setupFolder\$a\" -o $setupStage -nologo -clp:NoSummary $restore $kind
    if ($LASTEXITCODE -ne 0) { throw "the setup's publish for $a failed: exit $LASTEXITCODE" }
    $setup = Join-Path $release "Founderizer-Setup-$Version-$a.exe"
    Copy-Item -Force -Path (Join-Path $setupStage 'Founderizer.exe') -Destination $setup
    if ((Get-Item $setup).Length -le (Get-Item $zip).Length) { throw "the setup for $a does not carry its build" }
    if ($Tester) {
        if ((Get-AuthenticodeSignature -FilePath $setup).Status -ne 'NotSigned') { throw "the tester setup for $a has a signature" }
    } else {
        $held = @(Holds $setup @($prefix, $keyLine))
        if ($held) { throw "the signed setup for $a holds $($held -join ' and ')" }
        Sign @($setup)
    }

    foreach ($file in $zip, $setup) {
        $item = Get-Item $file
        $listed += [ordered]@{ name = $item.Name; arch = $a; size = $item.Length; sha256 = (Get-FileHash -Algorithm SHA256 $file).Hash.ToLowerInvariant() }
    }
    Write-Output ("{0}: {1} files in the build, zip {2:F1} MB, setup {3:F1} MB" -f $a, (Get-ChildItem -Path $files -Recurse -File).Count,
        ((Get-Item $zip).Length / 1MB), ((Get-Item $setup).Length / 1MB))
}

# The kind, the welcome page and the proofs as the built files say them (each arch's equal the command line's).
$builds = [ordered]@{ version = $Version; build = $Build; tester = $kinds[0].tester; welcome = $kinds[0].welcome
                      proofs = $kinds[0].proofs; files = $listed }
[IO.File]::WriteAllText((Join-Path $release 'builds.json'), ($builds | ConvertTo-Json -Depth 4), (New-Object Text.UTF8Encoding $false))
Step "done: $release"
