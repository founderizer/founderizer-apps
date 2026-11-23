# The setup of a Windows build machine at Azure (cloud.sh make runs it once with Azure's run command, as SYSTEM). The
# caller gives three values in base64: the SSH public key of this Mac, the one address that may reach SSH, and the text
# of idle.ps1. It does what ../proof-a/azure-pc-setup.ps1 does for proof A's PC, with no test certificate and no audit:
# Windows' OpenSSH server with that key only and from that address only, and the automatic sign-in of the user "builder"
# with a new password that is made here and never leaves the machine (an LSA secret, never the registry), and new SSH
# host keys (the image's are the same on every machine of the image). It also
# installs the machine's idle rule (idle.ps1, a task of SYSTEM every 10 minutes), keeps the display on with no lock, and
# keeps Defender's scan out of the build folders. Then Windows restarts, and the desktop session of "builder" starts by
# itself. No RDP is opened. It prints the SSH host key ("hostkey ...").
param([Parameter(Mandatory = $true)][string]$Key64, [Parameter(Mandatory = $true)][string]$From64,
      [Parameter(Mandatory = $true)][string]$Idle64)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$user = 'builder'
$key = [Text.Encoding]::ASCII.GetString([Convert]::FromBase64String($Key64)).Trim()
$from = [Text.Encoding]::ASCII.GetString([Convert]::FromBase64String($From64)).Trim()
if ($key -notmatch '^ssh-ed25519 [A-Za-z0-9+/=]+( \S+)?$') { throw 'the key is not an ed25519 public key' }
if ($from -notmatch '^[0-9]{1,3}(\.[0-9]{1,3}){3}$') { throw 'the address is not an IPv4 address' }
$folder = 'C:\ProgramData\fz-cloud'
New-Item -ItemType Directory -Force -Path $folder, 'C:\fz\src', 'C:\fz\out', 'C:\fz\setup', 'C:\fz\incoming' | Out-Null
# Only the administrators and SYSTEM write the folder of the idle rule: SYSTEM runs its script.
& icacls.exe $folder /inheritance:r /grant 'Administrators:(OI)(CI)F' /grant 'SYSTEM:(OI)(CI)F' | Out-Null
if ($LASTEXITCODE -ne 0) { throw "icacls could not set the rights of $folder" }

