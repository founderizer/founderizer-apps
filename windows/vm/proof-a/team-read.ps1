# The read of the hub's team for proof A (team.sh runs it with vm.sh desktop): in the signed-in user's desktop session
# of the clean PC, where Windows opens the user's protected data. It reads the key of the owner's PC for the hub from the
# app's secret box (%LOCALAPPDATA%\Founderizer\keys, Windows' protection of the user's data with the box's own purpose,
# Founderizer.Core/SecretBox.cs and OwnerPcKey.cs) into memory only, asks the hub GET /ui/mobile for its generation,
# GET /ui/team for the team and GET /ui/servers for its servers, and writes to -Out the team's lines and machines, each
# server (whether it is the hub's, its agents, its SSH user and port), whether the hub's server takes agents, and the
# step of the fleet's servers, with no key, no address and no secret (team_compare.py says what stays outside).
# The hub knows this PC by its address and that key, as it knows the app.
#
#   & C:\fz\proof-a\team-read.ps1 -Out C:\fz\proof-a\team-read.json
param([string]$Out = 'C:\fz\proof-a\team-read.json')
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Security
$folder = Join-Path $env:LOCALAPPDATA 'Founderizer\keys\owner-keys'
$files = @(Get-ChildItem -Path $folder -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -notlike '*.pending' -and $_.Name -notlike '.*' })
if ($files.Count -ne 1) { throw "the secret box has $($files.Count) keys of a hub, not one: $folder" }
$file = $files[0]
# The box's name is owner-keys/<address>_<port>, the address with "-" for each letter that a name may not have (":").
if ($file.Name -notmatch '^(?<address>[0-9a-f.-]+)_(?<port>[0-9]{1,5})$') { throw "not the name of a hub's key: $($file.Name)" }
# Both groups are kept now: the next -match takes $Matches' place (the dry run of 22 November 2026 lost the port so).
$address = $Matches.address
$port = $Matches.port
$hub = if ($address -match '^[0-9.]+$') { "http://${address}:$port" } else { "http://[$($address -replace '-', ':')]:$port" }
$name = 'owner-keys/' + $file.Name
$purpose = [Text.Encoding]::UTF8.GetBytes('Founderizer for Windows: secret box')
$plain = [Security.Cryptography.ProtectedData]::Unprotect([IO.File]::ReadAllBytes($file.FullName), $purpose,
    [Security.Cryptography.DataProtectionScope]::CurrentUser)
try {
    $head = [Text.Encoding]::ASCII.GetBytes("founderizer-secret-box/1`n$name`n")
    for ($i = 0; $i -lt $head.Length; $i++) { if ($plain[$i] -ne $head[$i]) { throw "the kept value is not the value of $name" } }
    $key = [Text.Encoding]::UTF8.GetString($plain, $head.Length, $plain.Length - $head.Length)
} finally {
    [Array]::Clear($plain, 0, $plain.Length)
}
if ($key -notmatch '^[A-Za-z0-9_-]{32,128}$') { throw 'the kept value is not a key' }
$headers = @{ Authorization = "Bearer $key" }
try {
    $db = (Invoke-RestMethod -Uri "$hub/ui/mobile" -Headers $headers -TimeoutSec 30).db
    $team = Invoke-RestMethod -Uri ("$hub/ui/team?db=" + [Uri]::EscapeDataString($db)) -Headers $headers -TimeoutSec 30
    $fleet = Invoke-RestMethod -Uri ("$hub/ui/servers?db=" + [Uri]::EscapeDataString($db)) -Headers $headers -TimeoutSec 30
} catch {
    # The error's own words, never the request: the key is in its headers.
    throw "the hub did not answer the read: $($_.Exception.Message)"
} finally {
    $headers.Clear()
    Remove-Variable key, headers
}
# What team.json says, and nothing that the hub measures at the moment or holds as a secret.
$lines = foreach ($l in $team.lines) {
    [ordered]@{
        agent = $l.agent; role = $l.role; reports_to = $l.reports_to; machine = $l.machine; runtime = $l.runtime
        active = $l.active; model = $l.model; effort = $l.effort; can = @($l.can); title = $l.title
        expertise = @($l.expertise); vault = $l.vault; shared_with = @($l.placement.shared_with)
    }
}
$machines = [ordered]@{}
foreach ($m in $team.machines.PSObject.Properties) {
    $machines[$m.Name] = [ordered]@{
        agents = @($m.Value.agents)
        ssh = if ($m.Value.ssh) { [ordered]@{ user = $m.Value.ssh.user; port = $m.Value.ssh.port } } else { $null }
    }
}
$servers = [ordered]@{}
foreach ($s in @($fleet.servers)) {
    $ssh = $s.access.ssh
    $servers[$s.name] = [ordered]@{
        hub = ($s.hub -eq $true); agents = @($s.agents)
        ssh = if ($ssh) { [ordered]@{ user = $ssh.user; port = $ssh.port } } else { $null }
    }
}
$result = [ordered]@{
    read_at = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'); revision = $team.revision; sha256 = $team.sha256
    lines = @($lines); machines = $machines; servers = $servers; hub_shared = ($fleet.hub_shared -eq $true)
    shape = if ($fleet.shape) { $fleet.shape.step } else { $null }
}
[IO.File]::WriteAllText($Out, ($result | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding $false))
"read $(@($lines).Count) agents, $($machines.Count) machines with agents and $($servers.Count) servers at revision $($team.revision) into $Out"
