# The build VM's first-logon script (README.md in the folder above).
#
# Windows Setup runs it once, from the setup disc, at the first sign-in of the
# local user "builder" (autounattend.xml, FirstLogonCommands). It:
#   1. installs the virtio drivers on the disc (from UTM's guest tools, signed by Microsoft);
#   2. installs Windows' own OpenSSH server, key only, reachable only from the host; lets no connection to
#      Tailscale's addresses leave by any card but Tailscale's own; and reaches the host at 10.0.2.2 only on the
#      ports of its test servers (58440 to 58459);
#   3. keeps the display and the VM awake, with no lock;
#   4. replaces the throwaway password of the answer file with a random one that
#      never leaves the VM, and makes the user sign in by itself at each start;
#   5. restarts Windows, so that the next start proves the automatic sign-in.
# Its log is C:\ProgramData\fz-setup\first-logon.log.

param([Parameter(Mandatory = $true)][string]$Media)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$state = 'C:\ProgramData\fz-setup'
New-Item -ItemType Directory -Force -Path $state | Out-Null
Start-Transcript -Path (Join-Path $state 'first-logon.log') -Append | Out-Null
$src = Join-Path $Media 'fz-setup'
$user = 'builder'
# The host reaches the VM through QEMU's user network, whose gateway is 10.0.2.2.
$hostAddress = '10.0.2.2'

function Step([string]$name) { Write-Output ("== {0} {1}" -f (Get-Date -Format o), $name) }

