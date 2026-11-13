# The Windows build VM

A Windows 11 Pro for Arm64 VM on a Mac with Apple silicon, for the Windows app's build lane (slice 1.0 of the Windows
app plan). Later sessions drive it with no person at it: it runs with no window, and every step goes over SSH with a
key. It is the build computer of plan decision D1 until a real PC comes.

It runs the QEMU, swtpm and firmware of **UTM 5.0.8**, through a small launcher (see "Why a launcher"). Thus QEMU runs
**outside UTM's sandbox, as the user's own process**.

## What the VM is

| Part | Value |
| --- | --- |
| Windows | Windows 11 Pro for Arm64, 26H2 (build 26300), English (United States), not activated |
| Hardware | 6 cores (`-cpu host`, hypervisor), 16 GB of memory, 100 GB disk (qcow2, NVMe), Secure Boot with Microsoft's keys, TPM 2.0 (swtpm, CRB) |
| Display | `virtio-ramfb` with the guest tools' `viogpudo` driver: 2880 x 1800 at 200 % (`FZ_VM_SCREEN`), the size of the approved pictures; no graphics card, so Windows draws in software |
| Network | QEMU's user-mode network. One forward: `127.0.0.1:52222` on the Mac to the VM's port 22. Nothing else reaches the VM |
| .NET | SDK 10.0.404 (runtime 10.0.15), installed by `setup/install-dotnet.ps1` |
| User | `builder`, a local administrator, no Microsoft account. It signs in by itself at each start, so a desktop session exists for windows and pictures |
| Password | Random, made in the VM at the first sign-in; it never leaves the VM. Nothing needs it: SSH takes the key only |
| SSH | Windows' own OpenSSH server, key only, Windows' default shell (`cmd.exe`), firewall rule for `10.0.2.2` (the Mac) only |

## Files

On the Mac, outside any repository (each folder and file is private to the user, mode 700 or 600):

| Path | What |
| --- | --- |
| `$HOME/VMs/founderizer-windows/` | the VM (`FZ_VM_DIR`) |
| `.../disk.qcow2`, `efi_vars.fd`, `tpm/` | its disk, its UEFI variables, its TPM state (`tpm/tpm2-00.permall`) |
| `.../setup.iso` | the setup disc that `create` made (answer file, first-logon script, drivers, public key) |
| `.../run/` | `qmp.sock` (the monitor) and `swtpm.sock`, Unix sockets with mode 600; the pid files and the logs |
| `.../bin/fz-qemu-launcher` | the launcher that `launcher/build.sh` built |
| `.../known_hosts` | the VM's SSH host key, apart from the user's own `known_hosts` |
| `.../downloads/` | the downloads below, kept so that a second VM needs none |
| `$HOME/.ssh/founderizer-windows-vm` | the SSH key of this Mac for the VM (ed25519, `FZ_VM_KEY`) |

In this folder:

