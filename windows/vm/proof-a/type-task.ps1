# Starts type-pipe.ps1 in the signed-in user's desktop session (secret.sh on a PC with no QEMU keyboard), or waits for
# its end and removes its task. Run over SSH; the caller sets $do ("start" or "finish"), $enter ("yes" or "no") and, to
# start, $field (the automation id of the field that takes the value).
$ErrorActionPreference = 'Stop'
$task = 'fz-proof-a-keys'
$state = 'C:\fz\proof-a\keys.state'
if ($do -eq 'start') {
    if (Get-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue) { Unregister-ScheduledTask -TaskName $task -Confirm:$false }
    Remove-Item -Path $state -ErrorAction SilentlyContinue
    $flag = if ($enter -eq 'yes') { ' -Enter' } else { '' }
    # The field's automation id: the typer types and presses Enter only while the focus is on it.
    if ($field -notmatch '^[A-Za-z0-9._-]{1,100}$') { throw "not an automation id: $field" }
    $arguments = "--headless powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"C:\fz\proof-a\type-pipe.ps1`" -Pipe fz-proof-a-keys -State `"$state`" -Field $field$flag"
    $action = New-ScheduledTaskAction -Execute 'conhost.exe' -Argument $arguments
    $principal = New-ScheduledTaskPrincipal -UserId 'builder' -LogonType Interactive -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
    Register-ScheduledTask -TaskName $task -Action $action -Principal $principal -Settings $settings -Force | Out-Null
    Start-ScheduledTask -TaskName $task
    $deadline = (Get-Date).AddSeconds(60)
    while (-not ((Test-Path $state) -and (Get-Content $state) -eq 'listening')) {
        if ((Get-Date) -gt $deadline) { throw 'the typer did not listen in 60 seconds' }
        Start-Sleep -Milliseconds 300
    }
    'listening'
} elseif ($do -eq 'finish') {
    $deadline = (Get-Date).AddSeconds(120)
    while ((Get-Content $state -ErrorAction SilentlyContinue) -eq 'listening') {
        if ((Get-Date) -gt $deadline) { break }
        Start-Sleep -Milliseconds 300
    }
    $said = Get-Content $state -ErrorAction SilentlyContinue
    Stop-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $task -Confirm:$false -ErrorAction SilentlyContinue
    Remove-Item -Path $state -ErrorAction SilentlyContinue
    $said
} else {
    throw "do is start or finish, not $do"
}
