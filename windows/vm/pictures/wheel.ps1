# wheel.ps1: turns the mouse wheel over a point of the screen, as a person scrolls (positive -Notches scroll up, toward
# a chat's start), and then rests the pointer on the title bar's empty middle.
#   vm.sh desktop '& C:\fz\setup\wheel.ps1 -X 1500 -Y 900 -Notches 4'
param([int]$X, [int]$Y, [int]$Notches = 1)
Add-Type -TypeDefinition @'
using System.Runtime.InteropServices;
public static class FzWheel {
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint dx, uint dy, int data, System.UIntPtr extra);
}
'@
[FzWheel]::SetProcessDPIAware() | Out-Null
[FzWheel]::SetCursorPos($X, $Y); Start-Sleep -Milliseconds 120
$step = if ($Notches -ge 0) { 120 } else { -120 }
for ($i = 0; $i -lt [Math]::Abs($Notches); $i++) { [FzWheel]::mouse_event(0x0800, 0, 0, $step, [System.UIntPtr]::Zero); Start-Sleep -Milliseconds 120 }
Start-Sleep -Milliseconds 600
"turned the wheel $Notches notches at $X,$Y"
