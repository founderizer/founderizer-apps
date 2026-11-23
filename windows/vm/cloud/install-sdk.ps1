# Installs one exact .NET SDK for Windows x64 on a build machine at Azure (cloud.sh make): the SDK of the release
# builds (cloud.sh's pin, which must equal ../../release/global.json when that file exists). It reads Microsoft's release
# list of the SDK's channel, downloads the installer from Microsoft, checks its SHA-512 against the list, installs it for
# the whole machine with no question, and checks that dotnet lists that SDK. An SDK that is there already is kept.
param([Parameter(Mandatory = $true)][string]$Version)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
if ($Version -notmatch '^[0-9]+\.[0-9]+\.[0-9]+$') { throw "not an SDK version: $Version" }
$dotnet = "$env:ProgramFiles\dotnet\dotnet.exe"
function Listed { (Test-Path $dotnet) -and ((& $dotnet --list-sdks) -match ('^' + [regex]::Escape($Version) + ' ')) }
if (Listed) { "SDK $Version is installed already"; & $dotnet --list-sdks; return }

$channel = ($Version -split '\.')[0..1] -join '.'
$list = Invoke-RestMethod -Uri "https://builds.dotnet.microsoft.com/dotnet/release-metadata/$channel/releases.json"
$release = $list.releases | Where-Object { $_.sdks.version -contains $Version } | Select-Object -First 1
if (-not $release) { throw "no SDK $Version in Microsoft's release list of the $channel channel" }
$sdk = $release.sdks | Where-Object { $_.version -eq $Version } | Select-Object -First 1
$file = $sdk.files | Where-Object { $_.rid -eq 'win-x64' -and $_.name -like '*.exe' } | Select-Object -First 1
if (-not $file) { throw "no win-x64 installer for SDK $Version" }
"SDK $Version (runtime $($sdk.'runtime-version'), released $($release.'release-date')) from $($file.url)"

$folder = 'C:\fz\downloads'
New-Item -ItemType Directory -Force -Path $folder | Out-Null
$installer = Join-Path $folder ([IO.Path]::GetFileName($file.url))
& curl.exe --fail --location --silent --show-error --retry 3 --output $installer $file.url
if ($LASTEXITCODE -ne 0) { throw "the download failed: curl exit $LASTEXITCODE" }
$hash = (Get-FileHash -Algorithm SHA512 $installer).Hash
if ($hash -ne $file.hash.ToUpperInvariant()) { throw "the installer's SHA-512 differs from the release list: $hash" }
"{0}: {1} bytes, SHA-512 equal to the release list" -f [IO.Path]::GetFileName($installer), (Get-Item $installer).Length
$process = Start-Process -FilePath $installer -ArgumentList '/install', '/quiet', '/norestart' -Wait -PassThru
"installer exit $($process.ExitCode)"
if ($process.ExitCode -notin 0, 3010) { throw 'the installer failed' }
Remove-Item -Path $installer
if (-not (Listed)) { throw "dotnet does not list SDK $Version after the install" }
& $dotnet --list-sdks
