#!/bin/bash
# The Windows build VM on a Mac (README.md in this folder): Windows 11 for ARM64
# in UTM's own QEMU, run with no window, driven over SSH with a key.
#
#   vm.sh create              make the VM from the downloads and install Windows (once)
#   vm.sh start               start the VM and wait until SSH answers
#   vm.sh stop                shut Windows down and wait until QEMU has ended
#   vm.sh status              say whether the VM runs, and its uptime
#   vm.sh run <command>       run a PowerShell command in the VM (an SSH session)
#   vm.sh copy <from> <to>    copy files with scp; write the VM's side as vm:<path>
#   vm.sh desktop <command>   run a PowerShell command in the signed-in user's desktop
#                             session, wait for it, and print its output
#   vm.sh picture [file.png]  a picture of the Windows desktop, taken in the VM
#   vm.sh screen [file.png]   a picture of the VM's display, taken by QEMU (also before Windows runs)
#   vm.sh keys <key...>       press keys through QEMU (QEMU key names: ret, spc, esc, ...)
#
# Settings, each with a default:
#   FZ_VM_DIR       the VM's folder, outside any repository ($HOME/VMs/founderizer-windows)
#   FZ_VM_KEY       the SSH key of this Mac for the VM ($HOME/.ssh/founderizer-windows-vm)
#   FZ_VM_PORT      the port on 127.0.0.1 that reaches the VM's SSH (52222)
#   FZ_VM_UTM       UTM's app (/Applications/UTM.app); vm.sh runs only with UTM 5.0.8
#   FZ_VM_CPUS, FZ_VM_MEMORY_MB, FZ_VM_DISK      6, 16384, 100G
#   FZ_VM_SCREEN    the size of the VM's screen, as the display driver offers it (2880x1800: 1440 x 900 at 200%,
#                   the size of the approved pictures of the Windows app)
#   FZ_VM_WINDOWS_ISO, FZ_VM_TOOLS_ISO           the downloads that create uses
set -euo pipefail
# Every file, folder and socket that vm.sh or QEMU makes is the user's alone.
umask 077

here="$(cd "$(dirname "$0")" && pwd)"
dir="${FZ_VM_DIR:-$HOME/VMs/founderizer-windows}"
key="${FZ_VM_KEY:-$HOME/.ssh/founderizer-windows-vm}"
port="${FZ_VM_PORT:-52222}"
utm="${FZ_VM_UTM:-/Applications/UTM.app}"
# The UTM whose QEMU, swtpm and firmware this VM was made and tested with.
utm_version="5.0.8"
cpus="${FZ_VM_CPUS:-6}"
memory="${FZ_VM_MEMORY_MB:-16384}"
disk_size="${FZ_VM_DISK:-100G}"
screen="${FZ_VM_SCREEN:-2880x1800}"
windows_iso="${FZ_VM_WINDOWS_ISO:-$dir/downloads/windows/Windows11_Client_arm64_en-us_26300_9457.iso}"
tools_iso="${FZ_VM_TOOLS_ISO:-$dir/downloads/guest-tools/utm-guest-tools-0.1.271.iso}"
user="builder"

launcher="$dir/bin/fz-qemu-launcher"
frameworks="$utm/Contents/Frameworks"
firmware="$utm/Contents/Resources/qemu"
run_dir="$dir/run"
qmp_socket="$run_dir/qmp.sock"
tpm_socket="$run_dir/swtpm.sock"

say() { printf '%s\n' "$*" >&2; }
die() { say "vm.sh: $*"; exit 1; }

ssh_options() {
    printf '%s\n' -F /dev/null -i "$key" -o IdentitiesOnly=yes -o IdentityAgent=none -o BatchMode=yes \
        -o UserKnownHostsFile="$dir/known_hosts" -o StrictHostKeyChecking=accept-new \
        -o ConnectTimeout=5 -o ServerAliveInterval=15 -o LogLevel=ERROR
}

