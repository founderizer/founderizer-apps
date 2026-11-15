# A click on an element that a script cannot name in advance, through UI Automation, in the signed-in user's desktop
# session (vm.sh desktop), with the mouse as a person clicks, and nothing of its words printed (a real fleet's titles
# stay off the output). One of:
#   -FirstCardUnder <lane>   the first card under a lane's title of the board ("In progress", "Waiting")
#   -IdPrefix <prefix>       the first element in view whose automation id starts with it ("Fold-steps-": a run's fold)
#   -Field <name>            the field of that name (its placeholder), emptied: the window comes to the front and the
#                            field takes the keyboard, for keys that QEMU types (vm.sh type)
#
#   vm.sh desktop '& C:\fz\setup\pick.ps1 -FirstCardUnder "In progress"'
param([string]$FirstCardUnder, [string]$IdPrefix, [string]$Field)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
Add-Type -TypeDefinition @'
using System.Runtime.InteropServices;
public static class FzPick {
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint dx, uint dy, uint data, System.UIntPtr extra);
    public static void Click(int x, int y) {
        SetCursorPos(x, y); System.Threading.Thread.Sleep(80);
        mouse_event(0x0002, 0, 0, 0, System.UIntPtr.Zero); mouse_event(0x0004, 0, 0, 0, System.UIntPtr.Zero);
    }
}
'@
[FzPick]::SetProcessDPIAware() | Out-Null
$A = [System.Windows.Automation.AutomationElement]
$Scope = [System.Windows.Automation.TreeScope]
$Types = [System.Windows.Automation.ControlType]
function Condition($property, $value) { New-Object System.Windows.Automation.PropertyCondition($property, $value) }
$window = $A::RootElement.FindFirst($Scope::Children, (Condition $A::NameProperty 'Founderizer'))
if (-not $window) { throw 'no window named Founderizer' }
$target = $null
if ($FirstCardUnder) {
    $title = $window.FindFirst($Scope::Descendants, (New-Object System.Windows.Automation.AndCondition(
        (Condition $A::NameProperty $FirstCardUnder), (Condition $A::ControlTypeProperty $Types::Text))))
    if (-not $title) { throw "no lane titled $FirstCardUnder" }
    $t = $title.Current.BoundingRectangle
    # The lane's cards are the buttons under its title that start within its column.
    $best = $null
    foreach ($b in $window.FindAll($Scope::Descendants, (Condition $A::ControlTypeProperty $Types::Button))) {
        $r = $b.Current.BoundingRectangle
        if ($b.Current.IsOffscreen -or $r.Y -le $t.Bottom -or [math]::Abs($r.X - $t.X) -gt 24) { continue }
        if (-not $best -or $r.Y -lt $best.Current.BoundingRectangle.Y) { $best = $b }
    }
    $target = $best
}
elseif ($IdPrefix) {
    foreach ($e in $window.FindAll($Scope::Descendants, [System.Windows.Automation.Condition]::TrueCondition)) {
        if ($e.Current.AutomationId.StartsWith($IdPrefix) -and -not $e.Current.IsOffscreen) { $target = $e; break }
    }
}
elseif ($Field) {
    $target = $window.FindFirst($Scope::Descendants, (New-Object System.Windows.Automation.AndCondition(
        (Condition $A::NameProperty $Field), (Condition $A::ControlTypeProperty $Types::Edit))))
    if ($target) { $target.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).SetValue('') }
}
if (-not $target) { 'nothing to click'; return }
$box = $target.Current.BoundingRectangle
[FzPick]::Click([int]($box.X + $box.Width / 2), [int]($box.Y + $box.Height / 2))
Start-Sleep -Milliseconds 300
$w = $window.Current.BoundingRectangle
[FzPick]::SetCursorPos([int]($w.X + $w.Width / 2), [int]($w.Y + 20)) | Out-Null
'clicked it'
