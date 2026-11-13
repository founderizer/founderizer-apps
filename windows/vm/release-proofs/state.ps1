# state.ps1: the install's state, in lines that a later state can be compared with.
param([switch]$Hashes)
$root = Join-Path $env:LOCALAPPDATA 'Programs\Founderizer'
"install folder: " + $(if (Test-Path $root) { $root } else { '(none)' })
if (Test-Path $root) {
    "  top: " + ((Get-ChildItem -Force $root | Sort-Object Name | ForEach-Object { $_.Name + $(if ($_.PSIsContainer) { '\' } else { '' }) }) -join ', ')
    "  builds: " + ((Get-ChildItem -Directory (Join-Path $root 'builds') -ErrorAction SilentlyContinue | Sort-Object { [long]$_.Name } | ForEach-Object Name) -join ', ')
    foreach ($p in 'current', 'previous', 'next', 'failed') {
        $f = Join-Path $root $p
        "  ${p}: " + $(if (Test-Path $f) { ((Get-Content $f) -join ' ') } else { '(none)' })
    }
    "  updates: " + ((Get-ChildItem -Force (Join-Path $root 'updates') -ErrorAction SilentlyContinue | ForEach-Object Name) -join ', ')
}
$link = Join-Path ([Environment]::GetFolderPath('Programs')) 'Founderizer.lnk'
if (Test-Path $link) {
    $s = (New-Object -ComObject WScript.Shell).CreateShortcut($link)
    "Start menu entry: $link -> $($s.TargetPath) (in $($s.WorkingDirectory))"
    $app = Get-StartApps | Where-Object Name -eq 'Founderizer'
    "  Start's apps: " + $(if ($app) { ($app | ForEach-Object { "$($_.Name), AppID $($_.AppID)" }) -join '; ' } else { '(none)' })
} else { "Start menu entry: (none)" }
$key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\Founderizer'
if (Test-Path $key) {
    $v = Get-ItemProperty $key
    "Windows' list of installed apps: $($v.DisplayName) $($v.DisplayVersion), by $($v.Publisher), $($v.EstimatedSize) KB, installed $($v.InstallDate)"
    "  UninstallString: $($v.UninstallString)"
    "  InstallLocation: $($v.InstallLocation)"
} else { "Windows' list of installed apps: (no entry)" }
$apps = @(Get-Process Founderizer.App -ErrorAction SilentlyContinue)
"app processes: " + $(if ($apps.Count) { ($apps | ForEach-Object { "$($_.Id) $($_.Path)" }) -join '; ' } else { '(none)' })
$launchers = @(Get-Process Founderizer -ErrorAction SilentlyContinue)
"launcher processes: " + $(if ($launchers.Count) { ($launchers | ForEach-Object { "$($_.Id) $($_.Path)" }) -join '; ' } else { '(none)' })
if ($Hashes) {
    $data = Join-Path $env:LOCALAPPDATA 'Founderizer'
    "data folder (store and key): " + $(if (Test-Path $data) { $data } else { '(none)' })
    if (Test-Path $data) {
        Get-ChildItem -Recurse -File $data | Sort-Object FullName | ForEach-Object {
            "  " + $_.FullName.Substring($data.Length + 1) + " " + $_.Length + " " + (Get-FileHash -Algorithm SHA256 $_.FullName).Hash.Substring(0, 16)
        }
    }
}
