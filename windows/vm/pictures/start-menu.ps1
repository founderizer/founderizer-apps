# start-menu.ps1: starts Founderizer as the owner does: the Windows key, the app's name, Enter (keyboard input that
# Windows takes as the user's own), then waits for its window (window.ps1).
Add-Type @"
using System; using System.Runtime.InteropServices;
public static class FzKeys {
    [DllImport("user32.dll")] public static extern void keybd_event(byte k, byte s, uint f, UIntPtr e);
    public static void Tap(byte k) { keybd_event(k, 0, 0, UIntPtr.Zero); keybd_event(k, 0, 2, UIntPtr.Zero); }
}
"@
Add-Type -AssemblyName System.Windows.Forms
[FzKeys]::Tap(0x5B)          # the Windows key: Start opens
Start-Sleep -Milliseconds 1500
[System.Windows.Forms.SendKeys]::SendWait('Founderizer')
Start-Sleep -Milliseconds 2500
[System.Windows.Forms.SendKeys]::SendWait('{ENTER}')
& C:\fz\run\window.ps1
