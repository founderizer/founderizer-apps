# The Windows build machines at Azure

Three x64 Windows machines at Azure, one for each builder lane of the Windows app, so that no lane waits for another
lane's hold and no build runs on the Mac's shared test line. `cloud.sh` makes and drives them with the verbs of
`../vm.sh`, over SSH. The Mac's ARM64 VM (`../README.md`) stays for the ARM64 runs and for the pictures of the Windows
11 look (these machines run Windows Server, whose look, fonts and title bar are not Windows 11's).

## The machines

| Lane | Work | Machine | Resource group | Region | Size |
| --- | --- | --- | --- | --- | --- |
| 1 | setup pages | `fz-build-1` | `fz-build-1-rg` | `northeurope` | `Standard_D8s_v6`: 8 vCPUs, 32 GB, x64 |
| 2 | cards | `fz-build-2` | `fz-build-2-rg` | `francecentral` | `Standard_D8s_v6` |
| 3 | T1a | `fz-build-3` | `fz-build-3-rg` | `swedencentral` | `Standard_D8s_v6` |

One machine in each region, because the subscription's quota is 10 vCPUs in each region. Lane 2 was planned in
`westeurope`, which refused every resource of the deployment on 23 November 2026 ("The selected region is currently not
accepting new customers"); `spaincentral` then refused Azure's auto-shutdown (no `Microsoft.DevTestLab/schedules`
there), after its what-if had passed. Nothing was made in either. Each machine has: Windows Server 2025 Datacenter with
Desktop Experience (licence included, Gen2, Trusted launch with Secure Boot and a vTPM), a Premium SSD of 128 GB (P10),
a NIC, a static public IPv4 address (Standard), a network `10.71.<lane>.0/24` with a network security group, Azure's
auto-shutdown at 01:00 Madrid time (`Romance Standard Time`; it deallocates the machine), and one role assignment for
its idle rule (below). Every resource has the tags `temporary=false`, `build=windows` and `lane=<lane>`. `machine.json`
is the whole list.

## Cost

Azure's retail list prices in EUR, pay-as-you-go, read on 23 November 2026 (`prices.azure.com`): Windows licence
included. While a machine is deallocated, only its disk and its address cost.

| Lane | Region | While it runs, per hour | Disk, per month (always) | Address, per month (always) | A month at the expected hours (240 h: 8 hours a day) |
| --- | --- | --- | --- | --- | --- |
| 1 | northeurope | 0.7334 | 17.69 | 3.29 | 196.99 |
| 2 | francecentral | 0.7523 | 21.41 | 3.29 | 205.25 |
| 3 | swedencentral | 0.7146 | 19.46 | 3.29 | 194.25 |
| all | | 2.2003 | 58.56 | 9.86 | 596.49 |

The address is 0.0045 an hour (3.29 a month of 730 hours). The role assignment and the auto-shutdown cost nothing. A
machine that runs every hour of a month costs about 545 to 575; the night's shutdown and the idle rule keep it far from
that.

## Use it

```
export FZ_AZURE_TENANT=<the tenantId that `az account list --all` gives for the subscription that pays>
app/windows/vm/cloud/cloud.sh 1 start              # start lane 1's machine; wait for SSH and builder's desktop
app/windows/vm/cloud/cloud.sh 1 build              # from your worktree: send its app/ sources, then the x64 build, signed with the machine's test key
app/windows/vm/cloud/cloud.sh 1 test               # send the sources again, then Founderizer.Windows.Tests
app/windows/vm/cloud/cloud.sh 1 build --proofs     # the proofs' build into C:\fz\out\x64-proofs
app/windows/vm/cloud/cloud.sh 1 desktop 'Start-Process explorer.exe -ArgumentList C:\fz\out\x64-proofs\Founderizer.App.exe'
app/windows/vm/cloud/cloud.sh 1 picture /tmp/window.png
app/windows/vm/cloud/cloud.sh 1 keys tab tab ret ctrl-a
app/windows/vm/cloud/cloud.sh 1 run 'dotnet --list-sdks'
FZ_VM_USER=<session> app/windows/vm/cloud/cloud.sh 1 hold      # the machine is this session's until release
FZ_VM_USER=<session> app/windows/vm/cloud/cloud.sh 1 release
app/windows/vm/cloud/cloud.sh 1 stop               # deallocate it when the work no longer needs it
app/windows/vm/cloud/cloud.sh list                 # each lane's machine and its power state
```

- `FZ_AZURE_TENANT` is set in the session's shell, never in a file of the repository. `make`, `start`, `stop`,
  `status` and `list` need it (they call Azure); the SSH verbs do not.
- `sync` (and `build` and `test`, which sync first unless `--no-sync`) sends the files of the worktree of the current
  folder (or of the worktree that `sync <worktree>` names) as they are now, committed or not: the tracked and the new
  files that git does not ignore (each new one is named before it goes), under `app/windows`, `app/vectors`,
  `app/Localization`, `app/Sources` and `app/ios/Sources`. They go to `C:\fz\src` as `app/` has them
  (`C:\fz\src\windows\Founderizer.Windows`, the paths of the Mac's VM); a removed file goes, and `bin` and `obj` stay,
  so the next build is incremental. `C:\fz\src\SOURCE.txt` names the worktree, the commit and the count of changed
  files, and `build` and `test` print it first; `build` also prints `dotnet --version`, and `test` ends a test that hangs
  for 30 minutes (`--blame-hang-timeout`). The pictures' scripts (`../pictures/*.ps1`) also go to `C:\fz\setup`.
- **Start the app through explorer**, as above: a command of `desktop` is a scheduled task with builder's full token
  (measured: High), so an app that it starts directly runs elevated, which no person's start does. Started through
  explorer, the app has builder's limited token (measured: "limited", Medium), as on a person's PC.
- `run`, `copy`, `desktop`, `picture`, `hold` and `release` are `vm.sh`'s own, with `FZ_VM_DIR`, `FZ_VM_HOST` and
  `FZ_VM_PORT` set for the machine. `screen` is `picture`: a machine at Azure has no QEMU display, and boot diagnostics
  (Azure's pictures of the screen) stay off. `keys` sends Windows' own key events in builder's desktop session
  (`keys.ps1`, as proof A's Azure typer does): QEMU's key names as `vm.sh keys` takes them, or a chord (`ctrl-a`,
  `alt-f4`, `shift-tab`). No value of a secret goes through `keys`: proof A's hidden prompt has its own path.
- A verb of SSH that finds the machine deallocated (its idle rule, the night, or `stop`) says so: run `start`.
- Each make, start, stop and change of address is a line of `$FZ_CLOUD_HOME/lane-<lane>/record.log` on the Mac.

## What a machine is

| Part | Value |
| --- | --- |
| User | `builder`: the built-in Administrator that Azure renames (its SID ends in -500), with Admin Approval Mode (`FilterAdministratorToken` 1), so builder's own desktop (explorer) and what it starts have a user's limited token; an administrator's rise has no question (`ConsentPromptBehaviorAdmin` 0, as on proof A's PC: nobody can press it). SSH has the full token, and so has a scheduled task of the desktop session (`desktop`): measured on `fz-build-2` after a restart, with no `LocalAccountTokenFilterPolicy` |
| Sign-in | Automatic, after each start, with a password that the setup made in the machine (an LSA secret); it never leaves the machine, and nothing needs it |
| SSH | Windows' own OpenSSH server, the key of this Mac only (`$HOME/.ssh/founderizer-windows-vm`, the key of the Mac's VM), from this Mac's public address only: the network security group's one inbound rule and Windows' firewall rule. No Remote Desktop: no rule for it, and Windows takes no such connection (`fDenyTSConnections` 1). When the Mac's address changes, `start` puts the new one in both rules, through Azure |
| Host key | New, made by the setup (the image's keys are the same on every machine of the image); the setup reads it and Azure's run command brings it back; `known_hosts` on the Mac holds it before the first SSH connection, and a key that is not there is refused (never taken on its first use) |
| .NET | SDK 10.0.404 for x64, the SDK of the release builds (T1a's `release/global.json`), checked against Microsoft's SHA-512 (`install-sdk.ps1`). `cloud.sh` stops when `release/global.json` names another SDK |
| Screen | 1920 x 1080 at 100 % (`display.ps1`; Azure's console starts at 1024 x 768). No graphics card: WARP draws, as in the Mac's VM |
| Updates | Windows applies none by itself (`patchMode` Manual, no automatic updates), so no restart comes in a run; `hold` also pauses Windows Update, as in the Mac's VM. They are applied by hand: below |
| Defender | No scan on each read in `C:\fz`, builder's NuGet folders and `C:\Program Files\dotnet`, for the builds' speed |
| Secrets | None. No GitHub key: the sources come from the builder's worktree on the Mac. No key or token is stored |
| Idle rule | `idle.ps1`, a task of SYSTEM every 10 minutes and at each start: the machine is in use while an SSH connection is open or `dotnet`, `MSBuild`, `testhost` or `VBCSCompiler` runs. After 2 hours with neither (counted from the last use or the last start), the machine deallocates itself through Azure's API with its own managed identity: the token comes from Azure's metadata service for that one call and is written nowhere, and the identity's one role is DevTest Labs User at the scope of this VM (read, start, restart and deallocate this VM; nothing else exists at that scope). A hold does not keep a machine up. Each deallocation is a line of `C:\ProgramData\fz-cloud\idle.log` |
| Night | Azure's auto-shutdown deallocates each machine at 01:00 Madrid time, also during a run: `start` brings it back |

## Make a machine

`cloud.sh <lane> make --what-if` reads and checks: the subscription by its name in `FZ_AZURE_TENANT`'s tenant (never
the CLI's default), the providers, the size in the region (x64, Gen2, Trusted launch, Premium SSD) and the quota of
its family, and Azure's what-if of the deployment; nothing is made. The what-if does not see every refusal (it passed
`spaincentral`, whose deployment then refused the auto-shutdown before it made anything). `cloud.sh <lane> make` does
the same checks, then the deployment (the admin password that Azure needs at the start is random and goes on the
deployment's standard input only), the setup (`setup.ps1`, by Azure's run command as SYSTEM), the wait for SSH after
its restart, the SDK and the screen. `--size <size>` takes another x64 size where `Standard_D8s_v6` is refused (for
example `Standard_D8as_v6`; the subscription has no quota for the Dsv5 family). Do not change `cloud.sh` while it
runs: bash reads a script while it runs it.

A machine is removed with `az group delete -n fz-build-<lane>-rg --subscription <the subscription's id> --yes` (its group
holds all of it), then its deployments at the subscription, which keep the Mac's address in their parameters:

```
for d in $(az deployment sub list --subscription <id> --query "[?starts_with(name, 'fz-build-<lane>-')].name" -o tsv); do
    az deployment sub delete -n "$d" --subscription <id>
done
```

and then its folder `$FZ_CLOUD_HOME/lane-<lane>` on the Mac.

## Windows' updates

Windows applies no update by itself, so that no restart comes in the middle of a build or a proof. The area session
applies them once a month, after Microsoft's monthly updates (the second Tuesday), on each machine that no session
holds: `cloud.sh <lane> start`, then Azure's one-time install of the critical and security updates, with a restart when
an update needs one, then `cloud.sh <lane> stop`:

```
az vm install-patches -g fz-build-<lane>-rg -n fz-build-<lane> --subscription <id> --maximum-duration PT2H \
    --reboot-setting IfRequired --classifications-to-include-win Critical Security
```

A machine that was deallocated for the whole month gets them at its next start, before its first build.

## Measured, 23 November 2026

| Step | Time |
| --- | --- |
| `make`: the deployment, the setup and its restart, the SDK, the screen | about 6 minutes (the deployment about 3.5, the setup about 1, the SDK about 1) |
| `build` (sync of about 4 MB, then the x64 publish and its signature; the first build of the machine, with NuGet's restore) | 56 to 61 s |
| `test --no-sync`: Founderizer.Windows.Tests | 27 to 28 s; 47 passed, 3 skipped (Tailscale's own tests: no Tailscale on the machine), 0 failed |
| `stop` / `start` (with the wait for SSH and builder's desktop) | 62 s / 74 s |
| the idle rule's deallocation (its call, as SYSTEM, with the machine's identity) | 25 s from its start to "VM deallocated"; Azure's activity log names the machine's identity as the caller |
| the tokens on `fz-build-2`, after a restart with no `LocalAccountTokenFilterPolicy` | SSH: full (High, `Get-Process -IncludeUserName` works); a task of `desktop`: full (High); builder's explorer: limited (Medium); the app started by a task of `desktop`: full; the app started through explorer: limited |

Two faults that the first make found, fixed in `setup.ps1`:

- **The image's SSH host keys are the same on every machine.** Windows Server 2025's image at Azure holds host keys made
  when Microsoft built it (12 November 2026): `fz-build-1` and `fz-build-3` gave the same fingerprint. So the setup makes
  new ones before it sends the key back through Azure's run command. The same fault was in proof A's
  `../proof-a/azure-pc-setup.ps1`, which has the same fix now.
- **Windows' page "Send diagnostic data to Microsoft"** covered the whole desktop at the first sign-in, over the app's
  window. Windows' own policy turns it off (`DisablePrivacyExperience` 1), with the diagnostic data "Required only"
  (`AllowTelemetry` 1), the smaller of the page's two choices. Nobody answered the page. Proof A's
  `../proof-a/azure-pc-setup.ps1` has the same policy now.

**The time with the image's host key, as it was.** Lanes 1 and 3 were made before that fix: lane 1 ran with the image's
host key from 20:40:43 to 20:52:36 UTC, lane 3 from 20:48:23 to 20:53:48 UTC (each got new keys through Azure's run
command then; lane 2 was made with the fix). In that time a host that holds the image's key could have stood in for the
machine on the network path from the Mac. What went over SSH then: on both, the make's own steps (the ready check,
`install-sdk.ps1` and its run, `display.ps1`); on lane 1 also the sources, twice (the folders of `sync` at origin/main
c04aee9ec with this piece's own files; among them `app/vectors/makers/agent_sharing.py`, which the public copy leaves out
because it imports an unpublished Teams file, and which holds only test keys from fixed labels), the output of one
build and one test run, two pictures of the privacy page, `keys.ps1` with Alt+F4, and the privacy policy's command. No
key, password or token went: SSH's sign-in proves the Mac's key with a signature that is good for that session only,
and the key stays on the Mac; the build's test signing key was made in the machine, not exportable, and stayed there.
A stand-in could have read those sources and given false outputs: lane 1's build and test results of that time came
again on lanes 2 and 3, each with its own new key.

**The machines against `setup.ps1`.** Lane 2 was made with it, then changed by hand on 23 November at 21:22 UTC to its
present form (no `LocalAccountTokenFilterPolicy`, `fDenyTSConnections` 1). Lanes 1 and 3 still have
`LocalAccountTokenFilterPolicy` 1 and Windows' Remote Desktop not refused (the network security group refuses it); at
their first start, before a build:

```
cloud.sh <lane> run "Remove-ItemProperty -Path HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System -Name LocalAccountTokenFilterPolicy; Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections -Type DWord -Value 1"
```

## Files

| File | What |
| --- | --- |
| `cloud.sh` | the tool: make, start, stop, status, list, sync, build, test, and vm.sh's run, copy, desktop, picture, screen, keys, hold, release |
| `machine.json` | the deployment of one machine (subscription scope: its resource group and all in it) |
| `setup.ps1` | the machine's setup, once, by Azure's run command: SSH, sign-in, UAC, power, Defender, the idle rule |
| `idle.ps1` | the idle rule |
| `install-sdk.ps1` | the exact .NET SDK for x64 |
| `display.ps1` | the screen of builder's desktop session |
| `keys.ps1` | keys in builder's desktop session |
