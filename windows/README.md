# Founderizer for Windows

A Windows-native owner app: C# on .NET 10, with WinUI 3 for its screens. It shares no code with the Mac and iPhone
apps. What keeps the apps in step is the hub's owner API, its feature names, a C# twin of the decode check, and test
vectors that Python makes and that Swift and C# read. The plan is `windows-app-plan.md` in the owner's plans folder.

The logic library and its tests build and run on macOS, Linux and Windows (slice 1.1, and the logic of the step-1
screens). The screens (`Founderizer.Windows`, slice 1.2) build on Windows only. Each element of a screen is one of the
seven pictures that the owner approved (`windows-app-pictures.md` in the plans folder).

## The parts

| Folder | What | Builds on |
| --- | --- | --- |
| `Founderizer.Core/` | the logic: the hub client, the models and decoders of the device routes, the live changes, the outbox, the canonical statement and the crypto. `net10.0`, no Windows call, trimming and Native AOT compatible, JSON only by source generation | any OS |
| `Founderizer.Core.Tests/` | MSTest: unit tests, the vectors of `../vectors`, and the decode twin (`HubDecodeTwin`) | any OS |
| `Founderizer.SelfCheck/` | a small program that runs the vectors, published with Native AOT: the proof that the library and BouncyCastle work with no JIT | any OS |
| `PARITY.md`, `parity.py` | each feature name of the hub and its state on Windows, and the script that prints each name with no line | |
| `../vectors/` | the shared test vectors and `make_vectors.py`, which makes them with the hub's own code | |

The routes are the device routes of `hub.py` `DEVICE_PATHS`: a PC of an owner who has a Mac is an owner device, as
the iPhone is. It enrolls with a code from the Mac, and then sends its own key on every call from its own address.

## What the screens call

The junction with `Founderizer.Windows`. Each rule, word and order of an element of the seven pictures is in the
library; a screen draws what a model gives it. **These names and shapes stay**: a later field may be added, and none is
renamed or removed without a word to the screens lane.

- **One store for the window**: `OwnerStore`, made with `StoreSettings`: `Folder` (the app's own folder, for the hub
  address, the last reading, the newest items of each chat, the seen marks, the drafts, the picked files and the
  outbox), `Keys` (an `IDeviceKeyStore`: `new FileKeyStore(path, protection)`, with the screens' `IKeyProtection`,
  Windows' protection of the user's data, later the TPM; keep its file outside `Folder`), `ClientLabel`
  (`founderizer-windows/1/<installation id>`, the client of each write), and `Tailscale` (an `ITailscaleStatus` of the
  screens: the text of `tailscale status --json`, or null when Tailscale is not on the PC or does not run).
- **Its life**: `SetFront(true)` when the window comes to the front and `SetFront(false)` when it leaves (it reads only
  in front: at once, every 10 s with a chat, a task or a write open, else every 30 s, and on each wake of
  `GET /ui/wait`); `OpenChat(agent)` and `OpenTask(id)` while a page shows (null when it goes); `RefreshAsync()` for Try
  again.