vm_ssh() {
    local options=()
    while IFS= read -r line; do options+=("$line"); done < <(ssh_options)
    ssh "${options[@]}" -p "$port" "$user@127.0.0.1" "$@"
}

# Runs a PowerShell script (stdin) in the VM with -EncodedCommand, so no quoting reaches the shells between.
# PowerShell writes the errors of an encoded command as CLIXML; the wrapper writes them to stderr as text.
vm_powershell() {
    local wrapped
    wrapped="$(python3 -I -c '
import base64, sys
script = sys.stdin.read()
wrapped = """$ProgressPreference = "SilentlyContinue"
try {
    & {
%s
    } 2>&1 | ForEach-Object {
        if ($_ -is [System.Management.Automation.ErrorRecord]) { [Console]::Error.WriteLine(($_ | Out-String).TrimEnd()) } else { $_ }
    }
} catch {
    [Console]::Error.WriteLine(($_ | Out-String).TrimEnd())
    exit 1
}
if ($LASTEXITCODE) { exit $LASTEXITCODE }
""" % script
sys.stdout.write(wrapped)
')"
    local encoded
    encoded="$(printf '%s' "$wrapped" | python3 -I -c 'import base64,sys; print(base64.b64encode(sys.stdin.read().encode("utf-16-le")).decode())')"
    if [ "${#encoded}" -lt 7000 ]; then
        vm_ssh "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $encoded"
        return
    fi
    # cmd.exe, the SSH shell, takes at most 8,191 characters: a longer script goes over as a file.
    local name local_file code=0
    name="fz-script-$(date +%s)-$$-$RANDOM.ps1"
    local_file="$(mktemp "${TMPDIR:-/tmp}/fz-script.XXXXXX")"
    printf '%s' "$wrapped" > "$local_file"
    vm_ssh "if not exist C:\\fz\\run mkdir C:\\fz\\run" >/dev/null
    copy_files "$local_file" "vm:C:/fz/run/$name"
    rm -f "$local_file"
    vm_ssh "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File C:\\fz\\run\\$name" || code=$?
    vm_ssh "del C:\\fz\\run\\$name" >/dev/null 2>&1 || true
    return "$code"
}

# Runs one PowerShell command text in the VM, as vm_powershell does.
vm_ps() {
    printf '%s' "$*" | vm_powershell
}

check_utm() {
    local found
    found="$(plutil -extract CFBundleShortVersionString raw "$utm/Contents/Info.plist" 2>/dev/null || true)"
    if [ "$found" != "$utm_version" ]; then
        die "UTM at $utm is version ${found:-unknown}, not $utm_version. This VM runs only with the UTM it was made with. Install UTM $utm_version again, or test the new version and change utm_version in vm.sh."
    fi
}

running() {
    [ -f "$run_dir/qemu.pid" ] && kill -0 "$(cat "$run_dir/qemu.pid")" 2>/dev/null
}

ssh_answers() {
    vm_ssh 'exit 0' >/dev/null 2>&1
}

wait_for_ssh() {
    local limit="${1:-600}" waited=0
    until ssh_answers; do
        running || die "QEMU ended; see $run_dir/qemu.log"
        [ "$waited" -ge "$limit" ] && die "no SSH answer after $limit seconds"
        sleep 5
        waited=$((waited + 5))
    done
}

# Starts a program in a new session, detached from this shell, and writes its pid.
detach() {
    local log="$1" pidfile="$2"
    shift 2
    python3 -I -c '
import subprocess, sys
log = open(sys.argv[1], "ab")
process = subprocess.Popen(sys.argv[3:], stdin=subprocess.DEVNULL, stdout=log, stderr=log, start_new_session=True)
open(sys.argv[2], "w").write(str(process.pid))
' "$log" "$pidfile" "$@"
}

qmp() {
    python3 -I - "$qmp_socket" "$1" <<'PY'
import json, socket, sys
path, command = sys.argv[1], json.loads(sys.argv[2])
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect(path)
f = s.makefile("rw")
json.loads(f.readline())
f.write(json.dumps({"execute": "qmp_capabilities"}) + "\n"); f.flush()
json.loads(f.readline())
f.write(json.dumps(command) + "\n"); f.flush()
while True:
    reply = json.loads(f.readline())
    if "return" in reply or "error" in reply:
        break
print(json.dumps(reply))
sys.exit(1 if "error" in reply else 0)
PY
}

