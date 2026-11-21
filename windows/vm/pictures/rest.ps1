# Brings the app's window to the front with one click on the empty middle of its title bar, and leaves the pointer there,
# so a picture shows the window at rest and in front (no taskbar, no hover, Windows' caption buttons of a front window),
# in the signed-in user's desktop session (vm.sh desktop). -NoClick only moves the pointer. The script is not DPI-aware:
# its points are the screen's at 96 DPI (1440 by 900).
#
#   vm.sh desktop '& C:\fz\setup\rest.ps1'

param([switch]$NoClick)
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class Pointer {
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint x, uint y, uint data, UIntPtr extra);
}
"@
[Pointer]::SetCursorPos(800, 20) | Out-Null
Start-Sleep -Milliseconds 200
if (-not $NoClick) { [Pointer]::mouse_event(2, 0, 0, 0, [UIntPtr]::Zero); [Pointer]::mouse_event(4, 0, 0, 0, [UIntPtr]::Zero) }
Start-Sleep -Milliseconds 1500
