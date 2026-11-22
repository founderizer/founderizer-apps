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
| `proof-a/` | the rig of step 2's proof A: the clean PC beside the build VM, the setup with the welcome page, the window watcher, the hidden prompt, the read of the hub's team and its reference, the servers of run 2 (see "Proof A: the rig") |

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
app/windows/vm/vm.sh run 'New-Item -ItemType Directory -Force -Path C:\fz\src\windows, C:\fz\src\vectors, C:\fz\setup | Out-Null'
app/windows/vm/vm.sh copy app/windows/Directory.Build.props app/windows/global.json app/windows/nuget.config \
    app/windows/Founderizer.Core app/windows/Founderizer.Install app/windows/Founderizer.Owner \
    app/windows/Founderizer.Remote app/windows/Founderizer.Setup app/windows/Founderizer.Windows vm:C:/fz/src/windows/
app/windows/vm/vm.sh copy app/vectors/agent-marks.json vm:C:/fz/src/vectors/   # Founderizer.Core embeds ../../vectors/agent-marks.json
app/windows/vm/vm.sh copy app/windows/vm/setup/build-window.ps1 vm:C:/fz/setup/
app/windows/vm/vm.sh run 'powershell -NoProfile -ExecutionPolicy Bypass -File C:\fz\setup\build-window.ps1 -Source C:\fz\src\windows\Founderizer.Windows'
app/windows/vm/vm.sh desktop 'Start-Process C:\fz\out\arm64\Founderizer.App.exe'
app/windows/vm/vm.sh picture /tmp/window.png    # a picture of the desktop, taken in the VM
FZ_VM_USER=<session> app/windows/vm/vm.sh hold  # before a proof run: the VM is this session's, no update restarts it
FZ_VM_USER=<session> app/windows/vm/vm.sh release  # after the run: Windows' updates as before, and the VM free again
                                                # (only the session that holds it; no name, no hold and no release)
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
  still install. **This policy did not hold:** at 02:28 UTC on 14 November 2026 Windows Update restarted the VM with
  the user signed in (System event 1074: `MoUsoCoreWorker.exe`, "Service pack (Planned)", then `TrustedInstaller.exe`,
  "Upgrade (Planned)"). So a proof run goes between `vm.sh hold` and `vm.sh release`. `hold` uses Windows' own pause of
  updates (the values that Settings > Windows Update > Pause writes, for one day; Settings then says "Updates paused
  until ...") and makes the next 18 hours Windows' active hours, in which Windows restarts for no update; it refuses
  while a restart already waits (exit 3), so that the restart comes before the run, not in it. `release` takes the
  pause away and puts the active hours back as they were. Neither restarts Windows: a restart also ends a Tailscale
  sign-in link that waits for the owner (the restart of 14 November did, and the VM needed a new link).
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
| `FOUNDERIZER_TAILSCALE_STATUS` | a file whose text stands for this PC's `tailscale status --json` in the store's search and in the first run (`Fleet/TailscaleSetup.cs`, `PcTailscale`), read again at each read; `none` is a PC with no Tailscale. With it the app runs no program of Tailscale's (no `tailscale up`), so the first run's pages are proved without the VM's own network, which is the owner's (plan v2, 8.15); Connect still downloads, checks and starts Tailscale's real installer, whose administrator's question the proof answers No |
| `FOUNDERIZER_THREAD_TRACE` | `1`: each measure of a chat's or a task's view, its rests, its changes (inertial or not) and his hand, into the debug log (how the end of a long thread was measured on 14 November 2026) |
| `FOUNDERIZER_SETUP_READINGS` | a folder: the manager's first setup (piece U3) reads its `servers.json`, `machines.json` and `fleet.json` at each read, in place of the hub's owner routes, and logs each write by its route alone to `writes.log` there (see "The manager's setup against a stand-in") |
| `FOUNDERIZER_SETUP_SAMPLE` | `checks` or `approve`: the first run's page shows that state of the hub's install (checks that did not pass, with Open Founderizer; the join of the manager's server waiting at Tailscale's link), which no stand-in of U2 reaches |

The argument `-openPage needs|tasks|activity|settings|agent.<name>|task.<id>` opens that page first, as the Mac app's
does.

**The first run (step 2, piece U1)** is only in a build with `-p:FounderizerWelcome=true` (`Fleet/FirstRunSwitch.cs`;
no build that a person gets has it before pieces U3, U4 and U5, plan v2 section 13). A clean start of such a build with
no Tailscale running, or none with a hub on it, opens the welcome page. Take the VM's Tailscale down first
(`tailscale down`), and up again after with the settings of "The owner's private network" below: a step-2 proof never
uses the owner's network. `pictures/rest.ps1` brings the window to the front with one click on its title bar's empty
middle and leaves the pointer there (`-NoClick`: only the pointer), and `pictures/click.ps1 -X <x> -Y <y>` clicks one
point (the slider of "Your fleet's servers"); both take the screen's 96-DPI points (1440 by 900), so a point of a
picture is half its pixel.

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
- **A page by its elements** (piece U1, after its first review: a page can be near a picture by its pixels and still
  have a card of the wrong width or a missing line): `elements.ps1` prints every element of the window as UI
  Automation sees it (its type, its automation id, its rectangle in the screen's pixels, its words), and `elements.py`
  checks that dump against a set's list of each picture's words and measures (`set8-elements.json` for the first
  run's pictures 1 to 7: each word of the set's table, each card's and field's place and size, Back's place, the
  steps on Back's line, and what must not be there, such as Windows' clear button in a field):

```
app/windows/vm/vm.sh desktop '& C:\fz\setup\elements.ps1 -Out C:\fz\page.tsv'
app/windows/vm/vm.sh copy vm:C:/fz/page.tsv page.tsv
python3 -I app/windows/vm/pictures/elements.py app/windows/vm/pictures/set8-elements.json 02-help-improve page.tsv
```

### The first run's servers against stand-ins (step 2, piece U2)

Never the owner's network: take the VM's Tailscale down first (`tailscale down`), and up again after with the settings
of "The owner's private network". With Tailscale down, the rule `fz-tailscale-range-only-through-tailscale` stops each
call to an address of 100.64.0.0/10, so a server that "joins" in a status file stops at its first SSH call. **Do not add
an address to the VM's card** (`New-NetIPAddress` on `Ethernet` turned its DHCP off, and SSH from the Mac stopped until
a PowerShell on the VM's own screen took it back).

- **The providers**: `python3 -I app/windows/vm/provider_standin.py > standin.out &` answers Tailscale's and Hetzner's
  APIs from the library's own vector files, on the first free port from 58459 down (the VM reaches the Mac on 58440 to
  58459 only). A proofs' build with `FOUNDERIZER_PROVIDERS=http://10.0.2.2:<port>` sends each provider's request there.
  Words in the file `commands` of its folder: `hold` and `go` (the hub's server waits at "Making your server"),
  `refuse` and `take` (servers of agents are refused with "Hetzner has no server free now."), `quit`. It logs each
  request (method, host, path; no header, no body) to `requests.log`, and writes the public line of the app's key that
  Hetzner was given to `app-key.pub`.
- **This PC's Tailscale**: `FOUNDERIZER_TAILSCALE_STATUS` (above) with `BackendState` `Running` and a private address of
  `Self`; a server joins when its name (`worker-1`) is a peer that is `Online` in that file.
- **A server for Other VPS**: a container of the Remote tests' image with root by key, systemd's mark and a stand-in of
  `tailscale` that waits 90 seconds and fails (nothing is downloaded), published on 127.0.0.1:58451 (keys only) and
  58452 (keys, password and keyboard-interactive); the address on the page is `10.0.2.2:58451`.
- **The owner's keys**: made for the proof (by this Mac's `ssh-keygen` with its passphrase on a helper's input, or by
  Windows' own `ssh-keygen` in the VM), in `%USERPROFILE%\.ssh` of the VM while the proof runs. A passphrase is typed
  into a page with `vm.sh type` (letters, digits and "-", from standard input), or, with a letter outside ASCII, through
  a named pipe of the desktop session that types Windows' Unicode keys: the words come on SSH's standard input, never in
  a command line, a file, a log or a picture. Windows' picker takes the file's name as keys of the VM's keyboard
  (QEMU's `send-key`, as `vm.sh type` sends them).

### The manager's setup against a stand-in (step 2, piece U3)

A proofs' build with the welcome page, started on the manager's page with `-openPage agent.juno` and
`FOUNDERIZER_SETUP_READINGS`, shows the manager's first setup over the files of that folder. Each state is a folder of
four files (`servers.json`, `machines.json`, `fleet.json`, `team.json`) that `setup_states.py` writes (the install of
picture 18, the sign-ins of pictures 19 and 20, the session's start, a manager with no server yet, the manager that
runs, and the server's page of Other VPS with "2 servers", which keeps the window's pane); a proof copies one into the readings folder,
and the next read of the setup (2 to 5 seconds) shows it. `fleet.json` holds the manager's row (`runtime`, `alive`,
`title`) and the mark that a hand-over would have kept (`provider`, `joined`), which the setup reads once, at its start.
The data are set 8's examples (`worker-2`, `KDRT-7QXP`); a code typed into Claude Code's field goes nowhere but the
setup's write, which `writes.log` names by its route. A press on a provider's card asks for the sign-in, so the sign-in
page that follows opens its link in the default browser by itself (the Mac's rule): Edge opens in the VM, and the proof
closes it. Nothing reaches a hub, a provider or a tailnet.

```
app/windows/vm/vm.sh desktop '$env:FOUNDERIZER_SETUP_READINGS = "C:\fz\u3\readings"; Start-Process C:\fz\u3\out\Founderizer.App.exe -ArgumentList "-openPage", "agent.juno"'
python3 -I app/windows/vm/pictures/elements.py app/windows/vm/pictures/set8-elements.json 19-sign-in-claude-code page.tsv
```

### The store against a scratch hub

`scratch_hub.py` serves the scratch hub of `app_decode.py` on the Mac (a temporary database and configuration,
nothing of the machine's), makes the VM a PC owner device, and prints the hub's address as the VM reaches it
(`http://10.0.2.2:<port>`) and a code. Run it from the repository's root, in the background; it then takes the words
`need`, `quick` (a request with no options of its own: the app's quick replies), `ticks` (a request whose options combine), `line`, `marks` (a reply with bold, italic, code and a link), `markdown` (a reply with a heading, a list, code and a link), `result` (Task 1 ends with an accepted result), `outputs` and `nooutputs` (its result names two checked outputs in a Git repository of the folder, a text file and a picture, or none), `steps` and `step` (Task 2's thread on Claude Code: 8 steps with one that failed and one that changed a file, the agent's message and 2 steps more; one step more; `manysteps`: 120 steps more in its last run), `permission` (Task 2 waits for a permission of Bash), `park` (its agent parks Task 2 until the next full hour), `thought`, `script`, `child`, `plan` and `cut` (Task 2's thread gets a thought, a Codex script that made a call, a child agent with its steps and words, the plan of the work that runs with a step that runs, the record's cut), `error` (its attempt ends with a call that never finished and an error, and attempt 2 starts), `guidance` (his guidance, read), `long` (90 rows more), `subtasks` (a parent task and two subtasks), `failread` and `readok` (each read of Task 2's record fails with 503, or answers again), `ended400` (400 ended tasks over the last six days: 3 failed, 60 runs of one schedule, the rest with titles of their own), `slowchat` and `fastchat` (each chat read 8 s late, or at once), `settle`, `two`, `code` and `quit` from the file `commands` in its folder and logs each change, and each answer to
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
- **Only Tailscale's own card reaches his network.** For the next person who makes a VM: a VM on QEMU's user network
  leaves with the Mac's own place in every network, so a hub that knows the owner's Mac by its address takes the VM for
  the Mac, unless the VM's own Tailscale carries that traffic or the VM blocks it. A call from the VM to an address of
  his network that its Tailscale does not carry leaves with the Mac's own address there. Measured on 14 November 2026: with Tailscale down in the VM, the hub's
  owner page answered 200 with no key; with Tailscale up, 403. The firewall rule
  `fz-tailscale-range-only-through-tailscale` (outbound, block, 100.64.0.0/10 and fd7a:115c:a1e0::/48, on every card
  but Tailscale's) closes it: with Tailscale down, no connection reaches his network at all. `setup/first-logon.ps1`
  makes it at a new VM's first start; an older VM takes it with the same `New-NetFirewallRule` over `vm.sh run`.
- **The Mac's own services stay out of the VM's reach.** The same network gives the VM every service that listens on
  the Mac's loopback, at 10.0.2.2 (on 14 November 2026, 65 of the Mac's 71 listening ports answered from the VM,
  among them 56 local servers of Claude Code). The VM reaches 10.0.2.2 only on 58440 to 58459, the ports of its test
  servers: the test channel's 58443, and a scratch hub's first free port from 58444 (`scratch_hub.py`). The rules
  `fz-host-only-test-ports-tcp` (outbound, block, every other TCP port of 10.0.2.2) and `fz-host-no-udp` hold it;
  SSH comes in from the Mac, and its answers go back on that connection, which no outbound rule stops.
- The settings: unattended (it stays connected with nobody signed in at its window), shields up (no connection from
  the network reaches the VM), no Tailscale SSH, no routes accepted or advertised, no exit node; `tailscale debug
  prefs` shows them. The VM's name on the network says what it is (for example `founderizer-windows-vm`).
- The installer puts Tailscale's tray app into the common Startup folder; the VM's join moves that shortcut to
  `C:\fz\downloads\Tailscale-startup.lnk`, so nothing but the service starts by itself, and the desktop of the
  pictures stays as it was.
- `tailnet/find-hub.cs` runs the library's own search for the hub (`Tailnet.FindAsync`, `GET /health` on port 8765
  of each device of the network) and prints each device that it asks by its number, its answer and its time, and which
  number is the hub: no name and no address of the network, so its lines can go into a report as they are.
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

## Proof A: the rig

Proof A of step 2 (`~/dev/founderizer-plans/windows-app-plan-v2.md`, section 11; the rig's plan
`windows-proof-a-rig-plan-2026-11-22.md`) runs the release build's setup on a clean PC, with the owner's sitting. Its
tools are in `proof-a/`. The clean PC is a second VM beside the build VM, in a folder of its own; the build VM keeps
its own hold rules and is used only to build. The tools write their files to `$HOME/VMs/founderizer-windows-proof-a-files`
(`FZ_PROOF_A_FILES`), outside any repository: the setup, the test certificate's public part, the logs, the references.

| Tool | What it does |
| --- | --- |
| `build-setup.sh` | holds the build VM (`vm.sh hold`), stops when a variable whose name starts with `Founderizer` is set there (`FounderizerProofsOn=true` turns the proofs' parts on in any build), builds this checkout's commit with a copy of `release/build-release.ps1` in which `-p:FounderizerWelcome` is `true` (the copy is in the build VM only), checks that `builds.json` says no proofs, that `Founderizer.App.dll` names no `GetEnvironmentVariable` and that the setup's signature is valid, and copies out the setup and the test certificate's public part |
| `clean-pc.sh` | `base`: the clean PC's base VM with `vm.sh create` (no Tailscale, no developer tool; the checks of `check-clean.ps1`); `copy <name>`: an APFS copy of the stopped base (`cp -c`) on its own SSH port, the test certificate trusted (`trust-certificate.ps1`), the session's helpers copied in, the clean checks, `vm.sh hold`; `env`, `check`, `list`, `remove` |
| `watch.sh` (`watch.ps1`, `watch-task.ps1`) | the window watcher in the copy's desktop session (a scheduled task under `conhost --headless`, so it has no window): each top-level window that becomes visible, with its class and its program, from Windows' own show events and a sweep every 100 ms; `stop` and `read` give the log and a summary that fails on a console (`ConsoleWindowClass`, Windows Terminal's window, or a console program) or on a window that could not be read |
| `secret.sh` (`focus.ps1`; `type-pipe.ps1`, `type-task.ps1` on a PC with no QEMU keyboard) | the hidden prompt (from `add-test-pc.sh`): it types into the field that has the focus only when that field is an empty field of Founderizer's window (and, with `--field`, the one of that automation id); it reads the value with no echo and types it with `vm.sh type`, which also takes `_` and `#` now (Shift on the VM's US keyboard, for a sign-in code); after the keys, on every path, it reads the focus (the program and the element's automation id) and the field's length against the count of characters, and presses Enter only when the focus is still on that field of Founderizer.App and the field holds them all (only a password box may give no length; a field with no value is refused); it says whether the field is empty or gone after, and logs the field's name, never the value. From the keys until the field is empty or gone, the mark `value-on-screen` in the copy's folder makes `vm.sh picture` and `vm.sh screen` refuse (a token's field shows each character); when the keys did not all stay in the field, the mark stays whatever the field says, because some can have gone to another window or element; `logs/secret.log` names where the focus is and, apart from it, how many characters the field itself holds (read by its automation id; names and counts, no value). The way out, in that line and in the refusal of `vm.sh`, is both steps, never one of them: empty the field (`pictures/pick.ps1 -Field`) and close the window that took the keys with no save and no picture (in Founderizer's own window, which stays open until the claim: empty that element), then remove the mark. A password box shows no character, and `pick.ps1 -Field` may not empty one (it sets the value through UI Automation's ValuePattern, which a WinUI PasswordBox may not give): for a password box only the window step applies, and the log line and the refusal say so. Before `secret.sh` runs again for a password box that took a part of a value, the session empties the box (a click in it, Ctrl+A, Delete): a password box gives no length, so `secret.sh` takes it with the part in it, and the whole value goes after the part (that step then fails, with no leak). When the desktop or the taskbar took a key (`focus.ps1` names explorer), nothing is closed: a character there shows no text, and explorer is not ended. `vm.sh desktop` refuses `pictures/frames.ps1`, `notify.ps1` and `toastpress.ps1` while the mark is there too. A mark left behind on a failure or a Ctrl-C is the safe side: the session looks, empties, and removes it. On the Server PC at Azure the value goes on SSH's standard input to a named pipe of the desktop session, whose typer sends Windows' own key events into that field only: it reads UI Automation's focused element before the first key, the window in front before each key (it stops at the first change), and the focused element and the field's length again before Enter |
| `team.sh` (`team-read.ps1`, `team_compare.py`) | `read`: in the copy's desktop session, the PC's own key for the hub from the app's secret box (in memory only), `GET /ui/mobile`, `GET /ui/team` and `GET /ui/servers`, and a file with no key and no address: each agent's line, each machine with an agent, each server (the hub's or not, its placed agents, its SSH user and port), whether the hub's server takes agents, and the step of the fleet's servers. `compare`: that read against a reference, "but for the names". What stays outside, because no owner read gives it: each agent's start line, the goals, the hub's port, the servers' `kind` and `user` entries, and the addresses |
| `team-reference.sh` | the reference, made with no owner in the agent-install rig of `~/dev/founderizer-plans/agent-install-test/rig` (Tart VMs on a Headscale test network). It is the Mac's install line for the same choices (the programs of `app/vectors/remote-install.json`, the Mac's own plans), and for "2 servers" this script's own join and move with the hub's owner routes (`POST /ui/servers/join`, the join line, `POST /ui/team/agents/juno/move` with Codex): what the Mac app sends there, but not a run of the Mac app. `one` (1 server, the manager on Codex) and `two`; `keep-one`, `keep-two`, `place-two` go on from a run that broke off. It keeps `team.json` and the hub's own reads of it (`GET /ui/team` and `GET /ui/servers`), and their compare must find no difference |
| `bare-server.sh` | run 2's server for "Other VPS": a bare Ubuntu 24.04 server in the hcloud context `founderizer-test`, no SSH key, label `temporary=true`, root's password from a SHA-512 crypt hash that cloud-init sets; the password at a hidden prompt, then typed by `secret.sh` into the copy's password field; `delete` only a server with the labels of proof A |
| `azure-pc-make.sh`, `azure-pc-delete.sh` (`azure-pc.json`, `azure-pc-setup.ps1`, `azure-pc-elevated.ps1`) | the x64 clean PC of run 2 at Azure: Windows Server 2025 Datacenter with Desktop Experience, licence included, `Standard_D2s_v6` (never an Arm "p" size), Trusted launch with a vTPM, SSH by key from this Mac's public address only, no RDP, no boot diagnostics; the host key comes back through Azure's run command and the first SSH checks it; `what-if` changes nothing; each resource made and removed is a line of `azure/record.log`; the delete also removes the deployments at the subscription and names each group that was not there before the make. Both take only the subscription of that name in the tenant that `FZ_AZURE_TENANT` names (below). `elevated <since>` lists the run's elevated starts (the new process's user is the event's `TargetUserName`, else its `SubjectUserName`), and `probe` is the run's first step there: one elevated start on purpose, which the list must hold; `elevated` refuses on a PC whose probe did not pass, and a list from before the probe holds the probe's own `whoami.exe` |
| `team_standin.py`, `standin-key.ps1`, `standin-team.json` | the dry run's stand-in of the hub's three reads, and a key of the PC kept in the app's secret box as the app keeps one |
| `vps-check.sh` (`vps-build.ps1`) | one "Other VPS" check with the SSH library that the app carries (`Renci.SshNet.dll`): the proofs' build with the welcome page from a commit (`--want 2026.0.1`), in a copy, against a test server in a container of the Remote tests' image on 127.0.0.1:58452 (root by password, systemd's mark, a `tailscale` that waits and fails) and `provider_standin.py`; "1 server", the stand-in's Tailscale token and the password through `secret.sh`, Other VPS, the server's read, and Install |
| `primary-ips.sh` | before run 1: the primary IPs in use in the Hetzner projects of this Mac's hcloud contexts (each IP once) against the account's limit; read only |

A run, for the session (the owner's acts are his items of the rig's plan):

```
FZ_VM_USER=<session> app/windows/vm/proof-a/build-setup.sh                 # once for both runs
FZ_VM_USER=<session> app/windows/vm/proof-a/clean-pc.sh copy run1
export FZ_PROOF_A_COPY=run1; eval "$(app/windows/vm/proof-a/clean-pc.sh env run1)"   # vm.sh acts on the copy
app/windows/vm/proof-a/watch.sh start
app/windows/vm/vm.sh copy "$HOME/VMs/founderizer-windows-proof-a-files/build/<version>-<build>/Founderizer-Setup-<version>-arm64.exe" vm:C:/fz/proof-a/
app/windows/vm/vm.sh desktop 'Start-Process C:\fz\proof-a\Founderizer-Setup-<version>-arm64.exe'
app/windows/vm/vm.sh desktop '& C:\fz\setup\ui.ps1 -Click "#first-run-set-up"'   # each page as a person presses it
app/windows/vm/proof-a/secret.sh "Tailscale token" --field first-run-tailscale-key   # the owner, in his Terminal
app/windows/vm/proof-a/team.sh read; app/windows/vm/proof-a/team.sh compare <reference> <read>
app/windows/vm/proof-a/watch.sh stop
app/windows/vm/proof-a/clean-pc.sh remove run1
```

- The base VM is made once and never started again for a run: a copy is made from it while it is stopped.
- The clean PC has 2 cores and 8 GB (`lib.sh`; the build VM keeps 6 and 16 GB), and its screen is 2880 x 1800 at
  200 % (`check-clean.ps1` checks it: at 1024 x 768 the app's window stayed black).
- **How the base VM was made on 22 November 2026, and what to do the next time.** `vm.sh create` did not end by itself,
  three times. (1) Windows stopped at "Start boot option" (its boot manager): its cores busy, no disk write. This
  happened at a restart with the setup disc attached (cold or warm), with 6 cores and with 2. (2) At the first
  sign-in, the first-logon script did not run (no SSH came). (3) When the script was started by hand, its first step
  (`pnputil /install` of the setup disc's drivers, which Windows Setup had installed already) ended in a bug check
  0x50 (Windows Error Reporting's BlueScreen event in the copies), then in a stop at the boot manager. A hard stop in
  a Windows that started left it unable to start ("couldn't be repaired"). What worked: when the boot manager stops
  (no disk write for 150 s and a busy core), end QEMU and start the setup run again cold; at the desktop, start the
  first-logon script from the Run box as an administrator (Win+R, Ctrl+Shift+Enter, then Left and Enter on the
  question; "No" has the focus) with its `pnputil` line left out; then set the screen to 2880 x 1800 in the desktop
  session (`ChangeDisplaySettings` with `CDS_UPDATEREGISTRY`), stop, start cold, and run `clean-pc.sh check`. The
  base then started at once, every time, with no disc attached.
- No Start again exists on a window page yet, so each run uses a new copy, and the session removes what the app made at
  the providers from the app's own records.
- Before each hidden prompt, the session closes Edge in the copy (Tailscale's sign-in link opens it): a value typed into
  a browser's address field goes to its search suggestions, also with no Enter.
- Nobody closes the app's window before the claim: on the PC its X ends the app, and the first run then starts again at
  the welcome page (the Mac does the same after Quit; plan v2, section 12, "The rig of proof A as built").
- The setup is signed with the build VM's test certificate; each copy trusts its public part. SmartScreen and a file
  with the mark of the web are not proved (no download from the internet).

**Run 2 on Windows Server at Azure** (the owner's choice of 22 November 2026, "Windows Server (Recommended)"). Its clean
PC is `azure-pc-make.sh create` (only at the run, after his yes; `what-if` changes nothing), with the x64 setup
(`build-setup.sh --arch arm64,x64`); `azure-pc-make.sh forward` makes it the copy `azure` of the other tools, and
`azure-pc-delete.sh` removes it right after the run. Both Azure tools need `FZ_AZURE_TENANT`, the id of the tenant of the
subscription that pays, set in the shell of the session and in no file of the repository: `export FZ_AZURE_TENANT=<the
tenantId that az account list --all gives for that subscription>` (the rig's plan in `~/dev/founderizer-plans` names
the subscription). With no variable or another tenant, they stop before any call that changes something.

On that PC no session can press Windows' administrator question (no QEMU keyboard, and the question is on the secure
desktop). So `azure-pc-setup.ps1` lets an administrator's rise go on with no question there (`ConsentPromptBehaviorAdmin`
0), and keeps UAC on (`EnableLUA` 1). Azure makes the admin user from the built-in Administrator (its SID ends in
-500), whose Admin Approval Mode is off on Windows Server: with no limited token at all, nothing would start limited and
no start would count as a rise. So the setup also sets `FilterAdministratorToken` 1 (its restart puts it in force), and
the record says whether the user's SID ends in -500: the app and `vm.sh desktop` then keep their limited rights. The
loss: an elevation that
must not happen (for example, the x64 setup asking for one) passes unseen there. So the setup turns on Windows' audit of
process creation, and `azure-pc-make.sh elevated <the run's start>` lists each start of the run with a full
administrator's token, for the run's record. Its checks of proof A:

| Proved on the Server PC | Stays with the ARM VM (Windows 11) |
| --- | --- |
| the x64 build and the x64 setup run; Tailscale's x64 (amd64) installer through the app; a TPM 2.0 that is not swtpm (Trusted launch's vTPM); "Other VPS" with a password; the window watcher, the hidden prompt (through its pipe) and the team's read | Windows' administrator question (it shows, it names Tailscale, the app goes on after Yes: run 1 proves it); every page against its picture of set 8 (Windows 11's look, fonts and title bar); the welcome page's motion; run 1 with "2 servers" at Hetzner |

**The session's own step on the Azure PC, before the owner's item 9** (the rig's plan, section 8), in the same PC's
life as run 2. Each minute of that life counts in his yes (one small VM for about 2 hours), from `create` to the end of
`azure-pc-delete.sh`: so the session starts `create` when run 1's clean-up starts (after item 8, the first reply and the
records), and the make ends about when item 9 starts, with no idle wait through run 1. If the sitting stops, the PC
goes at once, as "When the PC's life does not go as planned" says below. Then, before he types anything for run 2:

1. `create` ends with "ready" only when its SSH session as builder can run `Get-Process -IncludeUserName`, which needs
   an elevated session: that proves SSH's full token for the built-in Administrator with `FilterAdministratorToken` 1
   on Windows Server 2025. A stop after 10 minutes ("no SSH answer with a desktop session of builder") means no such
   token or no signed-in desktop; the PC costs until `azure-pc-delete.sh`.
2. `azure-pc-make.sh probe`: it passes only when the list holds its elevated `whoami.exe` with `%%1937` under builder,
   in `TargetUserName` or `SubjectUserName`: that proves the fields of event 4688 on Windows Server 2025.
3. The watcher, the setup, and the pages to run 2's name page, as in run 1. There, the typer's stop once, with a test
   value of 298 characters (about 10 s of keys) and Founderizer's window minimized by a timer during the keys. Windows
   can refuse the front to a program that a scheduled task starts (more so while the typer sends keys), so a new
   Notepad may not change the window in front; a minimize always does:

```
export FZ_PROOF_A_COPY=azure; eval "$(app/windows/vm/proof-a/clean-pc.sh env azure)"
app/windows/vm/vm.sh desktop '& C:\fz\setup\pick.ps1 -Field "Name"'          # the name field: empty, with the focus
printf 'proofa-test-value-%s\n' "$(printf '0123456789%.0s' $(seq 28))" |
    app/windows/vm/proof-a/secret.sh "Test value" --field first-run-name --no-enter & typing=$!
while kill -0 "$typing" 2>/dev/null &&
    ! app/windows/vm/vm.sh desktop '& C:\fz\proof-a\focus.ps1 -Id first-run-name' | grep -Eq 'length=[1-9]'; do :; done
app/windows/vm/vm.sh desktop 'Add-Type -Namespace Fz -Name Win -MemberDefinition "[DllImport(`"user32.dll`")] public static extern bool ShowWindow(System.IntPtr h, int c);"; $h = (Get-Process Founderizer.App | Select-Object -First 1).MainWindowHandle; if ($h -eq 0) { "no window handle: nothing minimized" } else { [void][Fz.Win]::ShowWindow($h, 6); "shown with 6: $h" }'
wait                                                       # the timer above: the window minimized during the keys
tail -1 "$HOME/VMs/founderizer-windows-proof-a-files/logs/secret.log"
```

   The stop is proved when the log says "the typer typed k of 298; front" and another program with k under 298, and
   the field's own count apart from it; the mark stays and `vm.sh picture` refuses. The minimize's line says "shown
   with 6" and the window's handle; "no window handle" means that nothing was minimized, and then the log proves
   nothing about the stop. If the line said "shown with 6" and the log says that the field still holds characters
   (all 298 stayed in it), the minimize came after the keys: empty the field and run it once more. Then the way out:
   the same `vm.sh desktop` line with 9 (restore) in place of 6, `pick.ps1 -Field "Name"` (its click brings the window
   to the front and empties the field), and, if `focus.ps1` names a window that took a key, that window closed with no
   save (not explorer: when the desktop or the taskbar took a key, a character there shows no text, and nothing is
   closed); `focus.ps1 -Id first-run-name` says `length=0`; the mark goes; run 2 goes on with its real name.

The PC's life, all in the 2 hours: the make (not measured yet: Azure's deployment, its run command and one restart),
this step (about 10 minutes: `probe` about 1, the stage about 5, a second try about 4), run 2 (items 9 to 12) and the
delete. The session writes the times of `create` and of the delete's end into the run's record.

**When the PC's life does not go as planned** (his yes is one small VM for about 2 hours; the make's time is not
measured):

- When the sitting stops, at any item: stop `create` if it runs (Ctrl-C), and wait until `az deployment sub list
  --subscription <id> --query "[?starts_with(name,'proof-a-pc-')].properties.provisioningState"` shows no "Running"
  (while the deployment runs, Azure can refuse the delete with a conflict); then run `azure-pc-delete.sh`.
- When `azure-pc-delete.sh` does not end with "each resource of proof-a-pc-rg is gone" (or "no resource group
  proof-a-pc-rg" when nothing was made): it runs under `set -e`, so an `az resource delete` that fails stops it with
  az's own error and no "STILL THERE" line; its other faults end with "STILL THERE: <id>", "the group proof-a-pc-rg
  still exists" or a group that was not there before the make, and exit 1. Run it once more. If it fails again, tell
  the owner at once, through the coordinating session ("Windows app version"), that the PC still costs past his yes,
  with `az group delete -n proof-a-pc-rg --subscription <id> --yes` or the group's page in the Azure portal.
- When the PC is still there 2 hours after `create` started: tell him so (through the coordinating session), and go on
  only with his word.

What is known to differ on Windows Server 2025 (Desktop Experience): WinUI 3 and the Windows App SDK need Desktop
Experience (Server Core has no WinUI), and the app carries its Windows App SDK, so no Store is needed; Server has no
Microsoft Store; its console host is conhost, not Windows Terminal (the watcher counts both); Server Manager opens at
each sign-in of an administrator (`azure-pc-setup.ps1` turns that off); Azure's D sizes have no graphics card, so WARP
draws, as in the ARM VM; updates are off for the VM's life (`patchMode` Manual) instead of `vm.sh hold`. Not checked:
whether Tailscale's MSI, its service and `tailscale up` behave on Server 2025 as on Windows 11; Segoe UI Variable on
Server; Edge's first start on Server for Tailscale's sign-in link.

**The dry run, 22 November 2026** (no owner, no cost; the setup of `main` 229035ba7 with SSH.NET 2026.0.1, ARM64):

| Step | Result | Time |
| --- | --- | --- |
| a copy of the base (`clean-pc.sh copy`) | clone, start, certificate, clean checks, hold | 30 to 54 s |
| the watcher, shown a console on purpose | it logged Windows Terminal's window and its pseudo console: "consoles: 2" | start 11 s |
| the setup, started as a double-click | installed in 13 s with no administrator's question; the welcome page showed | about 40 s |
| the pages to Connect Tailscale | Welcome, "Don't send", the name, Codex, "2 servers" (and "1 server" at the slider's left end, `click.ps1 -X 488 -Y 398`) | 2.5 min |
| Connect | the MSI from Tailscale, then Windows' administrator question for "Tailscale Inc." ("No" has the focus: `vm.sh keys left ret` is Yes), then `tailscale up` with its link; Edge opened over the app with its own first-start pages | 1.5 min to the question, 15 s to the link |
| the hidden prompt | refused a field that was not empty, and the focus in Edge; typed a test value with "_" and "#" whole; with Enter, a token's field left and the page moved on | 15 s a value |
| the window watcher, the whole run | no console: the app, Windows Installer's dialog, WebView2, Tailscale's own tray program, Edge | |
| the window closed and opened again (launcher) at "Waiting for Tailscale" | the app opened on the welcome page, not on the page where it was | 20 s |
| the team's read against `team_standin.py` | the key from the secret box, both reads with it; the file has no key, no address and no live field; the compare: 0 differences with the stand-in's team, 1 with another runtime | 40 s |
| the references (`team-reference.sh`) | "1 server" and "2 servers" kept; each team.json and its GET /ui/team compare with 0 differences. The installer in the rig stopped at "security updates" when an update restarted Tart's agent (its start step has a scope of its own now); team.json and the claim come before it. Round 2 made "1 server" again with GET /ui/servers in the compare (below) | 20 min each |
| `vps-check.sh` with SSH.NET 2026.0.1 | the server's read with the password (keyboard-interactive), then the PC's own key (publickey, twice): "Ubuntu 24.04 · 8 GB · Arm", Install, "Joining your private network"; by hand, then once more as the script runs it | 5.5 min scripted |
| `bare-server.sh` | syntax; its cloud-init text valid (`cloud-init schema`) with a hash of a probe value; nothing made | |
| `azure-pc-make.sh what-if`, `azure-pc-delete.sh --what-if` | the subscription by its name, both providers Registered, `Standard_D2s_v6` offered with no restriction (NVMe, Trusted launch), 10 vCPUs free in its family; what-if: 6 creations; nothing made | 1 min |

Two faults that the dry run found in the rig and that are fixed: the team's read lost its port to a second `-match`,
and the clean PC's screen was 1024 x 768 (the app's window stayed black).

**Round 2, after Fable's read of `35a39b970`** (the same day; no server, no Azure VM, no token):

| Check | Result |
| --- | --- |
| Fable's changed teams against the references | each gives at least 1 difference now (they gave 0 before): "1 server" with no `shared`, no `shape` and no `servers` (2), a "2 servers" team whose manager never moved (3 against "1 server", 11 against "2 servers"), one more empty server (4), `shared` alone (1), `shape` alone (1 and 1); a team with only another start line, hub port and goals gives 0 |
| the team's read in a copy against `team_standin.py` | `GET /ui/mobile`, `/ui/team` and `/ui/servers` with the key from the box; the file has each server, `hub_shared` and `shape`, and no key or address; 0 differences with the stand-in's team, 1 with its shape changed |
| `team-reference.sh one` again | the installer reached READY in 6 minutes (its start step has a scope of its own now), and team.json against GET /ui/team and GET /ui/servers: 0 differences in 22 values. `two-team.json` stays the round-1 reference; its GET reads were not kept again |
| `bare-server.sh make` with a stand-in `hcloud` | a server made whose answer is not read: "the server proof-a-vps exists ... bare-server.sh delete proof-a-vps" (`35a39b970` said "nothing costs"); no server made: "nothing costs"; its cloud-init text the same as before, from `printf` |
| the Azure tools' tenant | with no `FZ_AZURE_TENANT`, or another tenant, they stop; with the right one, `azure-pc-delete.sh --what-if` reads the subscription |
| `secret.sh` in a copy | a value with no Enter: the mark stays and `vm.sh picture` refuses; with Enter on the same field: the page went on, and the mark went |
| the rig's PowerShell files in a copy | each parses; the C# of `type-pipe.ps1`, `watch.ps1` and `azure-pc-setup.ps1` compiles; `azure-pc-elevated.ps1` runs; `check-clean.ps1` with its Tailscale state check passes on a clean copy |

Fable's answers to round 2 (the same day): the "2 servers" reference stays valid, because its view equals the hub's own
rule value for value; make both references again if `hub.sh` or `hubsetup.py` changes before the sitting; the Azure
PC's host key cannot be fooled (it comes back through Azure's own run command); a mark left behind on a failure or a
Ctrl-C is the safe side.

**Round 3, after Fable's read of `3e01cc5e4`:**

| Check | Result |
| --- | --- |
| the focus left the field during the keys (a copy: Notepad open, Alt+Tab during the hidden prompt's keys, a test value; run at 18:40 UTC with round 4's `secret.sh`) | no Enter; the mark stayed and `vm.sh picture` refused; the log named Notepad as where the focus was (no value). The test value was whole in the app's field (52 of 52) and Notepad's text was empty: the Alt+Tab took effect after the last key |
| one elevated start on purpose with the Azure PC's settings (in a copy: no question for an administrator, the audit of process creation on) | the list held `whoami.exe` and its `conhost.exe` (2 of 18 starts). On Windows 11 the event had `SubjectUserName` builder, `TargetUserName` "-" and `%%1937`: the user of this rise was in `SubjectUserName`, and the list takes either. Not run on Windows Server 2025 |
| `bare-server.sh make` with a stand-in `hcloud` | no server made: "nothing costs"; made, answer not read: the delete line; no server made, then no answer from Hetzner: "Hetzner did not say ... If it does, it costs until: bare-server.sh delete" (only Hetzner's own "not found" says "nothing costs") |
| `team_compare.py` on two reads of round 1 (no servers part) | refused: "a read with no servers part ... read again" (before, two such reads gave 0 and exit 0) |

**Round 4, after the read of `b2c58833e` by two Opus readers** (no server, no Azure VM, no token):

| Check | Result |
| --- | --- |
| `bare-server.sh` with a stand-in `hcloud` | make: no server, "nothing costs"; made but not read, the delete line; no answer, "If it does, it costs until"; a proxy's "404 Not Found", "Hetzner did not say ... nothing was made". delete: Hetzner's "not found", "nothing to delete"; no answer or a proxy's 404, "it can still cost. Run ... again"; a server there, deleted |
| `vm.sh` with the mark in the folder | `picture`, `screen`, and `desktop` with `frames.ps1`, `notify.ps1` or `toastpress.ps1` refuse, and the refusal names the window that took the keys as a way out |
| the field's length after the keys, the Azure typer (`type-pipe.ps1`), the PowerShell files (in the copy of the round-3 stage) | the QEMU path with the focus taken away: above. The typer's path (the copy with the mark "remote" for the time of the step): "typed 4 of 4, Enter", the page went on and the mark went. Each PowerShell file parses, and the C# of `type-pipe.ps1`, `watch.ps1` and `azure-pc-setup.ps1` compiles. The -500 account, `FilterAdministratorToken` and the gate of `elevated` run only on the Azure PC |

**Round 5, after the read of `b70ab8b80` by Fable and two Opus readers** (no server, no Azure VM, no token):

| Check | Result |
| --- | --- |
| `secret.sh`, `vm.sh` | `bash -n` |
| `secret.sh` with a stand-in `vm.sh` (no VM): the focus on Notepad with the field whole; back on the field with 30 of 52; the field gone; a field with no value; a password box; after the keys no length and no password box; a password box with the focus on Notepad after the keys; the typer's stop at 30 of 52; the typer's Enter | not run yet: in the tests lock with the stage |
| the log line when the focus leaves the field during the keys, and the parse of `focus.ps1` and `type-pipe.ps1` (a copy, as in round 3's (A)) | not run yet: the stage waits in the tests lock |
| the trigger of the Azure PC's step (Founderizer's window minimized during the keys; its handle is not 0) and its way out, in the same copy through the typer | not run yet: the stage waits in the tests lock |

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
