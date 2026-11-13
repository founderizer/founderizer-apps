# One step of a scripted run of the Windows app, through UI Automation, in the signed-in user's desktop session
# (vm.sh desktop): it presses the button named -Invoke (a row of the pane, Back or Forward), and then prints which
# page is open and whether Back and Forward can be pressed. With no -Invoke it only prints. No person is needed.
#
#   vm.sh desktop '& C:\fz\setup\ui.ps1 -Invoke "Tasks"'
param([string]$Invoke)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
$A = [System.Windows.Automation.AutomationElement]
$Scope = [System.Windows.Automation.TreeScope]
function Condition($property, $value) { New-Object System.Windows.Automation.PropertyCondition($property, $value) }

$window = $null
for ($i = 0; $i -lt 50 -and -not $window; $i++) {
    $window = $A::RootElement.FindFirst($Scope::Children, (Condition $A::NameProperty 'Founderizer'))
    if (-not $window) { Start-Sleep -Milliseconds 200 }
}
if (-not $window) { throw 'no window named Founderizer' }

function Button([string]$name) {
    $both = New-Object System.Windows.Automation.AndCondition(
        (Condition $A::NameProperty $name),
        (Condition $A::ControlTypeProperty ([System.Windows.Automation.ControlType]::Button)))
    $window.FindFirst($Scope::Descendants, $both)
}

if ($Invoke) {
    $button = Button $Invoke
    if (-not $button) { throw "no button named $Invoke" }
    $button.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    Start-Sleep -Milliseconds 700
}
$page = $window.FindFirst($Scope::Descendants, (Condition $A::AutomationIdProperty 'Page'))
'{0,-18} page: {1,-18} Back: {2,-5} Forward: {3}' -f $(if ($Invoke) { "pressed $Invoke" } else { 'at start' }),
    $page.Current.Name, (Button 'Back').Current.IsEnabled, (Button 'Forward').Current.IsEnabled