| File | What |
| --- | --- |
| `vm.sh` | the helper: create, start, stop, status, run, copy, desktop, picture, screen, keys |
| `autounattend.xml` | the answer file of Windows Setup; it holds no secret |
| `setup/first-logon.ps1` | runs once at the first sign-in: drivers, SSH, power, password, automatic sign-in |
| `make-setup-iso.sh` | makes the setup disc |
| `launcher/` | the launcher's source, its build script and its one entitlement |
| `setup/install-dotnet.ps1` | installs the .NET 10 SDK in the VM |
| `setup/build-window.ps1` | builds and signs the window of `../Founderizer.Windows` in the VM (`-Proofs`: the proofs' build) |
| `readings/` | the readings: keys in the TPM, start time with memory at rest, the processor at rest (`cpu-at-rest.ps1`) |
| `pictures/` | the proofs with pictures: a scripted run and the writes (`ui.ps1`), frames of motion (`frames.ps1`, `motion.py`, `changes.py`), comparisons with the approved pictures (`compare.py`, `glyphs.py`, `sheet.py`), the desktop for pictures (`look.ps1`) |
| `scratch_hub.py` | a scratch hub on the Mac that the VM's app reads, and the changes for the proofs |
| `tailnet/find-hub.cs` | the library's own search for the hub on the owner's private network, run in the VM |
| `test_channel.py` | the test channel of the update on the Mac: manifests that a test key signed, and the builds' zips, over HTTPS on 127.0.0.1 |
| `../release/build-release.ps1` | the build of a release: the zip and the setup of each kind of PC (`../release/README.md`) |
| `release-proofs/` | the release's proofs in the VM: the install's state (`state.ps1`), and the zips whose file has another signer or none (`make-refusals.ps1`) |

## The downloads

Each one was downloaded once, on 13 November 2026, and checked:

| File | Source | Size | SHA-256 | Checked against |
| --- | --- | --- | --- | --- |
| `UTM.dmg` (UTM 5.0.8) | `github.com/utmapp/UTM/releases/download/v5.0.8/UTM.dmg` | 304,304,581 | `7b2d7b2e2a02b3de1757ef19a8f36573e6d9cceae8c8cca0abcbcaa4a852019a` | the Homebrew cask `utm` and GitHub's digest; notarized, Developer ID of Turing Software, LLC (`WDNLXAD4W8`) |
| `Windows11_Client_arm64_en-us_26300_9457.iso` | `microsoft.com/software-download/windows11arm64`, "Windows 11 (multi-edition ISO for Arm64)", English | 8,528,523,264 | `8992f2d2cfd2fa647e579e9eb31fc21f34da8333c29b6170fde17d2ed6623e9c` | the table "Verify your download" on that page ("English 64-bit") |
| `utm-guest-tools-0.1.271.iso` | `getutm.app/downloads/utm-guest-tools-latest.iso`, which is `github.com/utmapp/qemu/releases/download/v10.0.2-utm/` | 127,084,544 | `65b6a69b392ee01dd314c10f3dad9ebbf9c4160be43f5f0dd6bb715944d9095b` | GitHub's digest |
| `tailscale-setup-1.104.7-arm64.msi` (in the VM, `C:\fz\downloads\`) | `pkgs.tailscale.com/stable/tailscale-setup-1.104.7-arm64.msi` | 36,453,888 | `904c4d877e306d601ac6dc1216091064769be9c942a2a1acc0cd98ffc6ee9191` | Windows' Authenticode check in the VM: Valid, signer `CN=Tailscale Inc., O=Tailscale Inc., L=Toronto, S=Ontario, C=CA` (DigiCert Trusted G4 Code Signing RSA4096 SHA384 2021 CA1, with a timestamp) |

Microsoft's download page refuses a scripted request ("Sentinel"), so the ISO's link comes from the page in a
browser. The link is valid for 24 hours. The guest tools give the ARM64 virtio drivers; Microsoft signed them
(Windows Hardware Compatibility Publisher), so Windows installs them with no question. The .NET SDK comes later,
inside the VM, from Microsoft (`setup/install-dotnet.ps1`).

## Make a VM

1. Install UTM 5.0.8 from the checked `UTM.dmg` into `/Applications` (`hdiutil attach`, `ditto`). Its own window is
   never opened.
2. Put the Windows ISO and the guest tools disc where `vm.sh` expects them (`$FZ_VM_DIR/downloads/windows/` and
   `.../guest-tools/`), or name them in `FZ_VM_WINDOWS_ISO` and `FZ_VM_TOOLS_ISO`.
3. Make the key: `ssh-keygen -t ed25519 -N '' -C founderizer-windows-vm -f "$HOME/.ssh/founderizer-windows-vm"`.
4. Run `app/windows/vm/vm.sh create`. It builds the launcher, makes the disk (UTM's `qemu-img`), copies UTM's
   Secure Boot variables (`edk2-arm-secure-vars.fd`, Microsoft's keys), makes the setup disc, and starts QEMU with
   the two discs and `-no-reboot`. It presses Space for "Press any key to boot from CD or DVD". Windows Setup copies
   Windows to the disk, and its first restart ends that QEMU run. `create` then starts QEMU again from the disk with
   only the setup disc: Setup goes on, signs in as `builder`, runs `setup/first-logon.ps1` and restarts. `create`
   ends when the user's desktop runs after that restart: 12 minutes on an M4 Max on 13 November 2026.
   Why two runs: in the first form of `create`, one of two installs hung at a Setup restart, with both USB discs
   attached and the CD first in the boot order (all 6 cores busy, the same frame for 17 minutes, again after a
   reset); the same disk booted at once without the discs.
5. Install the .NET SDK: copy `setup/install-dotnet.ps1` into the VM and run it (the commands are at its top).

`vm.sh screen` shows the VM's display at any time, also during Windows Setup. If `create` stops, the log of the
first-logon script is `C:\ProgramData\fz-setup\first-logon.log` in the VM.

**A second VM:** give it its own `FZ_VM_DIR` and `FZ_VM_PORT` (and its own key in `FZ_VM_KEY`, if it is for another
user), and run `create`. The downloads can stay in the first VM's folder: name them in `FZ_VM_WINDOWS_ISO` and
`FZ_VM_TOOLS_ISO`.

## Use it

```
app/windows/vm/vm.sh start                     # starts QEMU detached and waits until SSH answers
app/windows/vm/vm.sh run 'dotnet --version'    # one PowerShell command in an SSH session
app/windows/vm/vm.sh run 'New-Item -ItemType Directory -Force -Path C:\fz\src\windows, C:\fz\setup | Out-Null'
app/windows/vm/vm.sh copy app/windows/Directory.Build.props app/windows/global.json app/windows/nuget.config \
    app/windows/Founderizer.Windows vm:C:/fz/src/windows/
app/windows/vm/vm.sh copy app/windows/vm/setup/build-window.ps1 vm:C:/fz/setup/
app/windows/vm/vm.sh run 'powershell -NoProfile -ExecutionPolicy Bypass -File C:\fz\setup\build-window.ps1 -Source C:\fz\src\windows\Founderizer.Windows'
app/windows/vm/vm.sh desktop 'Start-Process C:\fz\out\arm64\Founderizer.App.exe'
app/windows/vm/vm.sh picture /tmp/window.png    # a picture of the desktop, taken in the VM
app/windows/vm/vm.sh stop                      # the power button through the monitor; waits until QEMU ends
```

- `run` sends its text to Windows PowerShell 5.1 as `-EncodedCommand`, so no quoting of the shells between applies.
  A longer text (cmd.exe takes 8,191 characters) goes to the VM as a file in `C:\fz\run\` and runs with `-File`;
  the file is removed after.
  Errors come back on stderr as text, and the exit code of the last program or of `exit` comes back too. An error
  that stops a command stops the rest of that text (PowerShell's `try`).
- `desktop` runs its command in the signed-in user's desktop session (a scheduled task with an interactive logon,
  as a normal user, under `conhost --headless`), waits for it, and prints its output. An SSH session cannot show a
  window; this one can.
- `picture` takes the picture inside Windows (`Graphics.CopyFromScreen` in the desktop session), so it works on a
  real PC too. `screen` takes it from QEMU's display, also before Windows runs; UTM's QEMU writes no PNG, so
  `vm.sh` turns its PPM into a PNG with Python's standard library.
- Do not change `vm.sh` while a `vm.sh` command runs: bash reads a script while it runs it.
- `start` checks that the installed UTM is 5.0.8, and stops with a plain message when it is not.
- QEMU and swtpm run detached in their own session, with pid files in `run/`, so the VM lives on after the command
  or the turn that started it. Nothing starts by itself: no launch agent, no login item.
- The Mac is shared with the test runs of other threads: stop the VM when the work no longer needs it.

## Why a launcher

UTM 5.0.8 starts a VM only from its own window or by Apple Events (`utmctl`, AppleScript). Its `utm://` links only
import or download a VM. Apple Events from a session need the user's click on a macOS privacy prompt (Automation,
"... wants access to control UTM"), and each VM then shows a window. UTM's own QEMU helper (`QEMULauncher`) is
signed to inherit UTM's sandbox, and macOS stops it with SIGTRAP when anything but UTM starts it.

So `launcher/fz-qemu-launcher.c` does the work of UTM's helper: it loads UTM's QEMU, `qemu-img` or swtpm library and
calls its entry point. It is a shorter form of UTM's `QEMULauncher/main.c` and `Bootstrap.c` (Apache-2.0, notice
kept). `launcher/build.sh` compiles it on the Mac and signs it ad hoc with one entitlement,
`com.apple.security.hypervisor`. No sudo, no setuid, no other entitlement, no change of a macOS setting. The
coordinator of the Windows work chose this route on 13 November 2026, with these conditions: user-mode network only,
Unix sockets with mode 600, the TPM state folder with mode 700, QEMU detached with a pid file, `stop` through the
monitor, the UTM version check, and this paragraph.

