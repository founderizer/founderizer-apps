# keys.ps1 -Text <keys> [-Ctrl <letter>]: keyboard input as a person types it (SendKeys syntax: {ENTER}, {DOWN}, {ESC}),
# or Ctrl and a letter.
param([string]$Text, [string]$Ctrl)
Add-Type -AssemblyName System.Windows.Forms
if ($Ctrl) { [System.Windows.Forms.SendKeys]::SendWait('^' + $Ctrl.ToLower()); Start-Sleep -Milliseconds 400 }
if ($Text) { [System.Windows.Forms.SendKeys]::SendWait($Text); Start-Sleep -Milliseconds 400 }
'keys sent'