build_launcher() {
    [ -x "$launcher" ] && return 0
    "$here/launcher/build.sh" "$launcher" "$utm" >/dev/null
}

# start_vm [install|setup]: "install" boots the Windows disc and the setup disc, and QEMU ends at the guest's
# first restart (-no-reboot); "setup" boots the disk with the setup disc only; no word boots the disk alone.
start_vm() {
    local mode="${1:-}"
    running && { say "the VM runs already"; return 0; }
    [ -f "$dir/disk.qcow2" ] || die "no VM at $dir: run vm.sh create"
    check_utm
    build_launcher
    mkdir -p "$run_dir" "$dir/tpm"
    chmod 700 "$dir" "$run_dir" "$dir/tpm"
    rm -f "$qmp_socket" "$tpm_socket"

    detach "$run_dir/swtpm.log" "$run_dir/swtpm.pid" "$launcher" "$frameworks/swtpm.0.framework/swtpm.0" \
        --ctrl "type=unixio,path=$tpm_socket,terminate" --tpmstate "dir=$dir/tpm" --tpm2
    local i
    for i in $(seq 1 50); do [ -S "$tpm_socket" ] && break; sleep 0.1; done
    [ -S "$tpm_socket" ] || die "swtpm did not start; see $run_dir/swtpm.log"
    chmod 600 "$tpm_socket"

    local media=()
    if [ "$mode" = install ]; then
        media=(-no-reboot
               -device usb-storage,drive=cd0,removable=true,bootindex=0,bus=usb-bus.0
               -drive "if=none,media=cdrom,id=cd0,readonly=on,file.locking=off,file.filename=$windows_iso")
    fi
    if [ "$mode" = install ] || [ "$mode" = setup ]; then
        media+=(-device usb-storage,drive=cd1,removable=true,bus=usb-bus.0
                -drive "if=none,media=cdrom,id=cd1,readonly=on,file.locking=off,file.filename=$dir/setup.iso")
    fi
    detach "$run_dir/qemu.log" "$run_dir/qemu.pid" "$launcher" \
        "$frameworks/qemu-aarch64-softmmu.framework/qemu-aarch64-softmmu" \
        -L "$firmware" -name founderizer-windows \
        -machine virt,gic-version=3 -accel hvf -cpu host \
        -smp "cpus=$cpus,sockets=1,cores=$cpus,threads=1" -m "$memory" \
        -nodefaults -vga none -display none -device "virtio-ramfb,xres=${screen%x*},yres=${screen#*x}" \
        -drive "if=pflash,format=raw,unit=0,readonly=on,file.locking=off,file.filename=$firmware/edk2-aarch64-secure-code.fd" \
        -drive "if=pflash,unit=1,file.filename=$dir/efi_vars.fd" \
        -device nec-usb-xhci,id=usb-bus -device usb-tablet,bus=usb-bus.0 -device usb-kbd,bus=usb-bus.0 \
        -device nvme,drive=disk0,serial=fzdisk0,bootindex=1 \
        -drive "if=none,media=disk,id=disk0,discard=unmap,detect-zeroes=unmap,file.filename=$dir/disk.qcow2" \
        "${media[@]+"${media[@]}"}" \
        -device virtio-net-pci,netdev=net0,mac=52:54:00:46:5a:01 \
        -netdev "user,id=net0,hostfwd=tcp:127.0.0.1:$port-:22" \
        -device virtio-rng-pci -device virtio-balloon-pci \
        -chardev "socket,id=chrtpm0,path=$tpm_socket" -tpmdev emulator,id=tpm0,chardev=chrtpm0 \
        -device tpm-crb-device,tpmdev=tpm0 \
        -qmp "unix:$qmp_socket,server=on,wait=off"
    for i in $(seq 1 100); do [ -S "$qmp_socket" ] && break; running || break; sleep 0.1; done
    running || die "QEMU did not start; see $run_dir/qemu.log"
    [ -S "$qmp_socket" ] || die "QEMU did not open its monitor; see $run_dir/qemu.log"
    chmod 600 "$qmp_socket"
}