**Opening the VM in UTM's window is left out.** A UTM bundle needs a `config.plist` in UTM's own format, and only
UTM's window can show whether UTM takes it; that window is what this VM avoids. The parts are plain files: a person
who wants the VM in UTM can make a Windows VM there (Arm64, UEFI, TPM, NVMe, the same settings) and put this
`disk.qcow2`, `efi_vars.fd` and `tpm/tpm2-00.permall` into its `Data` folder. That is not tested.

## What Windows Setup and the first-logon script change in Windows

- The answer file accepts Microsoft's licence terms for Windows (`AcceptEula`, `HideEULAPage`) and uses Microsoft's
  published KMS client key for Windows 11 Pro, as UTM's own answer file does. It selects the edition and activates
  nothing.
- Only Windows Setup's CPU check is bypassed (`LabConfig\BypassCPUCheck`). Setup checked the TPM 2.0 and Secure Boot
  itself.
- Privacy pages: no diagnostic data beyond the required, no Microsoft account, no online pages (`ProtectYourPC 3`,
  `HideOnlineAccountScreens`).
- Windows Update does not restart Windows while the user is signed in (`NoAutoRebootWithLoggedOnUsers`). Updates
  still install.
- The display, the disk and the VM never sleep; no hibernation; no lock at wake.
- UAC stays on. The desktop session runs as a normal user; an SSH session of an administrator is elevated.
- The automatic sign-in reads its password from the LSA secret `DefaultPassword`, not from the registry.
- `setup/build-window.ps1` puts its test certificate in the VM's trusted roots and trusted publishers.
- The display scale is 200 % (`Win8DpiScaling`, `LogPixels` 192), as in the approved pictures.

