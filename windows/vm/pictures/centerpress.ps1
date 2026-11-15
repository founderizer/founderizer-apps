# centerpress.ps1: opens Windows' notification list (Win+N), finds the notification whose words hold -Words through UI
# Automation, and presses it with the mouse, as a person does; a notification stays in the list after its popup went.
# The shell draws the list in its own host, where UI Automation may reach no item: then -X and -Y, the place of the
# newest notification at the top of the list (in screen pixels), take the press.
#   vm.sh desktop '& C:\fz\setup\centerpress.ps1 -Words "Which day does the example ship? (4)" -X 2440 -Y 320'
param([Parameter(Mandatory)][string]$Words, [int]$X = 0, [int]$Y = 0)
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
Add-Type -TypeDefinition @'
using System.Runtime.InteropServices;
public static class FzCenter {
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint x, uint y, uint d, System.UIntPtr e);
    [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, System.UIntPtr extra);
}
'@
[FzCenter]::SetProcessDPIAware() | Out-Null
# Win+N: the Windows key (0x5B) held while N (0x4E) is pressed.
[FzCenter]::keybd_event(0x5B, 0, 0, [System.UIntPtr]::Zero); [FzCenter]::keybd_event(0x4E, 0, 0, [System.UIntPtr]::Zero)
[FzCenter]::keybd_event(0x4E, 0, 2, [System.UIntPtr]::Zero); [FzCenter]::keybd_event(0x5B, 0, 2, [System.UIntPtr]::Zero)
$A = [System.Windows.Automation.AutomationElement]
$found = $null
for ($i = 0; $i -lt 20 -and -not $found; $i++) {
    Start-Sleep -Milliseconds 500
    foreach ($e in $A::RootElement.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)) {
        $n = $e.Current.Name
        if ($n -and $n.Contains($Words) -and -not $e.Current.IsOffscreen -and $e.Current.BoundingRectangle.Width -gt 0) { $found = $e; break }
    }
}
if ($found) {
    $b = $found.Current.BoundingRectangle
    'found in the list: "{0}" ({1})' -f $found.Current.Name, $found.Current.ControlType.ProgrammaticName
    $X = [int]($b.X + $b.Width / 2); $Y = [int]($b.Y + $b.Height / 2)
}
elseif ($X -gt 0) { "no item with ""$Words"" reached through UI Automation: the press goes to the top of the list at $X,$Y" }
else { "no notification with ""$Words"" in the list"; exit 1 }
[FzCenter]::SetCursorPos($X, $Y); Start-Sleep -Milliseconds 150
[FzCenter]::mouse_event(2, 0, 0, 0, [System.UIntPtr]::Zero); [FzCenter]::mouse_event(4, 0, 0, 0, [System.UIntPtr]::Zero)
'pressed it'
