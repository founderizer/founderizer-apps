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

## The two kinds: signed and tester

A tester build is a build made with `-Tester` (`-p:FounderizerTester=true`, rule 20 of
`~/dev/founderizer-plans/windows-app-plan-v2.md`, section 4, and its piece T1); every other build is a signed build
and says `-p:FounderizerTester=false`, in all three publishes. A tester build signs no file, its `build.json` says
`"tester": true`, its stages are `stage-tester-<arch>` and its files go to `<Out>\<version>-<build>-tester\`. Each
of its projects compiles with `TESTER`, which only that switch gives (`../Directory.Build.props`: a variable
`FounderizerTester` makes no tester build, and `TESTER` from anywhere else stops the build). Only a tester build has
`Founderizer.Core.TesterManifest`: the first line of a tester manifest, `founderizer-windows-tester-1`, and the line of
`tester-key.pub` as the constant `KeyLine` (`Founderizer.Core.csproj` makes it from the file when the build is made).

The build checks the kind by the built bytes (T1's test 2). `read-constants.cs` (a .NET file-based program, which the
release SDK runs) reads `BuildKind.Tester`, `FirstRunSwitch.Welcome` and `Proofs.On` from `Founderizer.App.dll`, and
the build stops when one is not what its command line asked; `builds.json` says the three as the built file says them.
No file of a signed build, and not its setup, holds the tester's first line or key, in UTF-8 or UTF-16, and its launcher
holds no BouncyCastle. A tester build's `Founderizer.Core.dll` holds both, with the key of `tester-key.pub`, and none of
our own files or its setup has a signature. No build starts while a variable whose name starts with `Founderizer` (with
no regard to case, so the proofs' `FOUNDERIZER_UPDATE_*` too) or one named `DefineConstants` is set for the machine, the
user or the build's process. What a tester setup and its update check (`Setup.Run` and `Updater` under `TESTER`) is the
next part of T1, after U6a: until then a tester setup installs nothing, because its own file has no signature.

## The SDK and the lock files

- **One exact SDK on each release machine:** the one of `global.json` in this folder (10.0.404, with no roll forward;
  its .NET runtime, 10.0.15, is the one that each self-contained build carries). `build-release.ps1` runs every
  `dotnet` command in this folder, so the muxer takes that SDK or none. It stops when the SDK is not installed, when
  its runtime is before 10.0.14 (GHSA-p3jp-9v83-76w9), or when its runtime is not `FounderizerReleaseRuntime` of
  `../Directory.Build.props`. A new release SDK changes both lines and the lock files in one commit, and
  `vm/setup/install-dotnet.ps1 -Version <SDK>` installs it.
- **This Mac's tests are not a release.** They run with the Mac's own .NET 10 SDK, under `../global.json` (any 10.0
  SDK) or none, and restore without locked mode.
- **One locked restore before the publishes** (`dotnet restore --locked-mode --force` of the app and the launcher,
  with all of their projects): a lock file that does not match its project, or a package whose hash is not the one of
  its lock file, stops the build. The publishes then restore nothing (`--no-restore`): a publish's own restore gives
  its one runtime (`-r`) to every project of the graph, and the libraries' lock files name none, so each project
  declares its runtimes itself (the app, the launcher and `Founderizer.Install`: `win-arm64;win-x64`). `--force`, so
  that NuGet reads each lock file again also in a folder that an earlier build restored (no "no-op" restore).
- **The lock files are the same on each SDK.** The SDK adds its own package, Microsoft.NET.ILLink.Tasks, to each
  project that it trims or checks for trimming, at the version of its own runtime, and a lock file names it.
  `../Directory.Build.props` gives every SDK the release SDK's version of it (`FounderizerReleaseRuntime`). So a
  restore on this Mac, which has another SDK, changes no lock file, and a lock file that it writes for a new package
  is the release machine's too.

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
