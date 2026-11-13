# A series of frames of one part of the screen, in the signed-in user's desktop session (vm.sh desktop): for the proof
# that an agent at work moves its glyph and its line and that nothing moves at rest (README.md, "Pictures").
#
#   vm.sh desktop '& C:\fz\setup\frames.ps1 -Out C:\fz\frames -Count 16 -IntervalMs 150'
# The default part is the pane's agents at scale 2: x 0 to 640, y 96 to 800 of the screen's own pixels.
param([string]$Out = 'C:\fz\frames', [int]$Count = 16, [int]$IntervalMs = 150,
      [int]$X = 0, [int]$Y = 96, [int]$Width = 640, [int]$Height = 704)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
Add-Type -TypeDefinition 'using System.Runtime.InteropServices; public static class FzFramesDpi { [DllImport("user32.dll")] public static extern bool SetProcessDPIAware(); }'
[FzFramesDpi]::SetProcessDPIAware() | Out-Null
Remove-Item -Recurse -Force $Out -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $Out | Out-Null
$clock = [Diagnostics.Stopwatch]::StartNew()
for ($i = 0; $i -lt $Count; $i++) {
    $due = $i * $IntervalMs
    while ($clock.ElapsedMilliseconds -lt $due) { Start-Sleep -Milliseconds 5 }
    $bitmap = New-Object System.Drawing.Bitmap $Width, $Height
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $graphics.CopyFromScreen($X, $Y, 0, 0, $bitmap.Size)
    $bitmap.Save((Join-Path $Out ('frame-{0:D2}.png' -f $i)), [System.Drawing.Imaging.ImageFormat]::Png)
    $graphics.Dispose(); $bitmap.Dispose()
}
"{0} frames in {1} ms" -f $Count, $clock.ElapsedMilliseconds
