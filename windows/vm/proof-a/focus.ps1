# What has the keyboard's focus in the signed-in user's desktop session (secret.sh runs it with vm.sh desktop): one line
# with the program, the element's automation id, its name, its type, whether it is a password box, and how many
# characters it holds: "unknown" only for a password box, "none" for an element with no value. Never its words: a
# field's contents stay out of every output.
#
#   & C:\fz\proof-a\focus.ps1              the element that has the focus
#   & C:\fz\proof-a\focus.ps1 -Id <id>     the element of Founderizer's window with that automation id, or "gone"
param([string]$Id)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
$A = [System.Windows.Automation.AutomationElement]
if ($Id) {
    $window = $A::RootElement.FindFirst([System.Windows.Automation.TreeScope]::Children,
        (New-Object System.Windows.Automation.PropertyCondition($A::NameProperty, 'Founderizer')))
    $element = if ($window) { $window.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
        (New-Object System.Windows.Automation.PropertyCondition($A::AutomationIdProperty, $Id))) }
    if (-not $element) { "element`tgone"; return }
} else {
    $element = $A::FocusedElement
    if (-not $element) { "focus`tnone"; return }
}
$current = $element.Current
$program = try { (Get-Process -Id $current.ProcessId).ProcessName } catch { 'unknown' }
$length = 'unknown'
if (-not $current.IsPassword) {
    $length = 'none'
    $pattern = $null
    if ($element.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref]$pattern)) {
        $length = [string]$pattern.Current.Value.Length
    }
}
$hasFocus = $current.HasKeyboardFocus
"$(if ($Id) { 'element' } else { 'focus' })`tprogram=$program`tid=$($current.AutomationId)`tname=$($current.Name)`ttype=$($current.ControlType.ProgrammaticName)`tpassword=$($current.IsPassword)`tlength=$length`tfocused=$hasFocus"