## The window in the VM

A normal start of the window keeps the library's store in `%LOCALAPPDATA%\Founderizer\store`, the device key in
`%LOCALAPPDATA%\Founderizer\device-key` (see "The device key"), and reads this PC's Tailscale to find the hub; with no
hub it opens on Add this PC. It reads no variable.

**The proofs' build** (`build-window.ps1 -Proofs`, `-p:FounderizerProofs=true`, into `C:\fz\out\arm64-proofs`) reads
the variables below, for the proofs in this VM only; the release build (`C:\fz\out\arm64`) has no such switch, and its
`Founderizer.App.dll` does not refer to `GetEnvironmentVariable` at all.

| Variable | What |
| --- | --- |
| `FOUNDERIZER_SAMPLE` | `1`: the sample fleet of the Mac and iPhone apps, with the example hub address and this PC's line of picture 6 |
| `FOUNDERIZER_HUB`, `FOUNDERIZER_DEVICE_CODE`, `FOUNDERIZER_STORE` | the library's store reads this hub, enrolls with the code, and keeps its files in the folder; the key stays in memory, so each start needs a new code |
| `FOUNDERIZER_SAMPLE_CLOCK` | `HH:mm`: the sample fleet's times as at that clock (`15:12` gives the times of picture 1) |
| `FOUNDERIZER_SAMPLE_ASK` | his one message in Customer Support's chat, a minute before the clock, which the agent works on: "Which order is it?" gives picture 2 and its "Thinking" line. The sample sends nothing: its writes do nothing |
| `FOUNDERIZER_TIMING_LOG` | a file for the app's timing lines (see "Readings"), and the answer of each Connect and each code (`connect: …`, `enroll: …`), whose lines on the screen wait for their pictures |
| `FOUNDERIZER_READING` | `changes`: the sample changes one line every 3 seconds; `block-ui`: the UI thread sleeps 4 seconds, 5 seconds after the start; `long-chat`: Customer Support's chat has 2,000 messages and replies, and 5 seconds after it opens, the scroll reading runs (see "Readings") |
| `FOUNDERIZER_DEBUG_LOG` | a file for an exception that nothing caught |

The argument `-openPage needs|tasks|activity|settings|agent.<name>|task.<id>` opens that page first, as the Mac app's
does.

### Pictures

