# The elevated starts of a run on the Azure PC (azure-pc-make.sh elevated, and its probe): on that PC an administrator's
# rise goes on with no question (azure-pc-setup.ps1), so an elevation that must not happen would pass unseen. Windows'
# audit of process creation (event 4688 in the security log) records each start with its token; this lists each start
# since $since (UTC, the caller sets it) by the user "builder" with a full administrator's token
# (TokenElevationTypeFull, %%1937): the time, what it is, the program and the program that started it. No command line
# is listed: a command line can hold a value. It runs over SSH as an administrator, which can read the security log.
#
# Each start has one of three names:
#   "the probe's whoami.exe"   a rise that azure-pc-make.sh probe asked for: a whoami.exe whose event has the
#                              SubjectUserSid S-1-5-18 (Windows' own service that elevates), the TargetUserName builder
#                              and %%1937, which svchost.exe did not start, before $probeAt (the time of the probe that
#                              passed; the caller sets it, or nothing during the probe itself); and its conhost.exe.
#                              Each whoami.exe's fields are printed, counted or refused, with "[from a task's
#                              cmd.exe]" when a cmd.exe that the Task Scheduler started is in its chain (the
#                              self-test's task: azure-pc-make.sh probe --from-full-token)
#   "a task of builder"        a scheduled task of builder and what it starts: on the Azure PC (the built-in
#                              Administrator with FilterAdministratorToken 1) a task has the full token, so each
#                              command of vm.sh desktop and the typer (type-pipe.ps1) is in this list. A task's start
#                              is a conhost.exe that the Task Scheduler (svchost.exe) starts; its descendants follow it
#   "OTHER"                    any other start with the full token: an elevation that the run must explain (for
#                              example Tailscale's installer after Windows' question, or one that must not happen),
#                              and a whoami.exe rise after the probe's time
# The last line is "probe=<n>": the count of the probe's whoami.exe rises. The probe passes only on n of 1 or more.
# Each start of any user writes its new process id's kind again, so an id that Windows gives again to a new process
# loses the kind of its old one: a setup or an app with a task's old id is not filed as a task. The events are read in
# the log's own write order (RecordId), never by their times: a clock that Windows' time sync steps back between a
# parent's start and its child's would put the child first, with the parent's old id and its old kind. At each "Windows
# is starting up" (event 4608) all kinds are emptied: the processes that start before the audit (smss, csrss, wininit,
# winlogon) have no 4688 and could keep the kind of a task's id from before the restart.
$ErrorActionPreference = 'Stop'
$styles = [Globalization.DateTimeStyles]::AdjustToUniversal -bor [Globalization.DateTimeStyles]::AssumeUniversal
$start = [DateTime]::Parse($since, [Globalization.CultureInfo]::InvariantCulture, $styles).ToLocalTime()
$end = if ($probeAt) { [DateTime]::Parse($probeAt, [Globalization.CultureInfo]::InvariantCulture, $styles).ToLocalTime() } else { $null }
$events = @(Get-WinEvent -FilterHashtable @{ LogName = 'Security'; Id = 4688, 4608; StartTime = $start } -ErrorAction SilentlyContinue)
$starts = 0
$task = @{}
$probe = @{}
$cmdtask = @{}
$count = @{ probe = 0; task = 0; other = 0 }
$rises = 0
$names = @{ probe = "the probe's whoami.exe"; task = 'a task of builder'; other = 'OTHER' }
foreach ($e in ($events | Sort-Object RecordId)) {
    if ($e.Id -eq 4608) {
        $task.Clear(); $probe.Clear(); $cmdtask.Clear()
        "Windows started {0:u}: the kinds of all process ids are emptied" -f $e.TimeCreated.ToUniversalTime()
        continue
    }
    $starts++
    $data = @{}
    foreach ($d in ([xml]$e.ToXml()).Event.EventData.Data) { $data[$d.Name] = $d.'#text' }
    # The new process's user: for a start that Windows elevates, a system service creates the process, and the user is
    # in TargetUserName; else (no target, or "-") the creator in SubjectUserName is the user.
    $user = if ($data.TargetUserName -and $data.TargetUserName -ne '-') { $data.TargetUserName } else { $data.SubjectUserName }
    $leaf = Split-Path -Leaf $data.NewProcessName
    $parent = if ($data.ParentProcessName) { Split-Path -Leaf $data.ParentProcessName } else { '' }
    $fromCmdTask = [bool]($cmdtask[$data.ProcessId] -or ($leaf -eq 'cmd.exe' -and $parent -eq 'svchost.exe'))
    if ($task[$data.ProcessId] -or ($leaf -eq 'conhost.exe' -and $parent -eq 'svchost.exe')) { $kind = 'task' }
    elseif ($leaf -eq 'conhost.exe' -and $probe[$data.ProcessId]) { $kind = 'probe' }
    else { $kind = 'other' }
    if ($leaf -eq 'whoami.exe') {
        $rise = $data.SubjectUserSid -eq 'S-1-5-18' -and $data.TargetUserName -eq 'builder' -and
            $data.TokenElevationType -eq '%%1937' -and $parent -ne 'svchost.exe'
        if ($rise -and (-not $end -or $e.TimeCreated -lt $end)) { $kind = 'probe'; $rises++; $verdict = "counted: the probe's rise" }
        elseif ($rise) { $kind = 'other'; $verdict = "refused: a rise after the probe's time (OTHER)" }
        else { $verdict = 'refused: not a rise' }
        "whoami.exe {0:u}: {1} (SubjectUserSid {2}, TargetUserName {3}, TokenElevationType {4}, started by {5}){6}" -f `
            $e.TimeCreated.ToUniversalTime(), $verdict, $data.SubjectUserSid, $data.TargetUserName, `
            $data.TokenElevationType, $data.ParentProcessName, $(if ($fromCmdTask) { " [from a task's cmd.exe]" } else { '' })
    }
    $task[$data.NewProcessId] = ($kind -eq 'task')
    $probe[$data.NewProcessId] = ($kind -eq 'probe')
    $cmdtask[$data.NewProcessId] = $fromCmdTask
    if ($user -ne 'builder' -or $data.TokenElevationType -ne '%%1937') { continue }
    $count[$kind]++
    "{0:u}  {1}  {2}  (started by {3})" -f $e.TimeCreated.ToUniversalTime(), $names[$kind], $data.NewProcessName, $data.ParentProcessName
}
"elevated starts of builder since ${since}: $($count.probe + $count.task + $count.other) (the probe's starts: $($count.probe); tasks of builder, which have the full token on the Azure PC: $($count.task); OTHER: $($count.other)) of $starts starts in the log"
"probe=$rises"
