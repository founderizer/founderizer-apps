# Starts or stops the window watcher (watch.ps1) in the signed-in user's desktop session of a clean PC's copy: a
# scheduled task with an interactive logon, under conhost --headless, so that the watcher has no window of its own. Run
# over SSH by watch.sh; the caller sets $do to "start" or "stop".
$ErrorActionPreference = 'Stop'
$task = 'fz-proof-a-watch'
$folder = 'C:\fz\proof-a'
$log = Join-Path $folder 'windows.log'
$stop = Join-Path $folder 'watch.stop'
function Wait-Line([string]$word, [int]$seconds) {
    $deadline = (Get-Date).AddSeconds($seconds)
    while ((Get-Date) -lt $deadline) {
        if (Test-Path $log) {
            $line = Get-Content -Path $log -Encoding utf8 | Where-Object { ($_ -split "`t")[1] -eq $word } | Select-Object -Last 1
            if ($line) { return $line }
        }
        Start-Sleep -Milliseconds 500
    }
    throw "the watcher wrote no '$word' line in $seconds seconds"
}
if ($do -eq 'start') {
    if (Get-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue) { throw 'the watcher is registered already: watch.sh stop first' }
    Remove-Item -Path $stop -ErrorAction SilentlyContinue
    if (Test-Path $log) { Move-Item -Path $log -Destination (Join-Path $folder ('windows-before-' + (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmss') + '.log')) }
    $arguments = "--headless powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$folder\watch.ps1`" -Log `"$log`" -Stop `"$stop`""
    $action = New-ScheduledTaskAction -Execute 'conhost.exe' -Argument $arguments
    $principal = New-ScheduledTaskPrincipal -UserId 'builder' -LogonType Interactive -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero)
    Register-ScheduledTask -TaskName $task -Action $action -Principal $principal -Settings $settings -Force | Out-Null
    Start-ScheduledTask -TaskName $task
    Wait-Line 'watching' 90
} elseif ($do -eq 'stop') {
    if (-not (Get-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue)) { throw 'no watcher is registered' }
    New-Item -ItemType File -Force -Path $stop | Out-Null
    try { Wait-Line 'stopped' 60 } finally {
        Stop-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $task -Confirm:$false
        Remove-Item -Path $stop -ErrorAction SilentlyContinue
    }
} else {
    throw "do is start or stop, not $do"
}
