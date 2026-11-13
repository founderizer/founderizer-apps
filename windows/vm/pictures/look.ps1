# The VM's desktop for the pictures (README.md, "Pictures"), in the signed-in user's desktop session (vm.sh desktop):
# the taskbar hides by itself, so it does not cover the foot of the window, and Windows' animation effects go on
# (-AnimationsOn, for the frames of motion) or off (for still pictures that compare pixel by pixel). The app follows a
# change of the animation effects at once.
#
#   vm.sh desktop '& C:\fz\setup\look.ps1 -AnimationsOn'
param([switch]$AnimationsOn)
Add-Type -TypeDefinition @"
using System; using System.Runtime.InteropServices;
public static class FzLook {
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int l, t, r, b; }
  [StructLayout(LayoutKind.Sequential)] public struct APPBARDATA { public int cbSize; public IntPtr hWnd; public uint uCallbackMessage; public uint uEdge; public RECT rc; public IntPtr lParam; }
  [DllImport("shell32.dll")] public static extern IntPtr SHAppBarMessage(uint msg, ref APPBARDATA data);
  [DllImport("user32.dll")] public static extern IntPtr FindWindow(string cls, string name);
  [DllImport("user32.dll")] public static extern bool SystemParametersInfo(uint action, uint param, IntPtr value, uint flags);
  // ABM_SETSTATE with ABS_AUTOHIDE
  public static void AutoHide() { var d = new APPBARDATA(); d.cbSize = Marshal.SizeOf(d); d.hWnd = FindWindow("Shell_TrayWnd", null); d.lParam = (IntPtr)1; SHAppBarMessage(10, ref d); }
  // SPI_SETCLIENTAREAANIMATION, saved to the profile and sent to every window
  public static void Animations(bool on) { SystemParametersInfo(0x1043, 0, on ? (IntPtr)1 : IntPtr.Zero, 3); }
}
"@
[FzLook]::AutoHide()
[FzLook]::Animations($AnimationsOn.IsPresent)
"taskbar hides by itself; animation effects " + $(if ($AnimationsOn) { "on" } else { "off" })
