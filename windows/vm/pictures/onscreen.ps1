# onscreen.ps1: whether "Latest" shows in the app's window, where the largest scroll view of the page stands (UI
# Automation's ScrollPattern: the share scrolled and the share in view), and, with -Words, whether an element with
# those words is in view in that scroll view (a row of a virtualized list that is not near the view has no element).
#   vm.sh desktop '& C:\fz\setup\onscreen.ps1 -Words "The example build passed its checks (12)."'
param([string]$Words)
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
$A = [System.Windows.Automation.AutomationElement]
$Scope = [System.Windows.Automation.TreeScope]
function Condition($property, $value) { New-Object System.Windows.Automation.PropertyCondition($property, $value) }
$window = $A::RootElement.FindFirst($Scope::Children, (Condition $A::NameProperty 'Founderizer'))
if (-not $window) { throw 'no window named Founderizer' }
$latest = $window.FindFirst($Scope::Descendants, (New-Object System.Windows.Automation.AndCondition(
    (Condition $A::NameProperty 'Latest'), (Condition $A::ControlTypeProperty ([System.Windows.Automation.ControlType]::Button)))))
'"Latest" shows: ' + [bool]($latest -and -not $latest.Current.IsOffscreen)
$scrolls = $window.FindAll($Scope::Descendants, (Condition $A::IsScrollPatternAvailableProperty $true))
$biggest = $null
foreach ($s in $scrolls) {
    $p = $s.GetCurrentPattern([System.Windows.Automation.ScrollPattern]::Pattern)
    if (-not $p.Current.VerticallyScrollable) { continue }
    if (-not $biggest -or $s.Current.BoundingRectangle.Height -gt $biggest.Current.BoundingRectangle.Height) { $biggest = $s }
}
if ($biggest) {
    $p = $biggest.GetCurrentPattern([System.Windows.Automation.ScrollPattern]::Pattern)
    'the thread: scrolled {0:F1} %, {1:F1} % of it in view, {2:F0} pixels high' -f $p.Current.VerticalScrollPercent, $p.Current.VerticalViewSize, $biggest.Current.BoundingRectangle.Height
}
if ($Words) {
    # Only inside the thread: the pane's row of the agent can hold the same words (its last message).
    $within = if ($biggest) { $biggest } else { $window }
    $e = $within.FindFirst($Scope::Descendants, (Condition $A::NameProperty $Words))
    $view = if ($biggest) { $biggest.Current.BoundingRectangle } else { $window.Current.BoundingRectangle }
    if (-not $e) { 'in view "{0}": False (no element)' -f $Words }
    else {
        $b = $e.Current.BoundingRectangle
        'in view "{0}": {1}' -f $Words, (-not $e.Current.IsOffscreen -and $b.Bottom -gt $view.Top -and $b.Top -lt $view.Bottom)
    }
}
