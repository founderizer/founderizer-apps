# Presses keys in the signed-in user's desktop session of a build machine at Azure (cloud.sh keys runs it with vm.sh
# desktop), with Windows' own key events (SendInput), as vm.sh keys presses them through QEMU in the Mac's VM. The
# caller sets $names: the keys, separated by spaces, each one QEMU's name (ret, spc, esc, tab, left, a, 1, f4 ...) or a
# chord of names joined by "-" (ctrl-a, alt-f4, shift-tab, meta_l-r). Every name is checked before the first key goes. It
# prints the program in front before and after the keys. Windows gives no key of a limited session to a window of an
# elevated program (UIPI).
$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class FzPress {
    [StructLayout(LayoutKind.Sequential)] struct KEYBDINPUT { public ushort Vk; public ushort Scan; public uint Flags; public uint Time; public IntPtr Extra; }
    [StructLayout(LayoutKind.Explicit, Size = 40)] struct INPUT { [FieldOffset(0)] public uint Type; [FieldOffset(8)] public KEYBDINPUT Key; }
    [DllImport("user32.dll", SetLastError = true)] static extern uint SendInput(uint count, INPUT[] inputs, int size);
    [DllImport("user32.dll")] static extern uint MapVirtualKey(uint code, uint type);
    public static void Send(ushort vk, bool extended, bool up) {
        var input = new INPUT[1];
        input[0].Type = 1;
        input[0].Key.Vk = vk;
        input[0].Key.Scan = (ushort)MapVirtualKey(vk, 0);
        input[0].Key.Flags = (extended ? 0x0001u : 0u) | (up ? 0x0002u : 0u);
        if (SendInput(1, input, Marshal.SizeOf(typeof(INPUT))) != 1) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
        System.Threading.Thread.Sleep(20);
    }
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
    public static uint FrontProcess() { uint pid; GetWindowThreadProcessId(GetForegroundWindow(), out pid); return pid; }
}
'@
function Front { try { (Get-Process -Id ([int][FzPress]::FrontProcess())).ProcessName } catch { 'none' } }
# QEMU's names and Windows' virtual keys; "+" marks a key that Windows sends as an extended key.
$table = @{
    ret = 0x0D; spc = 0x20; esc = 0x1B; tab = 0x09; backspace = 0x08; delete = '+0x2E'; insert = '+0x2D'
    home = '+0x24'; end = '+0x23'; pgup = '+0x21'; pgdn = '+0x22'
    left = '+0x25'; up = '+0x26'; right = '+0x27'; down = '+0x28'
    shift = 0x10; ctrl = 0x11; alt = 0x12; meta_l = '+0x5B'; menu = '+0x5D'
    minus = 0xBD; equal = 0xBB; comma = 0xBC; dot = 0xBE; slash = 0xBF; semicolon = 0xBA; apostrophe = 0xDE
    bracket_left = 0xDB; bracket_right = 0xDD; backslash = 0xDC; grave_accent = 0xC0
}
foreach ($c in [char[]]'abcdefghijklmnopqrstuvwxyz0123456789') { $table[[string]$c] = [int][char]::ToUpperInvariant($c) }
foreach ($n in 1..12) { $table["f$n"] = 0x6F + $n }
function KeyOf([string]$name) {
    if (-not $table.ContainsKey($name)) { throw "not a key name: $name" }
    $value = [string]$table[$name]
    $extended = $value.StartsWith('+')
    @{ vk = [uint16][Convert]::ToInt32($value.TrimStart('+'), $(if ($value -match '0x') { 16 } else { 10 })); extended = $extended }
}
$chords = @(foreach ($word in ($names -split '\s+' | Where-Object { $_ })) { , @($word -split '-' | ForEach-Object { KeyOf $_ }) })
if (-not $chords.Count) { throw 'no key names' }
"front before: $(Front)"
foreach ($chord in $chords) {
    foreach ($k in $chord) { [FzPress]::Send($k.vk, $k.extended, $false) }
    [array]::Reverse($chord)
    foreach ($k in $chord) { [FzPress]::Send($k.vk, $k.extended, $true) }
    Start-Sleep -Milliseconds 200
}
"pressed $($chords.Count); front after: $(Front)"
