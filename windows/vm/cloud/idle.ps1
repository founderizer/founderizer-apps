# The idle rule of a Windows build machine at Azure (setup.ps1 installs it; a task of SYSTEM every 10 minutes and at each
# start). The machine is in use while an SSH connection is open (every cloud.sh verb but make, start, stop, status and
# list is one) or a build or a test runs (dotnet, MSBuild, testhost, VBCSCompiler). After 2 hours with neither, counted
# from the last use or the last start, the machine deallocates itself through Azure's API, with its own identity: the
# token comes from Azure's metadata service for this one call and is written nowhere, and the identity's one role
# (DevTest Labs User at the scope of this VM, machine.json) reads, starts, restarts and deallocates this VM only. A hold
# (cloud.sh hold) does not count: a held machine that nobody uses deallocates too, and keeps its hold. Each deallocation is
# a line of idle.log beside this script.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$folder = 'C:\ProgramData\fz-cloud'
$mark = Join-Path $folder 'last-use'
$log = Join-Path $folder 'idle.log'
$limit = [TimeSpan]::FromHours(2)
$now = (Get-Date).ToUniversalTime()
$ssh = @(Get-NetTCPConnection -LocalPort 22 -State Established -ErrorAction SilentlyContinue)
$work = @(Get-Process -Name dotnet, MSBuild, testhost, VBCSCompiler -ErrorAction SilentlyContinue)
if ($ssh.Count -gt 0 -or $work.Count -gt 0 -or -not (Test-Path $mark)) {
    Set-Content -Path $mark -Value $now.ToString('o')
    return
}
$last = [DateTime]::Parse((Get-Content -Path $mark -Raw).Trim(), [Globalization.CultureInfo]::InvariantCulture,
    [Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
$boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime()
if ($boot -gt $last) { $last = $boot }
if (($now - $last) -lt $limit) { return }
$metadata = @{ Metadata = 'true' }
$vm = (Invoke-RestMethod -Headers $metadata -Uri 'http://169.254.169.254/metadata/instance/compute?api-version=2021-02-01').resourceId
if ($vm -notmatch '^/subscriptions/[0-9a-f-]+/resourceGroups/[^/]+/providers/Microsoft\.Compute/virtualMachines/[^/]+$') {
    throw "not a VM's id: $vm"
}
Add-Content -Path $log -Value ("{0}  no use since {1}: deallocate" -f $now.ToString('o'), $last.ToString('o'))
# The next start counts from its boot (above), not from this old mark; a deallocation that fails is tried again in 10
# minutes, with a line each time.
$token = (Invoke-RestMethod -Headers $metadata -Uri 'http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fmanagement.azure.com%2F').access_token
try {
    Invoke-RestMethod -Method Post -Headers @{ Authorization = "Bearer $token" } `
        -Uri "https://management.azure.com$vm/deallocate?api-version=2024-03-01" | Out-Null
} catch {
    Add-Content -Path $log -Value ("{0}  the deallocation failed: {1}" -f (Get-Date).ToUniversalTime().ToString('o'), $_.Exception.Message)
    throw
} finally {
    $token = $null
}
