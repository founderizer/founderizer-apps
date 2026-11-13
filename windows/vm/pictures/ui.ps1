# One step of a scripted run of the Windows app, through UI Automation, in the signed-in user's desktop session
# (vm.sh desktop), and then it prints which page is open and whether Back and Forward can be pressed. No person is
# needed. One of:
#   -Invoke <name>               presses the button of that name (a row of the pane, a card, an option, Back, Pause)
#   -Click <name>                the same with the mouse, as a person presses it: no keyboard focus frame shows after
#                                it, so a picture taken next is the window at rest. The pointer then rests on the
#                                empty middle of the title bar, where nothing shows a hover or a tooltip.
#   -Field <name> -Type <words>  writes the words into the field of that name (its placeholder, or the start of it)
#                                and presses Enter (with -NoEnter not: a whole code sends itself)
#   -Read <id>                   prints the words of the element with that automation id (TaskState, NeedsCount)
#   -Has <words>                 prints whether an element with those words shows (a message, a card's title)
# With none of them it only prints.
#
#   vm.sh desktop '& C:\fz\setup\ui.ps1 -Click "Tasks"'
#   vm.sh desktop '& C:\fz\setup\ui.ps1 -Field "Message Fleet Manager" -Type "Which order is it?"'
param([string]$Invoke, [string]$Click, [string]$Field, [string]$Type, [switch]$NoEnter, [string]$Read, [string]$Has)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes, System.Windows.Forms
Add-Type -TypeDefinition @'
using System.Runtime.InteropServices;
public static class FzMouse {
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint dx, uint dy, uint data, System.UIntPtr extra);
    public static void Click(int x, int y) {
        SetCursorPos(x, y); System.Threading.Thread.Sleep(80);
        mouse_event(0x0002, 0, 0, 0, System.UIntPtr.Zero); mouse_event(0x0004, 0, 0, 0, System.UIntPtr.Zero);
    }
}
'@
[FzMouse]::SetProcessDPIAware() | Out-Null
$A = [System.Windows.Automation.AutomationElement]
$Scope = [System.Windows.Automation.TreeScope]
$Types = [System.Windows.Automation.ControlType]
function Condition($property, $value) { New-Object System.Windows.Automation.PropertyCondition($property, $value) }

$window = $null
for ($i = 0; $i -lt 50 -and -not $window; $i++) {
    $window = $A::RootElement.FindFirst($Scope::Children, (Condition $A::NameProperty 'Founderizer'))
    if (-not $window) { Start-Sleep -Milliseconds 200 }
}
if (-not $window) { throw 'no window named Founderizer' }

function Named([string]$name, $type) {
    $both = New-Object System.Windows.Automation.AndCondition((Condition $A::NameProperty $name), (Condition $A::ControlTypeProperty $type))
    $window.FindFirst($Scope::Descendants, $both)
}
function Button([string]$name) { Named $name $Types::Button }

$did = 'at start'
if ($Invoke) {
    $button = Button $Invoke
    if (-not $button) { throw "no button named $Invoke" }
    $button.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    $did = "pressed $Invoke"
}
elseif ($Click) {
    $button = Button $Click
    if (-not $button) { throw "no button named $Click" }
    # A button that is not enabled takes no press (a write waits for its receipt): wait for it, up to 30 seconds.
    $waited = [Diagnostics.Stopwatch]::StartNew()
    while (-not $button.Current.IsEnabled -and $waited.Elapsed.TotalSeconds -lt 30) { Start-Sleep -Milliseconds 200 }
    if (-not $button.Current.IsEnabled) { throw "$Click is not enabled after 30 s" }
    if ($waited.Elapsed.TotalSeconds -gt 0.3) { '{0} was not enabled for {1:F1} s' -f $Click, $waited.Elapsed.TotalSeconds }
    $box = $button.Current.BoundingRectangle
    [FzMouse]::Click([int]($box.X + $box.Width / 2), [int]($box.Y + $box.Height / 2))
    Start-Sleep -Milliseconds 150
    # The pointer leaves in steps, so the button under the click gets its pointer-exit and loses its hover.
    $screen = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    $x = [int]($box.X + $box.Width / 2); $y = [int]($box.Y + $box.Height / 2)
    # A moved cursor alone gives WinUI no pointer input: each step is a mouse move as input (absolute, 0 to 65535).
    $restX = $screen.Width / 2; $restY = 30
    foreach ($step in 1..8) {
        $tx = $x + ($restX - $x) * $step / 8; $ty = $y + ($restY - $y) * $step / 8
        [FzMouse]::mouse_event(0x8001, [uint32]($tx * 65535 / ($screen.Width - 1)), [uint32]($ty * 65535 / ($screen.Height - 1)), 0, [System.UIntPtr]::Zero)
        Start-Sleep -Milliseconds 40
    }
    Start-Sleep -Milliseconds 300
    $did = "clicked $Click"
}
elseif ($Field) {
    $edit = Named $Field $Types::Edit
    if (-not $edit) {
        $edits = $window.FindAll($Scope::Descendants, (Condition $A::ControlTypeProperty $Types::Edit))
        $edit = @($edits | Where-Object { $_.Current.Name.StartsWith($Field) })[0]
    }
    if (-not $edit) { throw "no field named $Field" }
    $edit.SetFocus()
    $edit.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).SetValue($Type)
    Start-Sleep -Milliseconds 400
    if (-not $NoEnter) { [System.Windows.Forms.SendKeys]::SendWait('{ENTER}') }
    $did = "wrote into $Field"
}
if ($did -ne 'at start') { Start-Sleep -Milliseconds 700 }
if ($Read) {
    $element = $window.FindFirst($Scope::Descendants, (Condition $A::AutomationIdProperty $Read))
    'read {0}: {1}' -f $Read, $(if ($element) { $element.Current.Name } else { '(none)' })
}
if ($Has) {
    $element = $window.FindFirst($Scope::Descendants, (Condition $A::NameProperty $Has))
    'shows "{0}": {1}' -f $Has, [bool]$element
}
$page = $window.FindFirst($Scope::Descendants, (Condition $A::AutomationIdProperty 'Page'))
'{0,-18} page: {1,-18} Back: {2,-5} Forward: {3}' -f $did, $page.Current.Name, (Button 'Back').Current.IsEnabled,
    (Button 'Forward').Current.IsEnabled
