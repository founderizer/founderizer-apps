# The elevated starts of a run on the Azure PC (azure-pc-make.sh elevated): on that PC an administrator's rise goes on
# with no question (azure-pc-setup.ps1), so an elevation that must not happen would pass unseen. Windows' audit of
# process creation (event 4688 in the security log) records each start with its token; this lists each start since
# $since (UTC, the caller sets it) by the user "builder" with a full administrator's token (TokenElevationTypeFull,
# %%1937): the time, the program and the program that started it. No command line is listed: a command line can hold
# a value. It runs over SSH as an administrator, which can read the security log.
$ErrorActionPreference = 'Stop'
$start = [DateTime]::Parse($since, [Globalization.CultureInfo]::InvariantCulture,
    [Globalization.DateTimeStyles]::AdjustToUniversal -bor [Globalization.DateTimeStyles]::AssumeUniversal).ToLocalTime()
$events = @(Get-WinEvent -FilterHashtable @{ LogName = 'Security'; Id = 4688; StartTime = $start } -ErrorAction SilentlyContinue)
$found = 0
foreach ($e in ($events | Sort-Object TimeCreated)) {
    $data = @{}
    foreach ($d in ([xml]$e.ToXml()).Event.EventData.Data) { $data[$d.Name] = $d.'#text' }
    # The new process's user: for a start that Windows elevates, a system service creates the process, and the user is
    # in TargetUserName; else (no target, or "-") the creator in SubjectUserName is the user.
    $user = if ($data.TargetUserName -and $data.TargetUserName -ne '-') { $data.TargetUserName } else { $data.SubjectUserName }
    if ($data.TokenElevationType -ne '%%1937' -or $user -ne 'builder') { continue }
    $found++
    "{0:u}  {1}  (started by {2})" -f $e.TimeCreated.ToUniversalTime(), $data.NewProcessName, $data.ParentProcessName
}
"elevated starts of builder since ${since}: $found (of $($events.Count) starts in the log)"
