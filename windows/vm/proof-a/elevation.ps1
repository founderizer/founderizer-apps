# The token of each running process of one program: its elevation type, as Windows gives it (1: default, no split
# token; 2: full, elevated; 3: limited, a user's token, as a person's start gives an administrator). Proof A starts the
# setup and the app through explorer, so that they have builder's limited token (type 3) as on a person's PC: on the
# Azure PC a task of vm.sh desktop has the full token, and a program that it starts directly runs elevated (type 2).
# It reads no window, no words and no command line. Run it with vm.sh run (an administrator reads any process). With
# -Want, it ends with exit 1 when no process of that program runs or when one has another type:
#
#   app/windows/vm/vm.sh run '& C:\fz\proof-a\elevation.ps1 -Name Founderizer.App -Want 3'
param([Parameter(Mandatory = $true)][string]$Name, [ValidateSet(0, 1, 2, 3)][int]$Want = 0)
$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class FzToken {
    [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
    [DllImport("advapi32.dll", SetLastError = true)] static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);
    [DllImport("advapi32.dll", SetLastError = true)] static extern bool GetTokenInformation(IntPtr token, int infoClass, out int info, int length, out int returned);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
    // PROCESS_QUERY_LIMITED_INFORMATION, TOKEN_QUERY, TokenElevationType (18).
    public static int ElevationType(int pid) {
        IntPtr process = OpenProcess(0x1000, false, pid);
        if (process == IntPtr.Zero) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
        try {
            IntPtr token;
            if (!OpenProcessToken(process, 0x0008, out token)) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
            try {
                int type, returned;
                if (!GetTokenInformation(token, 18, out type, 4, out returned)) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
                return type;
            } finally { CloseHandle(token); }
        } finally { CloseHandle(process); }
    }
}
'@
$words = @{ 1 = "default: an administrator's full rights with no split"; 2 = 'full (elevated)'; 3 = 'limited' }
$found = @(Get-Process -Name $Name -ErrorAction SilentlyContinue)
if (-not $found) { "no process $Name"; if ($Want) { exit 1 }; return }
$other = 0
foreach ($p in $found) {
    $type = [FzToken]::ElevationType($p.Id)
    "{0} {1}: elevation type {2}, {3}" -f $Name, $p.Id, $type, $words[$type]
    if ($Want -and $type -ne $Want) { $other++ }
}
if ($Want) {
    if ($other) { "NOT as wanted: $other of $($found.Count) processes of $Name have another type than $Want"; exit 1 }
    "as wanted: each of the $($found.Count) processes of $Name has type $Want"
}
