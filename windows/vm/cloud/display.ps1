# Sets the screen of builder's desktop session on a build machine at Azure (cloud.sh make runs it with vm.sh desktop):
# Azure's console starts at 1024 x 768, where the app's window stayed black on proof A's clean PC. It takes the largest
# mode of the video adapter up to 1920 x 1080 (32 bits) and keeps it for the next sign-ins (CDS_UPDATEREGISTRY). It
# prints the size before and after.
$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class FzDisplay {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct DEVMODE {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string DeviceName;
        public short SpecVersion; public short DriverVersion; public short Size; public short DriverExtra; public int Fields;
        public int PositionX; public int PositionY; public int DisplayOrientation; public int DisplayFixedOutput;
        public short Color; public short Duplex; public short YResolution; public short TTOption; public short Collate;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string FormName;
        public short LogPixels; public int BitsPerPel; public int PelsWidth; public int PelsHeight;
        public int DisplayFlags; public int DisplayFrequency;
        public int ICMMethod; public int ICMIntent; public int MediaType; public int DitherType;
        public int Reserved1; public int Reserved2; public int PanningWidth; public int PanningHeight;
    }
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool EnumDisplaySettings(string device, int mode, ref DEVMODE dm);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int ChangeDisplaySettings(ref DEVMODE dm, int flags);
    // The device stays null here: PowerShell would give an empty string for $null.
    public static DEVMODE? Mode(int number) {
        var d = new DEVMODE();
        d.Size = (short)Marshal.SizeOf(typeof(DEVMODE));
        return EnumDisplaySettings(null, number, ref d) ? d : (DEVMODE?)null;
    }
    public static int Set(int width, int height) {
        var d = Mode(-1).Value;
        d.PelsWidth = width; d.PelsHeight = height;
        d.Fields = 0x80000 | 0x100000;
        return ChangeDisplaySettings(ref d, 1);
    }
}
'@
$current = [FzDisplay]::Mode(-1)
if ($null -eq $current) { throw 'no current display mode' }
"before: $($current.PelsWidth) x $($current.PelsHeight)"
$best = $null
for ($i = 0; ; $i++) {
    $mode = [FzDisplay]::Mode($i)
    if ($null -eq $mode) { break }
    if ($mode.BitsPerPel -ne 32 -or $mode.PelsWidth -gt 1920 -or $mode.PelsHeight -gt 1080) { continue }
    if (-not $best -or ($mode.PelsWidth * $mode.PelsHeight) -gt ($best.PelsWidth * $best.PelsHeight)) { $best = $mode }
}
if (-not $best) { throw 'no display mode of 32 bits up to 1920 x 1080' }
if ($best.PelsWidth -ne $current.PelsWidth -or $best.PelsHeight -ne $current.PelsHeight) {
    $result = [FzDisplay]::Set($best.PelsWidth, $best.PelsHeight)
    if ($result -ne 0) { throw "ChangeDisplaySettings gave $result" }
}
$after = [FzDisplay]::Mode(-1)
"after: $($after.PelsWidth) x $($after.PelsHeight)"