stop_vm() {
    running || { say "the VM is not running"; return 0; }
    # The monitor presses the VM's power button, and Windows shuts down.
    qmp '{"execute":"system_powerdown"}' >/dev/null 2>&1 || true
    local waited=0
    while running && [ "$waited" -lt 120 ]; do sleep 2; waited=$((waited + 2)); done
    if running; then
        say "Windows did not answer the power button in 120 seconds; asking it over SSH"
        vm_ps 'Stop-Computer -Force' >/dev/null 2>&1 || true
        waited=0
        while running && [ "$waited" -lt 120 ]; do sleep 2; waited=$((waited + 2)); done
    fi
    if running; then
        say "Windows did not shut down; QEMU quits"
        qmp '{"execute":"quit"}' >/dev/null 2>&1 || kill "$(cat "$run_dir/qemu.pid")"
        sleep 3
    fi
    if [ -f "$run_dir/swtpm.pid" ] && kill -0 "$(cat "$run_dir/swtpm.pid")" 2>/dev/null; then
        sleep 2
        kill "$(cat "$run_dir/swtpm.pid")" 2>/dev/null || true
    fi
    rm -f "$run_dir/qemu.pid" "$run_dir/swtpm.pid" "$qmp_socket" "$tpm_socket"
    say "the VM is stopped"
}

desktop() {
    local command="$*" id encoded
    [ -n "$command" ] || die "desktop needs a command"
    id="fz-desktop-$(date +%s)-$$"
    encoded="$(printf '%s' "$command" | base64 | tr -d '\n')"
    {
        printf "\$id = '%s'\n\$encoded = '%s'\n\$user = '%s'\n" "$id" "$encoded" "$user"
        cat <<'PS'
$ErrorActionPreference = 'Stop'
$folder = 'C:\fz\desktop'
New-Item -ItemType Directory -Force -Path $folder | Out-Null
$command = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($encoded))
$out = Join-Path $folder "$id.out"
$exit = Join-Path $folder "$id.exit"
$wrapper = Join-Path $folder "$id.ps1"
$body = @"
`$code = 0
try { & {
$command
} *>&1 | Out-File -FilePath '$out' -Encoding utf8; if (`$LASTEXITCODE) { `$code = `$LASTEXITCODE } }
catch { `$_ | Out-File -FilePath '$out' -Append -Encoding utf8; `$code = 1 }
Set-Content -Path '$exit' -Value `$code
"@
Set-Content -Path $wrapper -Value $body -Encoding utf8
$action = New-ScheduledTaskAction -Execute 'conhost.exe' -Argument "--headless powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$wrapper`""
$principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 2)
Register-ScheduledTask -TaskName $id -Action $action -Principal $principal -Settings $settings -Force | Out-Null
Start-ScheduledTask -TaskName $id
$deadline = (Get-Date).AddHours(2)
while (-not (Test-Path $exit)) {
    if ((Get-Date) -gt $deadline) { throw "no end after two hours: $id" }
    Start-Sleep -Milliseconds 500
}
Start-Sleep -Milliseconds 200
Unregister-ScheduledTask -TaskName $id -Confirm:$false
if (Test-Path $out) { Get-Content -Path $out -Encoding utf8 }
$code = [int](Get-Content -Path $exit)
Remove-Item -Path $wrapper, $out, $exit -ErrorAction SilentlyContinue
exit $code
PS
    } | vm_powershell
}