Copy `pictures/*.ps1` to `C:\fz\setup\` first. Each still picture is taken with the animation effects off and the
taskbar hidden (`look.ps1`); the frames of motion with the animation effects on.

```
app/windows/vm/vm.sh desktop '& C:\fz\setup\look.ps1'
app/windows/vm/vm.sh desktop '$env:FOUNDERIZER_SAMPLE_CLOCK = "15:12"; Start-Process C:\fz\out\arm64\Founderizer.App.exe -ArgumentList "-openPage", "agent.manager"'
app/windows/vm/vm.sh desktop '& C:\fz\setup\ui.ps1 -Click "Tasks"'       # one step of a scripted run, as a mouse click
app/windows/vm/vm.sh picture built.png
python3 -I app/windows/vm/pictures/compare.py approved.png built.png side.png 0 0 2880 96 0 96 640 1800 642 98 2120 1800 2120 96 2880 1800
python3 -I app/windows/vm/pictures/glyphs.py approved.png built.png glyphs.png
app/windows/vm/vm.sh desktop '& C:\fz\setup\look.ps1 -AnimationsOn'
app/windows/vm/vm.sh desktop '& C:\fz\setup\frames.ps1 -Out C:\fz\frames -Count 16 -IntervalMs 150 -X 642 -Y 98 -Width 2238 -Height 1702'
app/windows/vm/vm.sh copy 'vm:C:/fz/frames' frames
python3 -I app/windows/vm/pictures/changes.py frames                 # in how many frames the part changed
python3 -I app/windows/vm/pictures/motion.py frames motion.png       # with the default part: the pane's agents
```

- `compare.py` prints the mean difference of each region (x0 y0 x1 y1, in the screen's own pixels) and the share of
  pixels that are far apart, and writes the two pictures side by side. `glyphs.py` does the same for each agent's
  mark in the pane. `sheet.py` puts the title bar and the pane of several pictures side by side.
- `ui.ps1` presses a button of the window through UI Automation (a row's name, a card's title, an option, `Back`,
  `Pause`) and prints the open page's name and whether Back and Forward can be pressed. No person is needed.
  `-Invoke` presses it through UI Automation, which leaves Windows' keyboard focus frame on it; `-Click` presses it
  with the mouse, as a person does, and then moves the pointer to the empty middle of the title bar, so a picture
  shows the window at rest (no focus frame, no hover fill, no tooltip). `-Field <placeholder> -Type <words>` writes
  into a field and presses Enter; `-Read <automation id>` prints an element's words (`TaskState`, `NeedsCount`);
  `-Has <words>` says whether an element with those words shows. `-NoEnter` leaves out the Enter after the words: a
  whole code sends itself, and an Enter would press what holds the focus on the next page.
- `motion.py` counts, for each agent of the sample, the frames in which its mark and its line changed; `changes.py`
  counts the frames in which any part of the screen changed.

### The store against a scratch hub

`scratch_hub.py` serves the scratch hub of `app_decode.py` on the Mac (a temporary database and configuration,
nothing of the machine's), makes the VM a PC owner device, and prints the hub's address as the VM reaches it
(`http://10.0.2.2:<port>`) and a code. Run it from the repository's root, in the background; it then takes the words
`need`, `line`, `code` and `quit` from the file `commands` in its folder and logs each change, and each answer to
`/ui/wait`, `/ui/mobile` and `/ui/owner/enroll`, with the Mac's time, to `changes.log` there.

```
python3 -I app/windows/vm/scratch_hub.py > hub.out &
app/windows/vm/vm.sh desktop '$env:FOUNDERIZER_HUB = "http://10.0.2.2:<port>"; $env:FOUNDERIZER_DEVICE_CODE = "<code>"; $env:FOUNDERIZER_STORE = "C:\fz\store-test"; Start-Process C:\fz\out\arm64\Founderizer.App.exe'
echo need > <folder>/commands
app/windows/vm/vm.sh desktop '& C:\fz\setup\ui.ps1 -Field "Message Manager" -Type "A message from the PC."'
```

An enrollment is logged with the kind of app that it sends (`answered enroll, kind windows`), which the hub names "PC"
(`OWNER_DEVICE_KINDS`). The PC enrolls as the scratch fleet's own device `pc`: the hub's route for a new device commits
`team.json`, and the scratch kit has no remote to commit to. Slice 1.5's flows run on the release build: a clean start
(its folder removed) opens Add this PC; Settings, the scratch hub's address and Enter connect; Add this PC and the word
`code`'s code enroll; a restart reads with the kept key; Forget the key opens Add this PC again.

The writes of the PC show in the hub's database (`pilot.db` in the folder), each with the client
`founderizer-windows/1`: a message and a typed answer in `ui_requests`, a pressed option in `needs` (`answer`,
`answered`, `chosen`), Pause and Stop in `holds` and `ui_controls`, guidance in `steers`.

### Readings

