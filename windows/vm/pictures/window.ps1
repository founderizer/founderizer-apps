# window.ps1: waits until the window "Founderizer" is there (at most 90 s), and says how long it took and whether it
# is the window in front.
Add-Type @"
using System; using System.Runtime.InteropServices;
public static class FzWindow {
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindow(string c, string n);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
}
"@
$t = Get-Date
for ($i = 0; $i -lt 180; $i++) { if ([FzWindow]::FindWindow([NullString]::Value, 'Founderizer') -ne [IntPtr]::Zero) { break }; Start-Sleep -Milliseconds 500 }
$w = [FzWindow]::FindWindow([NullString]::Value, 'Founderizer')
Start-Sleep -Milliseconds 1500
"the window is there: " + ($w -ne [IntPtr]::Zero) + ", after " + [int]((Get-Date) - $t).TotalSeconds + " s; it is the window in front: " + ($w -ne [IntPtr]::Zero -and [FzWindow]::GetForegroundWindow() -eq $w)
