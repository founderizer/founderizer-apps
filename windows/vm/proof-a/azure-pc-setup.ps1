# The setup of the x64 clean PC at Azure (azure-pc-make.sh runs it once with Azure's run command, as SYSTEM). The
# caller gives three public values in base64: the SSH public key of this Mac, the one address that may reach SSH, and
# the build VM's test certificate (its public part). It does what ../setup/first-logon.ps1 does in a VM on this Mac:
# Windows' OpenSSH server with that key only and from that address only, the test certificate trusted, and the
# automatic sign-in of the user "builder" with a new password that is made here and never leaves the VM (an LSA secret,
# never the registry). Then Windows restarts, and the desktop session of "builder" starts by itself. No RDP is opened.
# It prints the SSH host key ("hostkey ..."), lets an administrator's rise go on with no question (UAC stays on), and
# turns on the audit of process creation, so that each elevated start of the run is in Windows' security log.
param([Parameter(Mandatory = $true)][string]$Key64, [Parameter(Mandatory = $true)][string]$From64,
      [Parameter(Mandatory = $true)][string]$Cer64)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$user = 'builder'
$key = [Text.Encoding]::ASCII.GetString([Convert]::FromBase64String($Key64)).Trim()
$from = [Text.Encoding]::ASCII.GetString([Convert]::FromBase64String($From64)).Trim()
if ($key -notmatch '^ssh-ed25519 [A-Za-z0-9+/=]+( \S+)?$') { throw 'the key is not an ed25519 public key' }
if ($from -notmatch '^[0-9]{1,3}(\.[0-9]{1,3}){3}$') { throw 'the address is not an IPv4 address' }
New-Item -ItemType Directory -Force -Path 'C:\ProgramData\fz-proof-a', 'C:\fz\proof-a', 'C:\fz\setup' | Out-Null

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
Restart-Service sshd
# The host key goes back through Azure's run command: azure-pc-make.sh writes known_hosts from it.
"hostkey " + (Get-Content -Path 'C:\ProgramData\ssh\ssh_host_ed25519_key.pub' -Raw).Trim()
$rule = Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue
if (-not $rule) {
    New-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -DisplayName 'OpenSSH Server (sshd)' -Direction Inbound -Protocol TCP `
        -LocalPort 22 -Action Allow | Out-Null
}
Set-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -RemoteAddress $from -Profile Any -Enabled True

# The build VM's test certificate, for the setup's signature (only the public part comes in).
$cer = 'C:\ProgramData\fz-proof-a\founderizer-test-signing.cer'
[IO.File]::WriteAllBytes($cer, [Convert]::FromBase64String($Cer64))
$certificate = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 $cer
if ($certificate.HasPrivateKey) { throw 'the certificate holds a private key' }
foreach ($store in 'Root', 'TrustedPublisher') {
    & certutil.exe -f -addstore $store $cer | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "certutil could not add the test certificate to $store" }
}

# The automatic sign-in, so that a desktop session exists for the app's window, the pictures and the watcher.
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
# Server Manager opens at each sign-in of an administrator on Windows Server: not on this PC's desktop.
New-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\ServerManager' -Name DoNotOpenServerManagerAtLogon -PropertyType DWord -Value 1 -Force | Out-Null
# Windows' administrator question: no session can press it on this PC (it has no QEMU keyboard, and the question is on
# the secure desktop). An administrator's rise goes on with no question here (ConsentPromptBehaviorAdmin 0); UAC stays on
# (EnableLUA 1), so the app and the desktop session keep their limited rights. Run 1 on the ARM VM proves the question.
$policy = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
Set-ItemProperty -Path $policy -Name ConsentPromptBehaviorAdmin -Type DWord -Value 0
Set-ItemProperty -Path $policy -Name EnableLUA -Type DWord -Value 1
# Azure makes the admin user from the built-in Administrator (its SID ends in -500), whose Admin Approval Mode is off on
# Windows Server: it would get no limited token at all, so nothing would start limited and no start would count as a
# rise. Admin Approval Mode for that account (FilterAdministratorToken 1) gives it the split token of every other
# administrator; the restart at the end of this setup puts it in force.
Set-ItemProperty -Path $policy -Name FilterAdministratorToken -Type DWord -Value 1
$sid = (Get-LocalUser -Name $user).SID.Value
"account: $user has the SID ending in -" + ($sid -split '-')[-1] + $(if ($sid -match '-500$') { ' (the built-in Administrator, renamed)' } else { '' })
# What that hides: an elevation that must not happen. Windows' audit of process creation records each start, with its
# token's elevation (event 4688), and azure-pc-elevated.ps1 lists the elevated ones of the run for its record.
& auditpol.exe /set /subcategory:"Process Creation" /success:enable | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'the audit of process creation was not turned on' }
Set-Content -Path 'C:\ProgramData\fz-proof-a\done' -Value (Get-Date -Format o)
& shutdown.exe /r /t 20 /c 'fz-proof-a: restart for the automatic sign-in'
'set up: SSH by key from one address, the test certificate trusted, the automatic sign-in of builder; Windows restarts in 20 seconds'