picture() {
    local out="${1:-$PWD/windows-desktop-$(date +%Y%m%d-%H%M%S).png}" name
    name="picture-$(date +%s)-$$.png"
    desktop "\$path = 'C:\\fz\\desktop\\$name'
$(cat <<'PS'
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type -TypeDefinition 'using System.Runtime.InteropServices; public static class FzDpi { [DllImport("user32.dll")] public static extern bool SetProcessDPIAware(); }'
[FzDpi]::SetProcessDPIAware() | Out-Null
$bounds = [System.Windows.Forms.SystemInformation]::VirtualScreen
$bitmap = New-Object System.Drawing.Bitmap $bounds.Width, $bounds.Height
$graphics = [System.Drawing.Graphics]::FromImage($bitmap)
$graphics.CopyFromScreen($bounds.Left, $bounds.Top, 0, 0, $bitmap.Size)
$bitmap.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
$graphics.Dispose(); $bitmap.Dispose()
Write-Output ("{0}x{1}" -f $bounds.Width, $bounds.Height)
PS
)" >&2
    copy_files "vm:C:/fz/desktop/$name" "$out"
    vm_ps "Remove-Item -Path 'C:\\fz\\desktop\\$name'" >/dev/null
    printf '%s\n' "$out"
}

copy_files() {
    local options=() arguments=() item
    while IFS= read -r line; do options+=("$line"); done < <(ssh_options)
    for item in "$@"; do
        case "$item" in
            vm:*) arguments+=("$user@127.0.0.1:${item#vm:}") ;;
            *) arguments+=("$item") ;;
        esac
    done
    scp -q -r "${options[@]}" -P "$port" "${arguments[@]}"
}

create_vm() {
    [ -f "$dir/disk.qcow2" ] && die "a VM exists at $dir already"
    [ -f "$windows_iso" ] || die "no Windows ISO at $windows_iso"
    [ -f "$tools_iso" ] || die "no UTM guest tools disc at $tools_iso"
    [ -f "$key.pub" ] || die "no public key at $key.pub"
    check_utm
    mkdir -p "$dir/tpm" "$run_dir"
    chmod 700 "$dir" "$dir/tpm" "$run_dir"
    build_launcher
    "$launcher" "$frameworks/qemu-img.framework/qemu-img" create -q -f qcow2 "$dir/disk.qcow2" "$disk_size"
    cp "$firmware/edk2-arm-secure-vars.fd" "$dir/efi_vars.fd"
    "$here/make-setup-iso.sh" "$tools_iso" "$key.pub" "$dir/setup.iso" >/dev/null
    rm -f "$dir/known_hosts"
    start_vm install
    # The Windows disc asks for a key before it boots from CD: press one, a few times, early.
    local i
    for i in $(seq 1 12); do sleep 1; qmp '{"execute":"send-key","arguments":{"keys":[{"type":"qcode","data":"spc"}]}}' >/dev/null 2>&1 || true; done
    # Windows Setup's first restart ends this QEMU run (-no-reboot). The next run boots the disk with the setup
    # disc only: in one of two installs, Windows hung at a Setup restart with both USB discs attached and the CD
    # first in the boot order, and booted at once without them.
    say "Windows Setup copies Windows to the disk (about 10 minutes)"
    local waited=0
    while running; do
        [ "$waited" -ge 3600 ] && die "Windows Setup did not restart in 60 minutes; see vm.sh screen"
        sleep 5
        waited=$((waited + 5))
    done
    local used
    used="$(du -k "$dir/disk.qcow2" | cut -f1)"
    [ "$used" -gt 4000000 ] || die "QEMU ended before Windows Setup copied Windows (disk ${used} KB); see $run_dir/qemu.log"
    waited=0
    while [ -f "$run_dir/swtpm.pid" ] && kill -0 "$(cat "$run_dir/swtpm.pid")" 2>/dev/null && [ "$waited" -lt 30 ]; do
        sleep 1
        waited=$((waited + 1))
    done
    start_vm setup
    say "Windows Setup goes on from the disk; it ends with the first sign-in, the setup script and a restart (about 20 minutes)"
    wait_for_ssh 5400
    local code
    waited=0
    while true; do
        code=0
        vm_ps 'if (Test-Path C:\ProgramData\fz-setup\done) { exit 0 } elseif (Test-Path C:\ProgramData\fz-setup\failed) { exit 2 } else { exit 1 }' >/dev/null 2>&1 || code=$?
        [ "$code" -eq 0 ] && break
        [ "$code" -eq 2 ] && die "the first-logon script failed: vm.sh run 'Get-Content C:\ProgramData\fz-setup\first-logon.log'"
        [ "$waited" -ge 1800 ] && die "the first-logon script did not end in 30 minutes"
        sleep 10
        waited=$((waited + 10))
    done
    # The script restarts Windows 15 seconds after it writes its done file. Wait for a boot after that file,
    # and for the desktop session that the automatic sign-in started after that boot.
    waited=0
    until vm_ps "\$done = (Get-Item C:\\ProgramData\\fz-setup\\done).LastWriteTimeUtc; \$boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime; if (\$boot.ToUniversalTime() -gt \$done -and (Get-Process explorer -IncludeUserName -ErrorAction SilentlyContinue | Where-Object { \$_.UserName -like '*\\$user' -and \$_.StartTime -ge \$boot })) { exit 0 } else { exit 1 }" >/dev/null 2>&1; do
        [ "$waited" -ge 900 ] && die "no restart with a desktop session of $user after the first-logon script"
        sleep 5
        waited=$((waited + 5))
    done
    say "Windows is installed, and $user is signed in"
}

