# The build of vps-check.sh, in the build VM's SSH session: the proofs' build with the welcome page (-p:FounderizerProofs
# and -p:FounderizerWelcome both true), ARM64, from C:\fz\proof-a\vps\src\windows, into C:\fz\proof-a\vps\out, and
# a zip of it. It prints the version of Renci.SshNet.dll in the output (SSH.NET, which "Other VPS" connects with). The
# caller may set $want to the version that must be there.
$ErrorActionPreference = 'Stop'
$found = foreach ($scope in 'Machine', 'User', 'Process') {
    [Environment]::GetEnvironmentVariables($scope).Keys | Where-Object { $_ -like 'Founderizer*' } | ForEach-Object { "$scope $_" }
}
if ($found) { throw ('the build VM has variables that change the build: ' + ($found -join ', ')) }
$env:MSBUILDDISABLENODEREUSE = '1'
$env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
$env:DOTNET_NOLOGO = '1'
$dotnet = "$env:ProgramFiles\dotnet\dotnet.exe"
& $dotnet build-server shutdown | Out-Null
$out = 'C:\fz\proof-a\vps\out'
if (Test-Path $out) { Remove-Item -Recurse -Force $out }
& $dotnet publish 'C:\fz\proof-a\vps\src\windows\Founderizer.Windows\Founderizer.Windows.csproj' -c Release -r win-arm64 `
    -p:Platform=ARM64 -p:FounderizerProofs=true -p:FounderizerWelcome=true -o $out -nologo -clp:NoSummary | Select-Object -Last 3
if ($LASTEXITCODE -ne 0) { throw "the publish failed: exit $LASTEXITCODE" }
$ssh = Get-Item (Join-Path $out 'Renci.SshNet.dll')
$version = $ssh.VersionInfo.ProductVersion
"Renci.SshNet.dll: product version $version, file version $($ssh.VersionInfo.FileVersion)"
if ($want -and -not $version.StartsWith($want)) { throw "the output has SSH.NET $version, not $want" }
$zip = 'C:\fz\proof-a\vps\app.zip'
if (Test-Path $zip) { Remove-Item -Force $zip }
Add-Type -AssemblyName System.IO.Compression.FileSystem
[IO.Compression.ZipFile]::CreateFromDirectory($out, $zip)
"zip: $((Get-Item $zip).Length) bytes"
