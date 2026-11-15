# The counts that the window shows, read through UI Automation in the signed-in user's desktop session (vm.sh desktop),
# with no name, title or words of the fleet: the agents' rows of the pane, the open requests of the pane's count, the
# cards of each lane when the board shows, and whether the line over the page shows (a read that failed, a refusal).
#
#   vm.sh desktop '& C:\fz\setup\counts.ps1'
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
$A = [System.Windows.Automation.AutomationElement]
$Scope = [System.Windows.Automation.TreeScope]
$Types = [System.Windows.Automation.ControlType]
function Condition($property, $value) { New-Object System.Windows.Automation.PropertyCondition($property, $value) }
$window = $A::RootElement.FindFirst($Scope::Children, (Condition $A::NameProperty 'Founderizer'))
if (-not $window) { throw 'no window named Founderizer' }
$w = $window.Current.BoundingRectangle

# The pane: the buttons between its Tasks row and its Settings row, within the Tasks row's width.
$buttons = $window.FindAll($Scope::Descendants, (Condition $A::ControlTypeProperty $Types::Button))
$tasks = $null; $settings = $null
foreach ($b in $buttons) {
    if ($b.Current.Name -eq 'Tasks' -and -not $tasks) { $tasks = $b.Current.BoundingRectangle }
    if ($b.Current.Name -eq 'Settings' -and -not $settings) { $settings = $b.Current.BoundingRectangle }
}
$agents = 0
foreach ($b in $buttons) {
    $r = $b.Current.BoundingRectangle
    if (-not $tasks -or -not $settings -or $b.Current.IsOffscreen) { continue }
    if ($r.X -ge $tasks.X - 2 -and $r.Right -le $tasks.Right + 2 -and $r.Y -ge $tasks.Bottom - 1 -and $r.Bottom -le $settings.Y + 1) { $agents++ }
}
'agents in the pane: {0}' -f $agents
$needs = $window.FindFirst($Scope::Descendants, (Condition $A::AutomationIdProperty 'NeedsCount'))
'open requests (the pane''s count): {0}' -f $(if ($needs -and -not $needs.Current.IsOffscreen -and $needs.Current.Name) { $needs.Current.Name } else { 'none shown' })

# The board's lanes: each lane's title and the count beside it.
foreach ($lane in 'In progress', 'Waiting', 'Ended') {
    $title = $window.FindFirst($Scope::Descendants, (New-Object System.Windows.Automation.AndCondition(
        (Condition $A::NameProperty $lane), (Condition $A::ControlTypeProperty $Types::Text))))
    if (-not $title -or $title.Current.IsOffscreen) { continue }
    $walker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
    $next = $walker.GetNextSibling($title)
    'lane "{0}": {1} task(s)' -f $lane, $(if ($next) { $next.Current.Name } else { '?' })
}
$line = $window.FindFirst($Scope::Descendants, (Condition $A::AutomationIdProperty 'Line'))
'the line over the page shows: {0}' -f [bool]($line -and -not $line.Current.IsOffscreen -and $line.Current.Name)