`FOUNDERIZER_TIMING_LOG` makes the app write `first-page <ms>` (from the process's start to the first frame of its
first page) and, for each change of the store's state, `change-to-frame <ms> <what the pane shows differently>`
(from the store's change to the next frame). `readings/start-time.exe` (from `start-time.cs`) starts the app several
times and reads the window's events and its memory at rest. `readings/cpu-at-rest.ps1` reads the processor time of
the app and of the compositor over a minute. With `FOUNDERIZER_READING=long-chat`, the log gets `scroll-start` (the
window's frame interval at rest, the median of 120 frames), then the chat goes from its end to its start, 64 pixels a
frame, and the log gets `scroll-end` (the frames, their median, 99th percentile and longest interval), a `scroll-long`
line for each frame longer than twice the interval at rest (with the rows that came into view in it, the views made
and the garbage collections), and every interval (`scroll-intervals`).

## The device key

The key that the hub gives this PC at enrollment stays in `%LOCALAPPDATA%\Founderizer\device-key`, outside the store's
folder, written by the library's `FileKeyStore` through the window's `UserKeyProtection`: Windows' protection of the
signed-in user's data (DPAPI, `CryptProtectData` for the current user, with the app's own purpose as entropy). The file
is DPAPI's blob, with no text of the key in it; only this Windows user on this PC opens it, and only with the app's
purpose; its access list is the one of the user's LocalAppData (the user, SYSTEM, Administrators). Forget the key
removes the file.

The TPM is a later choice. It would add a key that no program can copy off this PC (a TPM key is used where it is and
never exported), so a copy of the user's files with his Windows password would not carry the key away. It costs: the
hub's key is a bearer key that each request sends, so the TPM could only seal it (the same reach as DPAPI, bound to the
chip), and the real gain needs a TPM signing key that the hub checks instead (the enrollment's `signing_key`, which the
hub already takes); a TPM operation takes tens of milliseconds, some PCs and VMs have no usable TPM, and
a cleared TPM (a firmware update, a new motherboard) loses the key, so the PC needs a new code. The readings of slice
1.0 show that the TPM's P-256 signing works in this VM.

## The owner's private network