command="${1:-}"
[ $# -gt 0 ] && shift
case "$command" in
    create) create_vm ;;
    start) start_vm; wait_for_ssh 600; say "the VM runs; SSH answers on 127.0.0.1:$port" ;;
    stop) stop_vm ;;
    status)
        if running; then
            printf 'running, pid %s\n' "$(cat "$run_dir/qemu.pid")"
            vm_ps '"Windows up since " + (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToString("u")' 2>/dev/null || echo "SSH does not answer yet"
        else
            echo "stopped"
        fi ;;
    run) [ $# -gt 0 ] || die "run needs a command"; vm_ps "$*" ;;
    copy) [ $# -ge 2 ] || die "copy needs a source and a destination"; copy_files "$@" ;;
    desktop) desktop "$@" ;;
    picture) picture "${1:-}" ;;
    screen)
        out="${1:-$PWD/windows-screen-$(date +%Y%m%d-%H%M%S).png}"
        # UTM's QEMU writes no PNG, so it writes a PPM, and Python turns it into a PNG.
        ppm="$run_dir/screen-$$.ppm"
        qmp "{\"execute\":\"screendump\",\"arguments\":{\"filename\":\"$ppm\"}}" >/dev/null
        python3 -I - "$ppm" "$out" <<'PY'
import struct, sys, zlib
data = open(sys.argv[1], "rb").read()
fields, position = [], 0
while len(fields) < 4:
    while data[position:position + 1].isspace():
        position += 1
    if data[position:position + 1] == b"#":
        position = data.index(b"\n", position) + 1
        continue
    end = position
    while not data[end:end + 1].isspace():
        end += 1
    fields.append(data[position:end])
    position = end
assert fields[0] == b"P6" and fields[3] == b"255", fields
width, height = int(fields[1]), int(fields[2])
pixels = data[position + 1:]
rows = b"".join(b"\x00" + pixels[y * width * 3:(y + 1) * width * 3] for y in range(height))
def chunk(kind, body):
    return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body) & 0xffffffff)
png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)) \
    + chunk(b"IDAT", zlib.compress(rows, 6)) + chunk(b"IEND", b"")
open(sys.argv[2], "wb").write(png)
PY
        rm -f "$ppm"
        printf '%s\n' "$out" ;;
    keys)
        [ $# -gt 0 ] || die "keys needs QEMU key names"
        for name in "$@"; do
            qmp "{\"execute\":\"send-key\",\"arguments\":{\"keys\":[{\"type\":\"qcode\",\"data\":\"$name\"}]}}" >/dev/null
            sleep 0.2
        done ;;
    *) sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