try {
    $admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
    Step "user $env:USERNAME, elevated $admin"
    if (-not $admin) { throw 'the first-logon script needs an elevated token' }

    Step 'drivers'
    & pnputil.exe /add-driver (Join-Path $src 'drivers\*.inf') /subdirs /install
    Write-Output "pnputil exit $LASTEXITCODE"

    Step 'network'
    $deadline = (Get-Date).AddMinutes(10)
    while ($true) {
        try {
            $tcp = New-Object System.Net.Sockets.TcpClient
            $tcp.Connect('www.microsoft.com', 443)
            $tcp.Close()
            break
        } catch {
            if ((Get-Date) -gt $deadline) { throw 'no network after 10 minutes' }
            Start-Sleep -Seconds 5
        }
    }
    Get-NetIPAddress -AddressFamily IPv4 | Format-Table -AutoSize InterfaceAlias, IPAddress | Out-String | Write-Output

    Step 'OpenSSH server'
    $cap = Get-WindowsCapability -Online -Name 'OpenSSH.Server*' | Select-Object -First 1
    Write-Output "$($cap.Name): $($cap.State)"
    if ($cap.State -ne 'Installed') {
        for ($i = 1; $i -le 3; $i++) {
            try { Add-WindowsCapability -Online -Name $cap.Name | Out-String | Write-Output; break }
            catch { Write-Output "try $i failed: $_"; if ($i -eq 3) { throw }; Start-Sleep -Seconds 30 }
        }
    }
    # The first start writes the host keys and sshd_config.
    Start-Service sshd
    Stop-Service sshd
    $cfg = 'C:\ProgramData\ssh\sshd_config'
    $old = Get-Content -Path $cfg -Raw
    # sshd takes the first value of each keyword, so these lines win over the defaults below them.
    $head = "# fz-setup: key only`r`nPasswordAuthentication no`r`nKbdInteractiveAuthentication no`r`nPermitEmptyPasswords no`r`nPubkeyAuthentication yes`r`n`r`n"
    Set-Content -Path $cfg -Value ($head + $old) -Encoding ascii -NoNewline
    & "$env:SystemRoot\System32\OpenSSH\sshd.exe" -t
    if ($LASTEXITCODE -ne 0) {
        Write-Output 'sshd -t refused KbdInteractiveAuthentication; leaving it out'
        Set-Content -Path $cfg -Value ($head.Replace("KbdInteractiveAuthentication no`r`n", '') + $old) -Encoding ascii -NoNewline
        & "$env:SystemRoot\System32\OpenSSH\sshd.exe" -t
        if ($LASTEXITCODE -ne 0) { throw 'sshd -t refused the configuration' }
    }
    # An administrator's keys are in administrators_authorized_keys (Match Group administrators).
    $ak = 'C:\ProgramData\ssh\administrators_authorized_keys'
    Copy-Item -Path (Join-Path $src 'authorized_keys') -Destination $ak -Force
    & icacls.exe $ak /inheritance:r /grant '*S-1-5-32-544:F' /grant '*S-1-5-18:F' | Write-Output
    if (-not (Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -DisplayName 'OpenSSH Server (sshd)' -Enabled True `
            -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 | Out-Null
    }
    Set-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -RemoteAddress $hostAddress -Profile Any -Enabled True
    # QEMU's user network carries out through the Mac what the VM's own Tailscale does not: a call to an address of
    # the owner's private network would leave with the Mac's own address there, which the hub knows as the owner's
    # Mac (proved on 14 November 2026: with Tailscale down, an owner page with no key answered 200). So nothing
    # leaves for Tailscale's addresses by this card or any other card that is here now; Tailscale's own card, which
    # comes later, is not one of them (README.md, "The owner's private network").
    $cards = @(Get-NetAdapter | Where-Object { $_.InterfaceDescription -notlike 'Tailscale*' } | ForEach-Object Name)
    Remove-NetFirewallRule -Name 'fz-tailscale-range-only-through-tailscale' -ErrorAction SilentlyContinue
    New-NetFirewallRule -Name 'fz-tailscale-range-only-through-tailscale' `
        -DisplayName 'Founderizer VM: the Tailscale range only through Tailscale' -Direction Outbound -Action Block `
        -Profile Any -RemoteAddress '100.64.0.0/10', 'fd7a:115c:a1e0::/48' -InterfaceAlias $cards | Out-Null
    # The same network gives the VM every service that listens on the host's loopback, at 10.0.2.2: the VM's own
    # tools need only the test servers, which bind to 58440 to 58459 (the test channel 58443, a scratch hub from
    # 58444). SSH comes in from the host and its answers go back on that connection, which no outbound rule stops.
    foreach ($rule in 'fz-host-only-test-ports-tcp', 'fz-host-no-udp') { Remove-NetFirewallRule -Name $rule -ErrorAction SilentlyContinue }
    New-NetFirewallRule -Name 'fz-host-only-test-ports-tcp' -DisplayName 'Founderizer VM: the host only on its test ports' `
        -Direction Outbound -Action Block -Profile Any -RemoteAddress $hostAddress -Protocol TCP `
        -RemotePort '1-58439', '58460-65535' | Out-Null
    New-NetFirewallRule -Name 'fz-host-no-udp' -DisplayName 'Founderizer VM: no UDP to the host' `
        -Direction Outbound -Action Block -Profile Any -RemoteAddress $hostAddress -Protocol UDP | Out-Null
    Set-Service -Name sshd -StartupType Automatic
    Start-Service sshd

    Step 'power'
    & powercfg.exe /hibernate off
    foreach ($s in 'monitor-timeout-ac', 'standby-timeout-ac', 'disk-timeout-ac', 'hibernate-timeout-ac') {
        & powercfg.exe /change $s 0
    }
    & powercfg.exe /setacvalueindex SCHEME_CURRENT SUB_NONE CONSOLELOCK 0
    & powercfg.exe /setactive SCHEME_CURRENT
    # The screen: the virtio-gpu driver (viogpudo, above) takes the size that vm.sh gives QEMU (FZ_VM_SCREEN,
    # 2880 x 1800), and the user's scale is 200% from the next sign-in: 1440 x 900, the approved pictures' size.
    Set-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -Name Win8DpiScaling -Type DWord -Value 1
    Set-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -Name LogPixels -Type DWord -Value 192
    # No "finish setting up your device" page over the desktop at a later sign-in.
    New-Item -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\UserProfileEngagement' -Force | Out-Null
    Set-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\UserProfileEngagement' `
        -Name ScoobeSystemSettingEnabled -Type DWord -Value 0

    Step 'password and automatic sign-in'
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
    $password = [Convert]::ToBase64String($bytes)
    [Array]::Clear($bytes, 0, $bytes.Length)
    Set-LocalUser -Name $user -Password (ConvertTo-SecureString -String $password -AsPlainText -Force) -PasswordNeverExpires $true
    # Winlogon reads the password of an automatic sign-in from this LSA secret when
    # the registry holds none, so the password is never in plain text on the disk.
    [FzLsa]::Store('DefaultPassword', $password)
    $password = $null
    $winlogon = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
    Set-ItemProperty -Path $winlogon -Name AutoAdminLogon -Value '1'
    Set-ItemProperty -Path $winlogon -Name DefaultUserName -Value $user
    Set-ItemProperty -Path $winlogon -Name DefaultDomainName -Value $env:COMPUTERNAME
    foreach ($name in 'DefaultPassword', 'AutoLogonCount') {
        Remove-ItemProperty -Path $winlogon -Name $name -ErrorAction SilentlyContinue
    }

    Step 'done'
    Set-Content -Path (Join-Path $state 'done') -Value (Get-Date -Format o)
    & shutdown.exe /r /t 15 /c 'fz-setup: restart to prove the automatic sign-in'
} catch {
    Write-Output "FAILED: $_"
    Set-Content -Path (Join-Path $state 'failed') -Value "$(Get-Date -Format o) $_"
} finally {
    Stop-Transcript | Out-Null
}
