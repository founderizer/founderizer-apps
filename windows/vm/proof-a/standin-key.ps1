# For the dry run of team.sh with no hub (team_standin.py): a key of the owner's PC for the stand-in at 10.0.2.2:<port>,
# made in the desktop session and kept in the app's secret box as the app keeps one (Founderizer.Core/SecretBox.cs and
# OwnerPcKey.cs: owner-keys/<address>_<port>, the box's mark and the name before the value, Windows' protection of the
# user's data with the box's purpose). It prints only the key's SHA-256, which the stand-in takes, as a hub keeps it.
#
#   & C:\fz\proof-a\standin-key.ps1 -Port 58458            make it; prints "digest <sha256>"
#   & C:\fz\proof-a\standin-key.ps1 -Port 58458 -Remove    take it away again
param([Parameter(Mandatory = $true)][int]$Port, [switch]$Remove)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Security
$folder = Join-Path $env:LOCALAPPDATA 'Founderizer\keys\owner-keys'
$file = Join-Path $folder "10.0.2.2_$Port"
if ($Remove) {
    Remove-Item -Path $file -ErrorAction SilentlyContinue
    if (-not (Get-ChildItem -Path $folder -Force -ErrorAction SilentlyContinue)) { Remove-Item -Path $folder -ErrorAction SilentlyContinue }
    "removed the stand-in's key"
    return
}
if (Test-Path $file) { throw "a key for 10.0.2.2:$Port is in the box already" }
$random = New-Object byte[] 32
[Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($random)
$key = [Convert]::ToBase64String($random).Replace('+', '-').Replace('/', '_').TrimEnd('=')
[Array]::Clear($random, 0, $random.Length)
$head = [Text.Encoding]::ASCII.GetBytes("founderizer-secret-box/1`nowner-keys/10.0.2.2_$Port`n")
$value = [Text.Encoding]::UTF8.GetBytes($key)
$plain = New-Object byte[] ($head.Length + $value.Length)
[Array]::Copy($head, 0, $plain, 0, $head.Length)
[Array]::Copy($value, 0, $plain, $head.Length, $value.Length)
$purpose = [Text.Encoding]::UTF8.GetBytes('Founderizer for Windows: secret box')
$sealed = [Security.Cryptography.ProtectedData]::Protect($plain, $purpose, [Security.Cryptography.DataProtectionScope]::CurrentUser)
[Array]::Clear($plain, 0, $plain.Length)
New-Item -ItemType Directory -Force -Path $folder | Out-Null
[IO.File]::WriteAllBytes($file, $sealed)
$sha = [Security.Cryptography.SHA256]::Create()
$digest = -join ($sha.ComputeHash($value) | ForEach-Object { $_.ToString('x2') })
[Array]::Clear($value, 0, $value.Length)
Remove-Variable key
"digest $digest"
