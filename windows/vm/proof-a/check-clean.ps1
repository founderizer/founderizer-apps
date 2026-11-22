# The checks of a clean PC (clean-pc.sh): no Tailscale and no developer tool, and the three firewall rules of
# ../setup/first-logon.ps1 as outbound blocks that are on, the Tailscale range rule on every card that is there now.
# One line for each fault, and exit 1; else one line.
$faults = @()
if (Test-Path 'C:\Program Files\Tailscale') { $faults += 'Tailscale is installed' }
# Tailscale's state (its node key and its sign-in) stays here after an uninstall: a PC with it is no new PC.
if (Test-Path 'C:\ProgramData\Tailscale') { $faults += "Tailscale's state is in C:\ProgramData\Tailscale" }
if (Get-Service -Name Tailscale -ErrorAction SilentlyContinue) { $faults += 'the Tailscale service exists' }
foreach ($folder in 'C:\Program Files\dotnet', 'C:\Program Files\Microsoft Visual Studio', 'C:\Program Files\Git', 'C:\Program Files\nodejs') {
    if (Test-Path $folder) { $faults += "a developer tool is installed: $folder" }
}
foreach ($rule in 'fz-tailscale-range-only-through-tailscale', 'fz-host-only-test-ports-tcp', 'fz-host-no-udp') {
    $r = Get-NetFirewallRule -Name $rule -ErrorAction SilentlyContinue
    if (-not $r) { $faults += "no firewall rule $rule"; continue }
    if ("$($r.Enabled)" -ne 'True' -or "$($r.Action)" -ne 'Block' -or "$($r.Direction)" -ne 'Outbound') {
        $faults += "the firewall rule $rule is not an outbound block that is on"
    }
}
$range = Get-NetFirewallRule -Name 'fz-tailscale-range-only-through-tailscale' -ErrorAction SilentlyContinue
if ($range) {
    $covered = @(($range | Get-NetFirewallInterfaceFilter).InterfaceAlias)
    foreach ($card in (Get-NetAdapter | Where-Object { $_.InterfaceDescription -notlike 'Tailscale*' } | ForEach-Object Name)) {
        if ($covered -notcontains $card) { $faults += "the card $card is not under fz-tailscale-range-only-through-tailscale" }
    }
}
# The screen of the approved pictures: 2880 x 1800 at 200 % (1440 x 900). A screen of 1024 x 768 at 200 % leaves the
# app's window no room, and it stays black (the first dry run, 22 November 2026).
$screen = Get-CimInstance Win32_VideoController | Select-Object -First 1
if ("$($screen.CurrentHorizontalResolution)x$($screen.CurrentVerticalResolution)" -ne '2880x1800') {
    $faults += "the screen is $($screen.CurrentHorizontalResolution)x$($screen.CurrentVerticalResolution), not 2880x1800"
}
if ($faults) { $faults | ForEach-Object { "fault: $_" }; exit 1 }
'clean: no Tailscale, no developer tool, the three firewall rules on'
