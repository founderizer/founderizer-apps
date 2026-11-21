# Every element of the app's window as UI Automation sees it, one line each, in the signed-in user's desktop session
# (vm.sh desktop): its control type, its automation id, its rectangle in the screen's own pixels (x, y, width, height)
# and its name (the words of a text, the name of a button), tab-separated. elements.py reads it against a picture set's
# list of elements and words.
#
# The lines go to a file in UTF-8 (-Out), since the desktop session's console turns words such as "›" into others.
#
#   vm.sh desktop '& C:\fz\setup\elements.ps1 -Out C:\fz\page.tsv'
#   vm.sh copy vm:C:/fz/page.tsv page.tsv
param([Parameter(Mandatory = $true)][string]$Out)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
Add-Type -TypeDefinition 'using System.Runtime.InteropServices; public static class FzElementsDpi { [DllImport("user32.dll")] public static extern bool SetProcessDPIAware(); }'
[FzElementsDpi]::SetProcessDPIAware() | Out-Null
$A = [System.Windows.Automation.AutomationElement]
$window = $A::RootElement.FindFirst([System.Windows.Automation.TreeScope]::Children,
    (New-Object System.Windows.Automation.PropertyCondition($A::NameProperty, 'Founderizer')))
if (-not $window) { throw 'no window named Founderizer' }
$walker = [System.Windows.Automation.TreeWalker]::RawViewWalker
function Walk($element) {
    $child = $walker.GetFirstChild($element)
    while ($child) {
        $c = $child.Current
        $box = $c.BoundingRectangle
        if (-not $c.IsOffscreen -and -not $box.IsEmpty -and $box.Width -gt 0) {
            $name = ($c.Name -replace "[`t`r`n]", ' ')
            "{0}`t{1}`t{2:F0}`t{3:F0}`t{4:F0}`t{5:F0}`t{6}" -f $c.ControlType.ProgrammaticName.Replace('ControlType.', ''), $c.AutomationId,
                $box.X, $box.Y, $box.Width, $box.Height, $name
        }
        Walk $child
        $child = $walker.GetNextSibling($child)
    }
}
$lines = @(Walk $window)
[IO.File]::WriteAllLines($Out, [string[]]$lines, (New-Object System.Text.UTF8Encoding($false)))
"{0} elements in {1}" -f $lines.Count, $Out
