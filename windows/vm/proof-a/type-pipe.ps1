# The keys of secret.sh on a clean PC that has no QEMU keyboard (the x64 PC at Azure): in the signed-in user's desktop
# session (a scheduled task that type-task.ps1 starts), it opens a named pipe that only this user and the administrators
# reach, takes one line from it, and types it into the field -Field (an automation id) with Windows' own Unicode key
# events (SendInput), as a person types, then Enter with -Enter. The line comes on SSH's standard input to the pipe's
# other end: it is in no command line, no file and no log.
#
# It types only while the focus is on that field of Founderizer's window: before the first key it reads UI Automation's
# focused element, and before each key the window in front; at the first change it stops. One key can still reach a
# window that comes to the front between that check and the key: the typer fails closed (its words say fewer keys than
# the value, and secret.sh keeps the mark and logs where the focus is). After the keys it reads the
# focused element again and the field's length (never its words): Enter goes only when the focus is still on that field
# of Founderizer.App and the field holds every character (only a password box gives no length: "unknown"; an element
# with no value gives "none"). It writes to -State only
# "listening", then one of:
#   "typed N of N, Enter"
#   "typed N of N; no Enter: the focus is on <program>/<id>" or "...; no Enter: the field holds L of N"
#   "typed N of N; focus <program>/<id>; length <L|unknown|none>" (no -Enter)
#   "typed k of N; front <program>"                                (the window in front changed: it stopped)
#   "refused: <reason>" (nothing typed) or "failed: <reason>"
param([Parameter(Mandatory = $true)][string]$Pipe, [Parameter(Mandatory = $true)][string]$State,
      [Parameter(Mandatory = $true)][string]$Field, [switch]$Enter)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class FzKeys {
    [StructLayout(LayoutKind.Sequential)] struct KEYBDINPUT { public ushort Vk; public ushort Scan; public uint Flags; public uint Time; public IntPtr Extra; }
    [StructLayout(LayoutKind.Explicit, Size = 40)] struct INPUT { [FieldOffset(0)] public uint Type; [FieldOffset(8)] public KEYBDINPUT Key; }
    [DllImport("user32.dll", SetLastError = true)] static extern uint SendInput(uint count, INPUT[] inputs, int size);
    static void Send(ushort vk, ushort scan, uint flags) {
        var input = new INPUT[1];
        input[0].Type = 1;
        input[0].Key.Vk = vk; input[0].Key.Scan = scan; input[0].Key.Flags = flags;
        if (SendInput(1, input, Marshal.SizeOf(typeof(INPUT))) != 1) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
        System.Threading.Thread.Sleep(15);
    }
    public static void Key(char c) { Send(0, c, 0x0004); Send(0, c, 0x0004 | 0x0002); }
    public static void Enter() { Send(0x0D, 0, 0); Send(0x0D, 0, 0x0002); }
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
    public static uint FrontProcess() { uint pid; GetWindowThreadProcessId(GetForegroundWindow(), out pid); return pid; }
}
'@
# type-task.ps1 reads -State while this writes it. Each state goes to a new file first, which then takes the state
# file's place in one step (File.Replace; File.Move for the first one): a read sees a whole state, never a part of one.
# A step that meets a read is tried again. File.Replace takes no backup: [NullString]::Value, because PowerShell passes
# $null to a string parameter as "", which File.Replace refuses ("The path is not of a legal form", the run of
# 23 November 2026).
function Say([string]$text) {
    $new = "$State.new"
    for ($i = 0; ; $i++) {
        try {
            [System.IO.File]::WriteAllText($new, $text)
            if ([System.IO.File]::Exists($State)) { [System.IO.File]::Replace($new, $State, [NullString]::Value) }
            else { [System.IO.File]::Move($new, $State) }
            return
        } catch { if ($i -ge 40) { throw }; Start-Sleep -Milliseconds 50 }
    }
}
function ProgramOf([int]$id) { try { (Get-Process -Id $id).ProcessName } catch { 'unknown' } }
function Front { ProgramOf ([int][FzKeys]::FrontProcess()) }
# The focused element as "<program>/<automation id>", and its length (never its words): "unknown" for a password box,
# "none" for an element with no value.
function Focus {
    $element = [System.Windows.Automation.AutomationElement]::FocusedElement
    if (-not $element) { return @{ where = 'none/none'; length = 'none' } }
    $current = $element.Current
    $length = 'unknown'
    if (-not $current.IsPassword) {
        $length = 'none'
        $pattern = $null
        if ($element.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref]$pattern)) {
            $length = [string]$pattern.Current.Value.Length
        }
    }
    @{ where = (ProgramOf $current.ProcessId) + '/' + $current.AutomationId; length = $length }
}
$expected = "Founderizer.App/$Field"
$security = New-Object System.IO.Pipes.PipeSecurity
$me = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
$admins = New-Object System.Security.Principal.SecurityIdentifier 'S-1-5-32-544'
foreach ($who in $me, $admins) {
    $security.AddAccessRule((New-Object System.IO.Pipes.PipeAccessRule($who, 'ReadWrite', 'Allow')))
}
$server = New-Object System.IO.Pipes.NamedPipeServerStream($Pipe, 'In', 1, 'Byte', 'Asynchronous', 1024, 1024, $security)
try {
    Say 'listening'
    $wait = $server.BeginWaitForConnection($null, $null)
    if (-not $wait.AsyncWaitHandle.WaitOne([TimeSpan]::FromMinutes(5))) { throw 'no line in 5 minutes' }
    $server.EndWaitForConnection($wait)
    $reader = New-Object System.IO.StreamReader($server)
    $line = $reader.ReadLine()
    if (-not $line) { throw 'an empty line' }
    $count = $line.Length
    $before = Focus
    if ($before.where -ne $expected) {
        $line = $null
        Say "refused: the focus is on $($before.where), not on $expected"
        return
    }
    $typed = 0
    foreach ($c in $line.ToCharArray()) {
        $front = Front
        if ($front -ne 'Founderizer.App') { break }
        [FzKeys]::Key($c)
        $typed++
    }
    $line = $null
    if ($typed -lt $count) {
        Say "typed $typed of $count; front $front"
        return
    }
    $after = Focus
    $full = ($after.length -eq 'unknown') -or ($after.length -eq [string]$count)
    if ($Enter) {
        if ($after.where -ne $expected) { $said = "typed $count of $count; no Enter: the focus is on $($after.where)" }
        elseif (-not $full) { $said = "typed $count of $count; no Enter: the field holds $($after.length) of $count" }
        else { [FzKeys]::Enter(); $said = "typed $count of $count, Enter" }
    } else {
        $said = "typed $count of $count; focus $($after.where); length $($after.length)"
    }
    Say $said
} catch {
    Say "failed: $($_.Exception.Message)"
} finally {
    $server.Dispose()
}