# OpenSSH: Windows Server 2025 has the server with Windows, its service off; older images add the capability.
if (-not (Get-Service -Name sshd -ErrorAction SilentlyContinue)) {
    $capability = Get-WindowsCapability -Online -Name 'OpenSSH.Server*' | Select-Object -First 1
    Add-WindowsCapability -Online -Name $capability.Name | Out-Null
}
Set-Service -Name sshd -StartupType Automatic
Start-Service sshd
$keys = 'C:\ProgramData\ssh\administrators_authorized_keys'
Set-Content -Path $keys -Value $key -Encoding ascii
& icacls.exe $keys /inheritance:r /grant 'Administrators:F' /grant 'SYSTEM:F' | Out-Null
$config = 'C:\ProgramData\ssh\sshd_config'
$lines = Get-Content -Path $config | Where-Object { $_ -notmatch '^\s*#?\s*(PasswordAuthentication|KbdInteractiveAuthentication)\s' }
Set-Content -Path $config -Value (@('PasswordAuthentication no', 'KbdInteractiveAuthentication no') + $lines) -Encoding ascii
# The image's host keys were made when Microsoft built the image (12 November 2026 on fz-build-1), so every machine of
# that image holds the same private keys, and a check of them proves nothing: new ones, made here. (Windows can keep a
# file's old creation time when a file of the same name comes back at once: the key itself is new.)
Stop-Service sshd
Remove-Item -Path 'C:\ProgramData\ssh\ssh_host_*' -Force
& "$env:WINDIR\System32\OpenSSH\ssh-keygen.exe" -A
if ($LASTEXITCODE -ne 0) { throw "ssh-keygen -A failed: exit $LASTEXITCODE" }
foreach ($file in Get-ChildItem -Path 'C:\ProgramData\ssh\ssh_host_*_key') {
    & icacls.exe $file.FullName /inheritance:r /grant 'SYSTEM:F' /grant 'Administrators:F' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "icacls could not set the rights of $($file.Name)" }
}
Start-Service sshd
# The host key goes back through Azure's run command: cloud.sh writes known_hosts from it.
"hostkey " + (Get-Content -Path 'C:\ProgramData\ssh\ssh_host_ed25519_key.pub' -Raw).Trim()
$rule = Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue
if (-not $rule) {
    New-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -DisplayName 'OpenSSH Server (sshd)' -Direction Inbound -Protocol TCP `
        -LocalPort 22 -Action Allow | Out-Null
}
Set-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -RemoteAddress $from -Profile Any -Enabled True

# The automatic sign-in, so that a desktop session exists for the app's window and the pictures.
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class FzLsa {
    [StructLayout(LayoutKind.Sequential)]
    struct LsaString { public ushort Length; public ushort MaximumLength; public IntPtr Buffer; }
    [StructLayout(LayoutKind.Sequential)]
    struct LsaAttributes { public int Length; public IntPtr RootDirectory; public IntPtr ObjectName;
        public uint Attributes; public IntPtr SecurityDescriptor; public IntPtr SecurityQualityOfService; }
    [DllImport("advapi32.dll")] static extern uint LsaOpenPolicy(IntPtr system, ref LsaAttributes attributes, uint access, out IntPtr policy);
    [DllImport("advapi32.dll")] static extern uint LsaStorePrivateData(IntPtr policy, ref LsaString key, ref LsaString data);
    [DllImport("advapi32.dll")] static extern uint LsaClose(IntPtr policy);
    [DllImport("advapi32.dll")] static extern int LsaNtStatusToWinError(uint status);
    static LsaString Make(string s) {
        var r = new LsaString();
        r.Buffer = Marshal.StringToHGlobalUni(s);
        r.Length = (ushort)(s.Length * 2);
        r.MaximumLength = (ushort)(s.Length * 2 + 2);
        return r;
    }
    public static void Store(string name, string value) {
        var attributes = new LsaAttributes();
        attributes.Length = Marshal.SizeOf(attributes);
        IntPtr policy;
        uint status = LsaOpenPolicy(IntPtr.Zero, ref attributes, 0x000F0FFF, out policy);
        if (status != 0) throw new System.ComponentModel.Win32Exception(LsaNtStatusToWinError(status));
        var key = Make(name);
        var data = Make(value);
        try {
            status = LsaStorePrivateData(policy, ref key, ref data);
            if (status != 0) throw new System.ComponentModel.Win32Exception(LsaNtStatusToWinError(status));
        } finally {
            Marshal.ZeroFreeGlobalAllocUnicode(data.Buffer);
            Marshal.FreeHGlobal(key.Buffer);
            LsaClose(policy);
        }
    }
}
'@
$bytes = New-Object byte[] 24
[Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
$password = 'Fz-' + [Convert]::ToBase64String($bytes)
[Array]::Clear($bytes, 0, $bytes.Length)
Set-LocalUser -Name $user -Password (ConvertTo-SecureString -String $password -AsPlainText -Force) -PasswordNeverExpires $true
[FzLsa]::Store('DefaultPassword', $password)
$password = $null
$winlogon = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
Set-ItemProperty -Path $winlogon -Name AutoAdminLogon -Value '1'
Set-ItemProperty -Path $winlogon -Name DefaultUserName -Value $user
Set-ItemProperty -Path $winlogon -Name DefaultDomainName -Value $env:COMPUTERNAME
foreach ($name in 'DefaultPassword', 'AutoLogonCount') { Remove-ItemProperty -Path $winlogon -Name $name -ErrorAction SilentlyContinue }
# Server Manager opens at each sign-in of an administrator on Windows Server: not on this machine's desktop.
New-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\ServerManager' -Name DoNotOpenServerManagerAtLogon -PropertyType DWord -Value 1 -Force | Out-Null
# Windows' page "Send diagnostic data to Microsoft" covers the whole desktop at each sign-in until somebody answers it
# (seen on fz-build-1, 23 November 2026): Windows' own policy turns the page off, and the diagnostic data is "Required
# only", the smaller of the page's two choices.
foreach ($pair in @(@('HKLM:\SOFTWARE\Policies\Microsoft\Windows\OOBE', 'DisablePrivacyExperience'),
                    @('HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection', 'AllowTelemetry'))) {
    New-Item -Path $pair[0] -Force | Out-Null
    New-ItemProperty -Path $pair[0] -Name $pair[1] -PropertyType DWord -Value 1 -Force | Out-Null
}
# No Remote Desktop: the network security group has no rule for it, and Windows takes no such connection either.
Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections -Type DWord -Value 1
# Windows' administrator question: no session can press it here (no keyboard of a person, and the question is on the
# secure desktop), so an administrator's rise goes on with no question (ConsentPromptBehaviorAdmin 0); UAC stays on
# (EnableLUA 1), and the built-in Administrator that Azure renames to builder gets Admin Approval Mode
# (FilterAdministratorToken 1), so builder's own desktop (explorer) and what it starts keep a user's limited rights, as
# on a real PC. Measured on fz-build-2 (23 November 2026, after a restart): SSH still has the full token, with no
# LocalAccountTokenFilterPolicy; and a scheduled task of the desktop session (vm.sh desktop) also runs with the full
# token, so an app that it starts directly is elevated: README.md, "Use it", starts the app through explorer.
$policy = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
Set-ItemProperty -Path $policy -Name ConsentPromptBehaviorAdmin -Type DWord -Value 0
Set-ItemProperty -Path $policy -Name EnableLUA -Type DWord -Value 1
Set-ItemProperty -Path $policy -Name FilterAdministratorToken -Type DWord -Value 1

# The display stays on and the session is never locked, for the pictures and the keys.
& powercfg.exe /hibernate off
foreach ($s in 'monitor-timeout-ac', 'standby-timeout-ac', 'disk-timeout-ac', 'hibernate-timeout-ac') { & powercfg.exe /change $s 0 }
& powercfg.exe /setacvalueindex SCHEME_CURRENT SUB_NONE CONSOLELOCK 0
& powercfg.exe /setactive SCHEME_CURRENT
# The builds: Defender does not scan the sources, the builds and NuGet's packages on each read (the machine holds no
# secret and takes its sources only from the builder's own worktree).
Add-MpPreference -ExclusionPath 'C:\fz', "C:\Users\$user\.nuget", "C:\Users\$user\AppData\Local\NuGet", "$env:ProgramFiles\dotnet"

# The idle rule: idle.ps1 as SYSTEM every 10 minutes and at each start.
$idle = Join-Path $folder 'idle.ps1'
[IO.File]::WriteAllBytes($idle, [Convert]::FromBase64String($Idle64))
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$idle`""
$every = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 10)
$boot = New-ScheduledTaskTrigger -AtStartup
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 5) -MultipleInstances IgnoreNew
Register-ScheduledTask -TaskName 'fz-cloud-idle' -Action $action -Trigger $every, $boot -Principal $principal -Settings $settings -Force | Out-Null

Set-Content -Path (Join-Path $folder 'done') -Value (Get-Date -Format o)
& shutdown.exe /r /t 20 /c 'fz-cloud: restart for the automatic sign-in'
'set up: SSH by key from one address, the automatic sign-in of builder, the idle rule; Windows restarts in 20 seconds'
