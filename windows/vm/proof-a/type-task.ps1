# Starts type-pipe.ps1 in the signed-in user's desktop session (secret.sh on a PC with no QEMU keyboard), or waits for
# its end and removes its task. Run over SSH; the caller sets $do ("start" or "finish"), $enter ("yes" or "no") and, to
# start, $field (the automation id of the field that takes the value).
$ErrorActionPreference = 'Stop'
$task = 'fz-proof-a-keys'
$state = 'C:\fz\proof-a\keys.state'
# type-pipe.ps1 puts each state in place in one step (a new file that takes the state file's place); a read that meets
# that step is tried again, so that a read never ends the wait (the round-5 stage, 22 November 2026: "The process cannot
# access the file ... because it is being used by another process"). A moment with no file (File.Replace can leave
# none for a moment) is tried again too: a read gives nothing only after 2 s with no whole state.
function Read-State {
    for ($i = 0; $i -lt 40; $i++) {
        if ([System.IO.File]::Exists($state)) {
            try { return [System.IO.File]::ReadAllText($state).Trim() } catch { }
        }
        Start-Sleep -Milliseconds 50
    }
    return $null
}
if ($do -eq 'start') {
    if (Get-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue) { Unregister-ScheduledTask -TaskName $task -Confirm:$false }
    Remove-Item -Path $state, "$state.new" -ErrorAction SilentlyContinue
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
    while ((Read-State) -ne 'listening') {
        if ((Get-Date) -gt $deadline) { throw 'the typer did not listen in 60 seconds' }
        Start-Sleep -Milliseconds 300
    }
    'listening'
} elseif ($do -eq 'finish') {
    $deadline = (Get-Date).AddSeconds(120)
    while ((Read-State) -eq 'listening') {
        if ((Get-Date) -gt $deadline) { break }
        Start-Sleep -Milliseconds 300
    }
    $said = Read-State
    Stop-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $task -Confirm:$false -ErrorAction SilentlyContinue
    Remove-Item -Path $state, "$state.new" -ErrorAction SilentlyContinue
    $said
} else {
    throw "do is start or finish, not $do"
}
