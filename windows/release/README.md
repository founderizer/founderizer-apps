# The release of Founderizer for Windows: the build, the install and the update

Slice 1.6 of `~/dev/founderizer-plans/windows-app-plan.md`, the lane "Windows screens" of
`~/dev/founderizer-plans/windows-app-release-design.md` (its sections 4, 5 and 8). The library's part, the manifest
and the download, is `Founderizer.Core/ReleaseManifests.cs` and `Founderizer.Core/WindowsUpdate.cs`.

Nothing here draws an element on the owner's screen: the setup and the launcher have no window, the update runs under
the hood, and what they did is in `update.log`.

## The build: `build-release.ps1`

The Windows computer runs it on `main`'s tip, for ARM64 and x64:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File build-release.ps1 -Source C:\fz\src\windows -Version 0.2.3 -Build 23
```

For each kind of PC it publishes the app (`Founderizer.App.exe`, self-contained with JIT, not packaged) and the
launcher (`Founderizer.exe`, one trimmed file of about 14 MB), writes `build.json` with the version, the build number
and the kind of PC, signs every `.exe` and `.dll`, and writes:

| File | What it is |
| --- | --- |
| `Founderizer-<version>-<arch>.zip` | the build, for the channel: the app's files, the launcher and `build.json` |
| `Founderizer-Setup-<version>-<arch>.exe` | the setup: the launcher with that zip inside (`-p:BuildZip=`) |
| `builds.json` | each file's name, size and SHA-256, for the Mac's release job |

It signs with the build VM's test certificate (`vm/setup/build-window.ps1` makes it) or with `-Thumbprint`. Azure
Artifact Signing (plan decision D2) takes that step's place, with a timestamp, once the owner's identity check is done.
`-Proofs` makes the proofs' build; `-Reuse` packs the last publish again with a new version and build number.

## The install: `Founderizer.Install`, `Founderizer.Launcher`

```
%LOCALAPPDATA%\Programs\Founderizer\
  Founderizer.exe            the launcher: the Start menu entry starts it
  builds\<build>\            each build, whole, never changed after its check
  current, previous          one build number each, written to a new file and moved over the old one
  next                       a checked build that waits for its first start
  failed                     the builds that ended before their first good start: none is taken again
  updates\<build>-<id>\      one download, removed at its end
  update.log                 one line for each step of the setup, the launcher and the update
```

- **The setup** checks its build as an update is checked, puts it in `builds\<build>`, writes `current`, the
  launcher, the Start menu entry (with the app's identity `Founderizer.Founderizer`, which the running app takes too,
  so that a pin of its window pins the launcher) and the entry of Windows' list of installed apps (under
  `HKCU\Software\Microsoft\Windows\CurrentVersion\Uninstall\Founderizer`), and starts the app. Its manifest asks for
  the user's own rights (`asInvoker`): no step needs an administrator.
- **The launcher** starts the build of `current`, or a waiting `next` build. It waits for the new build's first good
  start (its window drew, and the store read its folder: the event `Local\Founderizer.GoodStart.<build>`) or for its
  end, and when it ended first, keeps it in `failed` and starts the build of `current` again. Each wait ends on an
  event, never on a clock. At a start with no build running, it removes the download folders and every build folder
  that `current` and `next` do not name.
- **The removal** (`Founderizer.exe --uninstall`, the entry's `UninstallString`) ends the app, removes both entries,
  the builds, the downloads and the files of the folder, and, once it has ended, its own file and the folder (Windows
  PowerShell waits for its end). It keeps `%LOCALAPPDATA%\Founderizer`, the store and the device key: a setup run
  later reads with the same key and no new code, as the iPhone keeps its key in its keychain when the app is deleted,
  and Remove on the owner's Mac is what ends the PC's access.

## The update: `Founderizer.Windows/Update`

The app of an installed build reads the channel at its first good start and every hour after, sooner after a read
that failed (60, 300 and 900 seconds), with the library's `WindowsUpdate.ReadAsync`. A newer build that is offered and
not in `failed` goes through four checks, each of which removes its download folder and changes nothing else when it
refuses:

1. The library: the manifest's fields, its Ed25519 signature by a key of this build, the kind of PC, a newer build
   number, the Windows version; then the download's size and SHA-256.
2. The unpack (`BuildUnpack`): each entry's name is checked before the first byte is written (no `..`, no root, no
   `:`, no device name, no part that ends with a dot or a space), the build holds one `Founderizer.App.exe`, at its
   top, and its `build.json` names the manifest's version, build and kind of PC.
3. The publisher check (`Publisher`): each `.exe` and `.dll` has a signature that Windows finds valid
   (`WinVerifyTrust`), by the same certificate as the running build. A build with no valid signature takes no update.
   The rule of Artifact Signing (the same subject and identity EKU, with revocation and a timestamp) comes with it.
4. The folder moves to `builds\<build>`, and `next` names it.

The app then ends once the owner has been away from its window for 120 seconds and no write is on its way (the Mac's
`AppUpdatePolicy`), and starts the launcher with `--after <pid>`. The new build starts without coming to the front
(`--after-update`, minimized again when the old window was).

**The keys.** A release build trusts only the lines of `release-key.pub` (`Update/ReleaseChannel.cs`, as the Mac's
`AppUpdate.swift` holds them) and reads the approved track, since the hub gives the PC no setting for early releases
yet; the lines of `early-key.pub` are there for that day. A build with the proofs' switch takes a test channel, its
certificate's SHA-256, a test key and a shorter clock from the proofs' variables (`FOUNDERIZER_UPDATE_*`); a release
build holds none of them, not even their names (`vm/README.md`, "The release in the VM").
