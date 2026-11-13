# size.ps1 -Width <w> -Height <h>: restores the window "Founderizer" and asks Windows for a client area of w by h
# effective pixels (at the window's scale), at the screen's top left; prints the client area that Windows gave, in
# effective pixels, and its place on the screen in the screen's pixels.
param([int]$Width, [int]$Height)
Add-Type @"
using System; using System.Runtime.InteropServices;
public static class FzSize {
    [StructLayout(LayoutKind.Sequential)] public struct R { public int L, T, Ri, B; }
    [StructLayout(LayoutKind.Sequential)] public struct P { public int X, Y; }
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindow(string c, string n);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr w, int c);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr w, out R r);
    [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr w, out R r);
    [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr w, ref P p);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr w, IntPtr a, int x, int y, int cx, int cy, uint f);
    [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr w);
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
}
"@
[FzSize]::SetProcessDPIAware() | Out-Null
$w = [FzSize]::FindWindow([NullString]::Value, 'Founderizer')
if ($w -eq [IntPtr]::Zero) { 'no window named Founderizer'; exit 1 }
[FzSize]::ShowWindow($w, 9) | Out-Null
Start-Sleep -Milliseconds 400
$scale = [FzSize]::GetDpiForWindow($w) / 96.0
for ($round = 0; $round -lt 3; $round++) {
    $win = New-Object FzSize+R; $cli = New-Object FzSize+R; $at = New-Object FzSize+P
    [FzSize]::GetWindowRect($w, [ref]$win) | Out-Null; [FzSize]::GetClientRect($w, [ref]$cli) | Out-Null; [FzSize]::ClientToScreen($w, [ref]$at) | Out-Null
    $extraW = ($win.Ri - $win.L) - $cli.Ri; $extraH = ($win.B - $win.T) - $cli.B
    $left = $win.L - $at.X; $top = $win.T - $at.Y
    [FzSize]::SetWindowPos($w, [IntPtr]::Zero, $left, $top, [int]($Width * $scale) + $extraW, [int]($Height * $scale) + $extraH, 0x14) | Out-Null
    Start-Sleep -Milliseconds 600
}
$cli = New-Object FzSize+R; $at = New-Object FzSize+P
[FzSize]::GetClientRect($w, [ref]$cli) | Out-Null; [FzSize]::ClientToScreen($w, [ref]$at) | Out-Null
"asked for $Width x $Height; the window's client area is " + [math]::Round($cli.Ri / $scale) + " x " + [math]::Round($cli.B / $scale) + " at scale $scale, at screen pixels $($at.X),$($at.Y) to $($at.X + $cli.Ri),$($at.Y + $cli.B)"