The VM can join the owner's Tailscale network as one machine of his, as a customer's PC does (slices 1.5 and 1.7
need it; the owner's yes of 13 November 2026, "Yes, join it"). The download is above, checked before it runs. Tailscale's
service is the one new service in the VM; nothing new starts on the Mac.

```
app/windows/vm/vm.sh run 'Start-Process msiexec.exe -Wait -ArgumentList "/i", "C:\fz\downloads\tailscale-setup-1.104.7-arm64.msi", "/qn", "/norestart", "TS_NOLAUNCH=true"'
app/windows/vm/vm.sh run '& "C:\Program Files\Tailscale\tailscale.exe" up --unattended --shields-up --ssh=false --accept-routes=false --exit-node= --advertise-routes= --hostname=<name> --timeout=20s'
```

- `up` prints a sign-in link for one use and waits. Nobody here opens it: it goes to the owner, who signs the
  machine in on Tailscale's own page. No key, token or login of his is used for the join.
- The settings: unattended (it stays connected with nobody signed in at its window), shields up (no connection from
  the network reaches the VM), no Tailscale SSH, no routes accepted or advertised, no exit node; `tailscale debug
  prefs` shows them. The VM's name on the network says what it is (for example `founderizer-windows-vm`).
- The installer puts Tailscale's tray app into the common Startup folder; the VM's join moves that shortcut to
  `C:\fz\downloads\Tailscale-startup.lnk`, so nothing but the service starts by itself, and the desktop of the
  pictures stays as it was.
- `tailnet/find-hub.cs` runs the library's own search for the hub (`Tailnet.FindAsync`, `GET /health` on port 8765
  of each device of the network) and prints the hub's address; no address is written into a file of this folder.
  Copy it to `C:\fz\src\windows\vm\tailnet\` beside the copied `Founderizer.Core` and run `dotnet run find-hub.cs`.

## The second set of pictures in the VM

The states of `~/dev/founderizer-plans/windows-app-pictures-2.md` (the owner's "Yes, as shown") are drawn from the
library's models, as the first set's. For their pictures, the proofs' build takes one more variable:

| `FOUNDERIZER_SAMPLE_STATE` | The state (`Fleet/SampleStates.cs`) |
| --- | --- |
| `code-refused` | picture 8: no hub yet; the code that he types is refused (403) |
| `not-enrolled`, `no-answer` | 9a, 9b: the hub no longer knows this PC; the hub does not answer; the reading 4 minutes old |
| `not-sent` | 14: his message to Customer Support waits, not confirmed |
| `answered`, `all-answered` | 16, 12: his answer to the refund at 15:12; both requests answered |
| `files` | 4: his message with a picture and a file, and a file in Marketing's composer |
| `failed`, `paused`, `stopping` | 5, 6a, 6b: a result that failed; a pause, then a stop, on the Developer's task |
| `usage`, `marks`, `reading`, `notify` | 7, 15, 13, 10: a usage reading; an agent at its limit and one not answering; the first read; the notification of the email's request |

Pictures 1, 2a, 2b and 9c are the sample as it is, with presses. Picture 3 (Discuss) has no state any more: Discuss
left the product (the owner, 13 November 2026), and each picture that shows it differs from the built one by it. The helpers in `pictures/` (copy them to
`C:\fz\run\`): `window.ps1` waits for the window and says whether it is in front, `start-menu.ps1` starts the app as
the owner does (the Windows key, its name, Enter), `size.ps1` asks Windows for a client area (the least size),
`keys.ps1` types keys, `notify.ps1` pictures Windows' notification while it shows, `toastpress.ps1` presses the next
notification with the mouse, and `reveal.ps1` brings up the taskbar that hides by itself (the taskbar's count). With a
store against `scratch_hub.py`, its word `settle` (the helper confirms a hold) stands in for the agents.

## The release in the VM

The install, the update and the removal of slice 1.6 (`../release/README.md`) are proved in the VM against a test
channel on the Mac, with the proofs' build: only it reads the test channel's address, its certificate and its key,
from the user's environment, so that the app that the Start menu entry starts reads them too.

```
python3 -I app/windows/vm/test_channel.py setup --folder <folder>    # once: the test key and the TLS certificate
python3 -I app/windows/vm/test_channel.py serve --folder <folder> &  # https://10.0.2.2:58443 for the VM
python3 -I app/windows/vm/test_channel.py offer --folder <folder> --zip <build's zip> --version 0.1.1 --build 2 --arch arm64
```

- `setup` prints the proofs' variables: `FOUNDERIZER_UPDATE_CHANNEL` (the channel), `FOUNDERIZER_UPDATE_KEY` (the
  test key's public half; its private half stays in the folder, mode 600) and `FOUNDERIZER_UPDATE_PIN` (the SHA-256
  of the channel's certificate, the one certificate that the proofs' build takes). `FOUNDERIZER_UPDATE_EVERY` and
  `FOUNDERIZER_UPDATE_AWAY` shorten the hour and the two minutes to seconds; `FOUNDERIZER_UPDATE_FAIL_BUILD=<build>`
  ends that build before its first good start (the way back).
- Set them for the user in the desktop session (`[Environment]::SetEnvironmentVariable(<name>, <value>, 'User')`):
  Explorer takes them at once, and the Start menu entry then starts the app with them. Remove them after the proofs.
- `offer` signs a manifest with the test key (the hub's own `releases.sign`); `--tamper signature` or `--tamper sha256`
  makes the refused ones, `--slot arm64 --arch x64` offers the other kind of PC, `--cut` stops the next download of
  that zip after half of its bytes. `none` offers nothing. Each request is a line of `requests.log` in the folder.
- The channel listens on 127.0.0.1 only: QEMU's user network brings the VM's calls to 10.0.2.2 there, and nothing of
  the private network or the LAN reaches it.

## Limits

- **Windows is not activated** in the VM, so after a while Windows draws "Activate Windows" in the screen's bottom
  right corner; a picture that compares the whole screen counts it (0.1 of 255).
- **No graphics card.** Windows and WinUI draw with the software renderer (WARP). Pictures are correct; speed
  numbers are not the reference numbers of the plan's rule 6. Those come from the real PC.
- **The TPM is swtpm**, a TPM 2.0 in software on the Mac. A reading with it proves the Windows and .NET side, not a
  real TPM's behaviour.
- **x64:** the VM compiles the x64 build and makes its zip and its setup; it does not prove that the x64 build runs.
- **Native AOT** (plan rule 7) needs, on Windows, Visual Studio's "Desktop development with C++" (Microsoft's
  Native AOT prerequisites). It is not in this VM and was not tried; the builds here are self-contained, with JIT.
- The ARM64 build is 455 files and 194 MB (the .NET runtime and the Windows App SDK, self-contained, not trimmed).

## The readings of slice 1.0, 13 November 2026

The programs are in `readings/`; their full output is in the session's report. Both ran in the desktop session of
`builder`, as the app will.

- **Keys in the TPM** (`tpm-keys.cs`): the "Microsoft Platform Crypto Provider" reports `TPM-Version:2.0
  -Revision:1.64-VendorID:'IBM '` (swtpm) and the hardware flag. A P-256 signing key made there signs in DER form
  (70 to 72 bytes), and the signature verifies in software with the exported public key; a changed message does not
  verify. A P-256 key agreement key made there agrees a raw secret of 32 bytes, equal to the software side. Two
  facts for slice 1.5: the provider refuses an ECDH key with a key usage property (`0x80090029`), and .NET's
  `ECDiffieHellmanCng` cannot agree with a TPM key, because the peer's public key must be imported into the TPM's
  provider (.NET gives "The supplied handle is invalid" or "Invalid flags specified"); the reading calls CNG
  directly (`NCryptImportKey`, `NCryptSecretAgreement`, `NCryptDeriveKey` with `TRUNCATE`).
- **Start and memory** (`start-time.cs`, the ARM64 build of `../Founderizer.Windows`, 6 runs, 10 seconds at rest):
  the first start after a fresh boot showed the window after 1,549 ms in one reading and 2,955 ms in another (the
  Mac's load was 7 and 10); the later starts after 152 to 247 ms. At rest: about 90 MB working set and 22.5 MB
  private bytes. The window is never cloaked, so "painted" here is the moment
  the window shows, not a measured first frame. These are not the plan's reference numbers (no graphics card, a VM,
  a busy Mac).

## The readings of slice 1.2, 13 November 2026

The signed ARM64 Release build, in the desktop session of `builder`, with the sample fleet (Customer Support and
Developer at work) unless it says otherwise. **The VM has no graphics card**: WinUI and the compositor draw with WARP,
in software, on the processor, and the Mac ran other threads' work beside it (load 6 to 14). These are not the plan's
reference numbers; those come from the real PC.

- **Cold start to the first page:** 1,260 ms for the first start after a restart of Windows, then 437 to 473 ms
  (`first-page`; the window showed 952 ms, then 324 to 337 ms, after the start). The first start of new files is
  slower: 10.8 s once, right after a new build, and 2.65 s for the first start of a fresh copy of the same build (then
  462 and 476 ms). Windows' real-time protection is on; that its scan of the new files takes that time is likely, not
  proved.
- **Memory at rest:** a working set of 209 to 213 MB and 41 MB of private bytes after 10 seconds (the empty window of
  slice 1.0: about 90 MB and 22.5 MB).
- **Processor at rest, with two agents at work:** over 60 seconds, the app 8.09 % of one core and the compositor
  process (dwm) 4.94 %. With the animation effects off, nothing moves: the app 0.16 % and dwm 0.03 %. The motion runs
  off the UI thread (the frames do not change when the UI thread sleeps), but WinUI's compositor runs in the app's
  process, and without a graphics card WARP draws each frame there.
- **From a wait's answer to the change on screen**, 10 changes from `scratch_hub.py`: the hub answered the store's
  next `GET /ui/mobile` 2 to 6 ms after it answered `/ui/wait` (the Mac's clock: the answer's way to the VM, the
  store's new request and its way back), and the frame came 7.2 to 15.1 ms (median 9.5 ms) after the store's change
  (the VM's clock). The part between, the mobile answer's way back and the store's decoding, has no common clock and
  is not measured. Before the wait's answer, the hub gathers changes for 0.25 s (`WAIT_GATHER`).

## The readings of slices 1.3 and 1.4, 13 November 2026

The signed ARM64 Release build, in the desktop session of `builder`. **The VM has no graphics card**: WinUI and the
compositor draw with WARP, in software, and the Mac ran other threads' work beside it (load 8 to 10 during these
runs). These are not the plan's reference numbers; those come from the real PC.

- **A chat of 2,000 messages scrolls from its end to its start** (`FOUNDERIZER_READING=long-chat`, 64 pixels a
  frame, 2,657 frames in 44.7 s): the window's frame interval at rest is 17.9 ms; during the scroll the median frame
  is 16.5 ms, the 99th percentile 30.6 ms and the longest 62.6 ms; 12 frames are longer than twice the interval at
  rest (35.9 ms), and 11 of them are frames in which a row came into view, whose words are then laid out and drawn
  for the first time. 2,029 rows came into view, and 33 row views were made for them: the list reuses its views. A
  new state of that chat reaches its frame in 19 to 32 ms. Its first page came 569 ms after the start.
- **Memory and processor at rest on the chat page**, over 60 seconds: Fleet Manager's chat, with the pane's two
  agents at work, 8.79 % of one core for the app and 4.99 % for dwm, 243 MB working set and 61 MB private bytes;
  with the animation effects off, 0.21 % and 0.00 %. Customer Support's chat while it works (the "Thinking" line,
  the pill's and the panel's marks move as well): 29.15 % and 7.67 %. Each moving mark is drawn in software at
  each frame: about 10 % of a core each for the pill's and the panel's marks.
- **The content area's rounded corner** (W4) is drawn over the page, not as a clip of it. As a clip it made the
  software renderer draw the whole page again at each frame of a mark that moved in it: 46.8 % against 27.1 % of a
  core on a chat while its agent works (a Debug build, 20 seconds each), and a scroll frame of 28 ms at the median
  against 16.5 ms.
