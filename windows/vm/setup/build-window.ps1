# Builds the empty window of app/windows/Founderizer.Windows in the build VM and signs it with a test key
# (README.md in the folder above).
#
#   build-window.ps1 -Source C:\fz\src\windows\Founderizer.Windows [-Out C:\fz\out] [-Proofs] [-Arch x64]
#
# With -Proofs it builds the proofs' build into <Out>\arm64-proofs (-p:FounderizerProofs=true: the sample fleet and
# the readings' variables, Proofs.cs), and no x64; without it, the release build into <Out>\arm64, which reads none.
# With -Arch x64 (an x64 PC: the build machines at Azure, ../cloud/cloud.sh build) it publishes the x64 build in place of
# the ARM64 one, into <Out>\x64 or <Out>\x64-proofs, and signs that one; step 2 is then the publish itself.
#
# Copy app/windows/Directory.Build.props, global.json and nuget.config beside the project folder first: they are
# the shared build settings of every Windows project (README.md in the folder above shows the commands).
#
# 1. Publishes the ARM64 build: Release, self-contained, not packaged (plan decision D3).
# 2. Compiles the x64 build, to prove that it compiles; this ARM64 VM does not run it.
# 3. Makes a code signing test key in the VM once (LocalMachine\My, RSA 3072), trusts its certificate in the
#    VM only, and signs Founderizer.App.exe and Founderizer.App.dll of the ARM64 build with it. The zip and the
#    setup of a release, with the launcher, are release/build-release.ps1's.
# A test key is not the release identity: plan decision D2 (Azure Artifact Signing) signs the releases.

param(
    [Parameter(Mandatory = $true)][string]$Source,
    [string]$Out = 'C:\fz\out',
    [switch]$Proofs,
    [ValidateSet('arm64', 'x64')][string]$Arch = 'arm64'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
$env:DOTNET_NOLOGO = '1'
$dotnet = "$env:ProgramFiles\dotnet\dotnet.exe"
$project = Join-Path $Source 'Founderizer.Windows.csproj'
$built = Join-Path $Out $(if ($Proofs) { "$Arch-proofs" } else { $Arch })
$platform = if ($Arch -eq 'x64') { 'x64' } else { 'ARM64' }
# Always an array: an if that gives one string would splat that string's letters, one by one.
$extra = @(if ($Proofs) { '-p:FounderizerProofs=true' })

function Step([string]$name) { Write-Output ("== {0} {1}" -f (Get-Date -Format o), $name) }

Step "publish $platform"
& $dotnet publish $project -c Release -r "win-$Arch" -p:Platform=$platform -o $built -nologo -clp:NoSummary @extra
if ($LASTEXITCODE -ne 0) { throw "the $platform publish failed: exit $LASTEXITCODE" }

if (-not $Proofs -and $Arch -eq 'arm64') {
Step 'build x64'
& $dotnet build $project -c Release -r win-x64 -p:Platform=x64 -nologo -clp:NoSummary
if ($LASTEXITCODE -ne 0) { throw "the x64 build failed: exit $LASTEXITCODE" }
$x64 = Get-ChildItem -Path (Join-Path $Source 'bin\x64\Release') -Recurse -Filter 'Founderizer.App.exe' | Select-Object -First 1
if (-not $x64) { throw 'no x64 Founderizer.App.exe' }
$machine = [BitConverter]::ToUInt16([IO.File]::ReadAllBytes($x64.FullName), [BitConverter]::ToInt32([IO.File]::ReadAllBytes($x64.FullName), 0x3C) + 4)
Write-Output ("x64 build: {0}, PE machine 0x{1:x4} (0x8664 is x64)" -f $x64.FullName, $machine)
}

Step 'test key'
$subject = 'CN=Founderizer Test Signing (build VM)'
$certificate = Get-ChildItem -Path Cert:\LocalMachine\My -CodeSigningCert | Where-Object Subject -eq $subject | Select-Object -First 1
if (-not $certificate) {
    $certificate = New-SelfSignedCertificate -Type CodeSigningCert -Subject $subject -CertStoreLocation Cert:\LocalMachine\My `
        -KeyAlgorithm RSA -KeyLength 3072 -HashAlgorithm SHA256 -KeyExportPolicy NonExportable -NotAfter (Get-Date).AddYears(2)
}
$public = Join-Path $Out 'founderizer-test-signing.cer'
Export-Certificate -Cert $certificate -FilePath $public | Out-Null
# Trusted in this VM only, so that Windows verifies the test signature. Import-Certificate adds the certificate
# to LocalMachine\Root over SSH and then fails with "Access is denied"; certutil does the same work cleanly.
foreach ($store in 'Root', 'TrustedPublisher') {
    & certutil.exe -f -addstore $store $public | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "certutil could not add the test certificate to $store" }
}
Write-Output "certificate $($certificate.Thumbprint), $subject, until $($certificate.NotAfter.ToString('yyyy-MM-dd'))"

Step 'sign'
foreach ($name in 'Founderizer.App.exe', 'Founderizer.App.dll') {
    $file = Join-Path $built $name
    $result = Set-AuthenticodeSignature -FilePath $file -Certificate $certificate -HashAlgorithm SHA256
    if ($result.Status -ne 'Valid') { throw "signing $name failed: $($result.Status) $($result.StatusMessage)" }
}
Get-AuthenticodeSignature -FilePath (Join-Path $built 'Founderizer.App.exe'), (Join-Path $built 'Founderizer.App.dll') |
    Format-Table -AutoSize @{ n = 'File'; e = { Split-Path $_.Path -Leaf } }, Status, @{ n = 'Signer'; e = { $_.SignerCertificate.Subject } } |
    Out-String | Write-Output

$files = Get-ChildItem -Path $built -Recurse -File
$exe = Join-Path $built 'Founderizer.App.exe'
$machine = [BitConverter]::ToUInt16([IO.File]::ReadAllBytes($exe), [BitConverter]::ToInt32([IO.File]::ReadAllBytes($exe), 0x3C) + 4)
Write-Output ("{0} build: {1}, {2} files, {3:F1} MB, PE machine 0x{4:x4}" -f $platform, $built, $files.Count, (($files | Measure-Object Length -Sum).Sum / 1MB), $machine)
