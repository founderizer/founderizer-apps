# One click of the mouse at a point of the screen at 96 DPI (1440 by 900; this script is not DPI-aware), in the
# signed-in user's desktop session (vm.sh desktop), then the pointer rests on the title bar's empty middle.
#
#   vm.sh desktop '& C:\fz\setup\click.ps1 -X 975 -Y 422'

param([int]$X, [int]$Y)
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class Mouse {
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint x, uint y, uint data, UIntPtr extra);
}
"@
[Mouse]::SetCursorPos($X, $Y) | Out-Null; Start-Sleep -Milliseconds 150
[Mouse]::mouse_event(2, 0, 0, 0, [UIntPtr]::Zero); Start-Sleep -Milliseconds 60; [Mouse]::mouse_event(4, 0, 0, 0, [UIntPtr]::Zero)
Start-Sleep -Milliseconds 400
[Mouse]::SetCursorPos(800, 20) | Out-Null; Start-Sleep -Milliseconds 800