- **Its changes**: `Changed` gives a `StoreChange`, in order, never twice for one state, on the thread that changed the
  store (a pool thread for a read, the caller's for a write or a draft): move it to the UI thread. The store raises one
  only when a model of a screen changed, and `change.Parts` (`StoreParts`: `Pane`, `Line`, `Chat` for the open chat,
  `Needs`, `Board`, `Task` for the open task, `Settings`) says which; a read that brought nothing new raises none.
  `change.After` is the new immutable `StoreState`; `change.Agents` names the pane rows that came, went or changed, and
  `Fleet`, `Chats`, `Needs`, `Tasks`, `TaskPages`, `Connection` and `Pending` what changed in the data. An age that moves
  with the clock alone ("just now", "5 min ago") raises no change: a screen that shows one draws it again on its own
  timer, once a minute. The one rule of time that the store raises itself is the reading that turns old (45 seconds
  after the last read with no read since): at that moment a write cannot go, and the change says so.
- **The models**, pure functions of one state, the clock (`DateTimeOffset.UtcNow`) and `ScreenContext.Local` (Windows'
  time zone and culture): `Screens.FirstPage`, `Screens.Line` (the connection line), `Screens.Pane`, `Screens.Chat`,
  `Screens.Needs`, `Screens.Board`, `Screens.Task`, `Screens.Settings` (with Founderizer's credit, `Credit.Founderizer`,
  the phone's one line: `Words`, then `Handle` as the one link to `Profile`), and the form `EnrollForm` of Add this PC. Each
  list is a `ValueList<T>`, equal by value; `RowDiff.Of(before, after, row => row.Key)` gives the rows that came, went,
  changed or moved.
- **An agent's mark**: `MarkLook` (its two colours for a gradient from the top left to the bottom right, the inner mark's
  fill and opacity, dashed in setup, and whether it moves now), the outline and the inner mark as SVG path data in a
  square of 100 (`GlyphPaths.Outline(kind)`, `GlyphPaths.Core(kind)`), and its motion (`GlyphLook.Moves()`).
- **The writes**: `SetDraft` and `SendMessageAsync(agent)`; `SetAnswerDraft` and `AnswerAsync(need)`; `Press(need,
  option)` (never refused: it waits while the store cannot write); `TickAsync(need, options)`; `DiscussAsync(need,
  text)`; `ControlAsync(task, action)`; `GuideAsync(task, text)`; `RetryAsync()`; `DiscardRefused()`;
  `AddFileAsync(composer, name, bytes)`, `UploadAsync(composer, requestId)` (a file that did not go goes again) and
  `RemoveFile(composer, requestId)` (composers `agent:<name>` and `need:<id>`); `FileAsync(file)`; `EnrollAsync(code)`;
  `ConnectAsync(address)`; `ForgetKey()`; `ReadDeviceAsync()`; `Unlock()`; `FindHubAsync()`. A write that returns
  words returns the owner's words of what failed. **A press is never lost with no word**: `SendMessageAsync`, `AnswerAsync`,
  `TickAsync`, `DiscussAsync`, `ControlAsync` and `GuideAsync` give `Task<string?>`, null when the write went, else the
  owner's words. A press that comes while another write is on its way, or while the reading waits for a read that
  comes in front, waits and goes then, in the order of the presses (the window draws a change after the store made it,
  so a button can still show on). A lasting reason gives its words at once, and nothing goes: a request that waits
  ("A saved request waits. Check it in Settings."), the hub that does not answer (the connection line's words), the
  storage line, or "Not sent. The hub connection changed." for a press whose hub changed while it waited
  (`StoreState.HoldsWrites(now)` says which). A screen shows those words where the press was only where an approved
  element has a place for them (a composer's note); a Pause or a Stop has none, and its line over the page already
  says the same cause.
- **The picked files** (the iPhone's StagedFile): `state.Staged[composer]` holds each `StagedFile` (`RequestId`, `Name`,
  `Mime`, `Size`, `File` once the hub holds it, `Failure`, `IsOnHub`), in the order he picked them, between starts;
  `state.Uploading` the ones that go up now. While a file of a composer waits, its Send is off (`ComposerModel.CanSend`,
  `AnswerBoxModel.CanSend(..., filesWait)`) and the box's `Note` says "Sending a file…" or "A file did not go up. Send it
  again, or take it out."; a file that he picked and that was not taken is `state.FileError`.
- **Add this PC and Settings (slice 1.5)**: a PC with no hub address opens on Add this PC (`Screens.FirstPage`) and
  looks for its hub on its Tailscale by itself while it is in front, every five seconds (`FindHubAsync`, the Mac's
  `findHub`); `state.Search` (`HubSearch`: `Looking`, `NoNetwork`, `NoHub`, `Found`) says how it stands, with no words of
  its own: a PC with no hub shows its page with no hub, as the iPhone does, and a hub that does not answer has the
  iPhone's line ("Your hub did not answer. Check that its server is on."). `EnrollAsync(code)` sends the PC's kind, so
  the hub names it "PC". Settings' address field starts with `state.Hub` (found or typed), and Connect is
  `ConnectAsync(text)`, whose refusal `state.AddressError` keeps. The key stays between starts in its file, so a start
  needs no new code; Forget the key takes the file away.
- **The app's own update (slice 1.6, the library's part)**: `WindowsManifest.Check(data, keys, channel, arch)` (the
  release keys that the app ships, and the early keys too while its fleet takes releases early),
  `WindowsUpdate.ReadAsync(http, channel, arch, early, keys, installed, system, fleet)` and `WindowsUpdate.Reading`
  (offered only when the build is higher, not held, and this Windows meets its minimum; the Mac's words with "PC"),
  and `BuildDownload.FetchAsync(http, manifest, root)`, which gives the path of a file whose size and SHA-256 are the
  manifest's, in a new folder of its own under `root`, or `UpdateFailure` with the owner's words and no folder left.
  `BuildDownload.NewClient()` is the client of both. The screens give the rest (`~/dev/founderizer-plans/
  windows-app-release-design.md`, sections 4 and 5): the publisher check, the unpack, the launcher and the swap. No
  element shows an update before the owner's yes to it.
- An element that needs a hub feature asks the model, which reads `ui_features` (`state.Offers(...)`): Discuss
  (`need_talk`), the task's controls (`task_controls`) and its guidance (`task_steering`), the plus of the files
  (`attachments`), the chat of an agent other than the manager (`direct_chat`).
- `Directory.Build.props` no longer sets `InvariantGlobalization` (the self-check sets it for itself), so the screens
  write dates and times in the user's culture.

```csharp
var store = new OwnerStore(new StoreSettings { Folder = folder, Keys = keys, ClientLabel = label });
var page = Screens.FirstPage(store.State);
var pane = Screens.Pane(store.State, page, DateTimeOffset.UtcNow, ScreenContext.Local);
store.Changed += (_, change) => dispatcher.TryEnqueue(() =>
{
    var next = Screens.Pane(change.After, page, DateTimeOffset.UtcNow, ScreenContext.Local);
    foreach (var name in RowDiff.Of(pane.Agents, next.Agents, row => row.Key).Changed) rows[name].Show(next.Agents.First(r => r.Name == name));
    pane = next;
});
store.SetFront(true);
```

## Build and test

You need the .NET 10 SDK (`dotnet --version` says 10.0.x; `global.json` takes any 10.0 SDK).

```bash
dotnet test app/windows/Founderizer.Core.Tests/Founderizer.Core.Tests.csproj
```

The tests of the decode twin are inconclusive (skipped) there: they run against a scratch hub, which
`app_decode.py` serves.

```bash
python3 app_decode.py --windows
```

That decodes the scratch hub with the Swift apps first, as before, and then with this library, at `--ref` (default
`origin/main`). The Windows lane runs the twin alone, against a commit of its own:

```bash
python3 app_decode.py --windows-only --ref HEAD
```

The self-check, published with Native AOT (on this Mac `osx-arm64`; on a PC `win-x64` or `win-arm64`):

```bash
dotnet publish app/windows/Founderizer.SelfCheck/Founderizer.SelfCheck.csproj -c Release -r osx-arm64
```

On a Mac whose .NET comes from Homebrew, the native link takes Homebrew's OpenSSL and Brotli, which are not on the
linker's own path (`ld: library 'ssl' not found`):

```bash
LIBRARY_PATH=/opt/homebrew/opt/openssl@3/lib:/opt/homebrew/lib dotnet publish app/windows/Founderizer.SelfCheck/Founderizer.SelfCheck.csproj -c Release -r osx-arm64
```

```bash
app/windows/Founderizer.SelfCheck/bin/Release/net10.0/osx-arm64/publish/Founderizer.SelfCheck
```

The vectors again, and the check that the committed files are what the hub's code makes now:

```bash
python3 app/vectors/make_vectors.py --check
```

The parity report:

```bash
python3 app/windows/parity.py
```

Keep a test run small, as `AGENTS.md` asks: the tests of what you changed, once, when the piece is ready, and one test
process at a time.

## Packages

- **One package that is not in the box of .NET**: BouncyCastle.Cryptography, for X25519, Ed25519 and
  ChaCha20-Poly1305 (.NET 10 has no X25519 and no Ed25519). It is pinned to one version (`[2.7.0]`, released on
  30 July 2026), and `packages.lock.json` holds its checksum. A new version is at least 7 days old.
- The tests take MSTest 4.5.1 and Microsoft.NET.Test.Sdk 18.11.0, with their own lock file.
- `nuget.config` names nuget.org alone, so no source of a machine's own setup is asked.
- The self-check has no lock file of its own: its one package is the library's, and a lock file there would change
  with each machine's AOT compiler package.

## What the library does as the Swift apps do, and where it is stricter

- **The decoders** have the rules of a Swift `Decodable`: a field that is not optional must be there and must not be
  null, a number is never read from text, and an unknown field is skipped. Each answer is read with the size cap of
  the Swift client before it is parsed, and then checked as the Swift decoder checks it: the schema, the generation,
  the agent or task asked for, unique ids.
- **The client** is the iPhone's `MobileClient` with the Mac's hardening: no redirect, no cookie, no stored
  credential, the device's key as a bearer token on every call, the Mac's timeouts (15 seconds a call, 40 for the
  wait, 90 for a knowledge file). It takes gzip and no other encoding. It uses no proxy, so the key goes to the hub
  and to nothing between.
- **The canonical statement** is written by hand, equal byte for byte to Python's
  `json.dumps(obj, sort_keys=True, separators=(",", ":"), ensure_ascii=False)`: the keys in code point order, Python's
  escapes, and floats as Python's `repr`. The vectors hold each character class that the .NET writer gets wrong.
- **The owner signature** is checked as `vault.owner_signed` checks it: strict base64, the one shortest DER form, r and
  s below n, either s.
- **The release manifests** are read as `AppUpdate.readManifest` and `releases.read_manifest` read them, and their
  Ed25519 signature is checked as `releases.verify_signature` checks it, which also refuses a key of small order.
- **Stricter than Swift**: a shape is anchored at both ends of the text, so a final newline never passes; a manifest's
  `hold` must be JSON true or false (Swift also takes 0 and 1), and its `build` and `size` JSON whole numbers (Swift
  also reads true as 1).
- **Keys** are software keys behind `IOwnerKey`. The key in the TPM is a later slice (1.5), on Windows.

## Before the first release

- The .NET runtime of a build that ships must be 10.0.14 or later: GitHub's advisory GHSA-p3jp-9v83-76w9
  (CVE-2026-111497, a Brotli decoder out-of-bounds write, 3 November 2026) covers every .NET 10 runtime before it.
  The client never decodes Brotli from the network, but the runtime of the app carries the decoder.
- The decode twin becomes a part of the app decode check of `COORDINATION.md` after the first Windows release.
