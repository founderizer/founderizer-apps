# notify.ps1: the sample's notification (FOUNDERIZER_SAMPLE_STATE=notify) over a page; pictures of the screen at 0.5, 1.5 and 3 seconds after the app
# logged it (C:\fz\notify-1.png and on).
param([string]$State = 'notify', [string]$Page = 'tasks')
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type -TypeDefinition 'using System.Runtime.InteropServices; public static class FzDpi2 { [DllImport("user32.dll")] public static extern bool SetProcessDPIAware(); }'
[FzDpi2]::SetProcessDPIAware() | Out-Null
[void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
[Windows.UI.Notifications.ToastNotificationManager]::History.Clear('Founderizer.Founderizer')
Get-Process Founderizer.App -ErrorAction SilentlyContinue | Stop-Process; Start-Sleep -Milliseconds 500
Remove-Item C:\fz\timing.log, C:\fz\notify-*.png -ErrorAction SilentlyContinue
$env:FOUNDERIZER_TIMING_LOG = 'C:\fz\timing.log'; $env:FOUNDERIZER_SAMPLE = '1'; $env:FOUNDERIZER_SAMPLE_CLOCK = '15:12'; $env:FOUNDERIZER_SAMPLE_STATE = $State
$exe = if ($env:SHOT_EXE) { $env:SHOT_EXE } else { "C:\fz\src\windows\Founderizer.Windows\bin\ARM64\Debug\net10.0-windows10.0.26100.0\win-arm64\Founderizer.App.exe" }
Start-Process -FilePath $exe -ArgumentList '-openPage', $Page
for ($i = 0; $i -lt 60; $i++) { Start-Sleep -Milliseconds 200; if ((Test-Path C:\fz\timing.log) -and (Select-String -Path C:\fz\timing.log -Pattern '^notification:' -Quiet)) { break } }
$n = 1
foreach ($wait in 500, 1000, 1500) {
    Start-Sleep -Milliseconds $wait
    $bounds = [System.Windows.Forms.SystemInformation]::VirtualScreen
    $bitmap = New-Object System.Drawing.Bitmap $bounds.Width, $bounds.Height
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $graphics.CopyFromScreen($bounds.Left, $bounds.Top, 0, 0, $bitmap.Size)
    $bitmap.Save("C:\fz\notify-$n.png", [System.Drawing.Imaging.ImageFormat]::Png)
    $graphics.Dispose(); $bitmap.Dispose(); $n++
}
Get-Content C:\fz\timing.log | Select-String 'notification'
