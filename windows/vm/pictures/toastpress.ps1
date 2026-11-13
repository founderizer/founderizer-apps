# toastpress.ps1: waits for the app's next notification (a new line "notification:" in its log), takes a picture of the
# screen while Windows shows it (C:\fz\toast.png), and presses its middle with the mouse, as a person does.
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices;
public static class FzPress {
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint x, uint y, uint d, UIntPtr e);
}
'@
[FzPress]::SetProcessDPIAware() | Out-Null
$before = @(Select-String -Path C:\fz\timing.log -Pattern '^notification:').Count
for ($i = 0; $i -lt 60; $i++) { Start-Sleep -Milliseconds 200; if (@(Select-String -Path C:\fz\timing.log -Pattern '^notification:').Count -gt $before) { break } }
Start-Sleep -Milliseconds 900
$bounds = [System.Windows.Forms.SystemInformation]::VirtualScreen
$bitmap = New-Object System.Drawing.Bitmap $bounds.Width, $bounds.Height
$graphics = [System.Drawing.Graphics]::FromImage($bitmap)
$graphics.CopyFromScreen($bounds.Left, $bounds.Top, 0, 0, $bitmap.Size)
$bitmap.Save('C:\fz\toast.png', [System.Drawing.Imaging.ImageFormat]::Png)
$graphics.Dispose(); $bitmap.Dispose()
[FzPress]::SetCursorPos(2300, 1660); Start-Sleep -Milliseconds 150
[FzPress]::mouse_event(2, 0, 0, 0, [UIntPtr]::Zero); [FzPress]::mouse_event(4, 0, 0, 0, [UIntPtr]::Zero)
Start-Sleep -Seconds 2
'pressed the notification'
