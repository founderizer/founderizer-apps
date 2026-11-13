# Installs the newest .NET 10 SDK for Windows on ARM64 in the build VM (README.md in the folder above).
#
# It reads Microsoft's release list of the 10.0 channel, downloads the SDK installer from Microsoft, checks the
# installer's SHA-512 against the list, and installs it for the whole machine with no question. Run it over SSH:
#
#   vm.sh copy app/windows/vm/setup/install-dotnet.ps1 vm:C:/fz/install-dotnet.ps1
#   vm.sh run 'powershell -NoProfile -ExecutionPolicy Bypass -File C:\fz\install-dotnet.ps1'

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$folder = 'C:\fz\downloads'
New-Item -ItemType Directory -Force -Path $folder | Out-Null

$channel = Invoke-RestMethod -Uri 'https://builds.dotnet.microsoft.com/dotnet/release-metadata/10.0/releases.json'
$version = $channel.'latest-sdk'
$release = $channel.releases | Where-Object { $_.sdks.version -contains $version } | Select-Object -First 1
$sdk = $release.sdks | Where-Object { $_.version -eq $version } | Select-Object -First 1
$file = $sdk.files | Where-Object { $_.rid -eq 'win-arm64' -and $_.name -like '*.exe' } | Select-Object -First 1
if (-not $file) { throw "no win-arm64 installer for SDK $version" }
Write-Output "SDK $version (runtime $($release.'release-version'), released $($release.'release-date'))"
Write-Output "from $($file.url)"

$installer = Join-Path $folder ([IO.Path]::GetFileName($file.url))
if (-not (Test-Path $installer) -or (Get-FileHash -Algorithm SHA512 $installer).Hash -ne $file.hash.ToUpperInvariant()) {
    & curl.exe --fail --location --silent --show-error --retry 3 --output $installer $file.url
    if ($LASTEXITCODE -ne 0) { throw "download failed: curl exit $LASTEXITCODE" }
}
$hash = (Get-FileHash -Algorithm SHA512 $installer).Hash
if ($hash -ne $file.hash.ToUpperInvariant()) { throw "SHA-512 differs: $hash" }
Write-Output ("{0}: {1} bytes, SHA-512 equal to the release list: {2}" -f [IO.Path]::GetFileName($installer), (Get-Item $installer).Length, $hash)

$process = Start-Process -FilePath $installer -ArgumentList '/install', '/quiet', '/norestart' -Wait -PassThru
Write-Output "installer exit $($process.ExitCode)"
if ($process.ExitCode -notin 0, 3010) { throw "the installer failed" }
& "$env:ProgramFiles\dotnet\dotnet.exe" --version
