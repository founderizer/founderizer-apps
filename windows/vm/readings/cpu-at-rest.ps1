# Reading of rule 6 (app/windows/vm/README.md, "Readings"): the processor at rest. It reads, over the given seconds,
# the processor time of the app (Founderizer) and of the compositor (dwm), which runs the app's motion, as a share of
# one core. Run it over SSH, as an administrator, while the app shows in the desktop session:
#
#   vm.sh run 'powershell -NoProfile -File C:\fz\readings\cpu-at-rest.ps1 -Seconds 60'
param([int]$Seconds = 60)
$ErrorActionPreference = 'Stop'
$app = Get-Process Founderizer.App
$dwm = Get-Process dwm
$appBefore, $dwmBefore = $app.TotalProcessorTime, $dwm.TotalProcessorTime
$clock = [Diagnostics.Stopwatch]::StartNew()
Start-Sleep -Seconds $Seconds
$app.Refresh(); $dwm.Refresh()
$elapsed = $clock.Elapsed.TotalMilliseconds
'over {0:F0} s: app {1:F2}% of one core, compositor (dwm) {2:F2}% of one core; app working set {3:F1} MB, private bytes {4:F1} MB' -f
    ($elapsed / 1000), (($app.TotalProcessorTime - $appBefore).TotalMilliseconds / $elapsed * 100),
    (($dwm.TotalProcessorTime - $dwmBefore).TotalMilliseconds / $elapsed * 100), ($app.WorkingSet64 / 1MB), ($app.PrivateMemorySize64 / 1MB)
