# reveal.ps1: the pointer at the foot of the screen, so that the taskbar that hides by itself comes up.
Add-Type -TypeDefinition 'using System.Runtime.InteropServices; public static class FzReveal { [DllImport("user32.dll")] public static extern bool SetProcessDPIAware(); [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y); }'
[FzReveal]::SetProcessDPIAware() | Out-Null
[FzReveal]::SetCursorPos(1440, 1799); Start-Sleep -Milliseconds 1500; 'the taskbar is up'
