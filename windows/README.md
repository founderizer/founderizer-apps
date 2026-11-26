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
| `Founderizer.Core.Tests/` | MSTest: unit tests, the vectors of `../vectors`, and the decode twin (`HubDecodeTwin`, and `OwnerDecodeTwin` as the owner's computer) | any OS |
| `Founderizer.Owner/`, `Founderizer.Setup/` | step 2 (`windows-app-plan-v2.md`, section 6): the owner's pages, and the first run with what the owner's computer sets up; each with its tests in `Founderizer.Owner.Tests/` and `Founderizer.Setup.Tests/` | any OS |
| `Founderizer.Remote/` | SSH from the owner's PC (step 2, piece L1): `IRemote` and `SshRemote`, the host key record, the app's own SSH key; the owner's key once and its check (piece L1a). The only project that names SSH.NET; it names no other project. `net10.0`, no Windows call | any OS |
| `Founderizer.Remote.Tests/` | MSTest: against a scratch `sshd` of this machine, and an `sshd` in a Docker container for the password and `sudo -S`; the owner's keys made by this machine's `ssh-keygen`, and in the container by `puttygen` and OpenSSL's `ssh-keygen` | macOS, Linux |
| `Founderizer.Setup/Install/` | the install of a server and the claim of a new hub from the owner's PC (step 2, piece L3): the Mac's `InstallPlan`, `MachineInstaller`, `ServerCheck` and their reads, over `IRemote`; held to `../vectors/remote-install.json` and `install-reads.json` | any OS |
| `Founderizer.Setup/RootJobs/` | the root jobs of the owner's PC (step 2, piece L6): the Mac's sweeps (the owner's access line, the join's hardening, the agents' browser parts), the vault's install and pins and the key registration's proof over `IRemote`; held to `../vectors/remote-root.json` and `remote-vault.json` | any OS |
| `Founderizer.Setup/FirstRun/`, `Founderizer.Setup/Agents/`, `Founderizer.Owner/Reads/` | the first run and the manager's setup as models (step 2, piece L4): the Mac's `FirstRunModel` and its page models, the build, Start again, the records, the password once, the agent setup and its sign-in, and the reads of `GET /ui/servers`, `/ui/machines` and `/ui/team`; held to `../vectors/setup-words.json` and `remote-password.json` | any OS |
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
- **Its life**: `SetFront(true)` when the window comes to the front and `SetFront(false)` when it leaves (in front it
  reads at once, every 10 s with a chat, a task or a write open, else every 30 s, and on each wake of `GET /ui/wait`;
  behind, the open app keeps its key and its wait, and a wake reads the fleet alone, with no chat, no task page and no
  seen mark, so that a new request notifies: decision D4); `OpenChat(agent)` and `OpenTask(id)` while a page shows (null when it goes); `RefreshAsync()` for Try
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
  option)` (never refused: it waits while the store cannot write); `Reply(need, words)` (a quick reply: its words are
  the answer with the box's files, sent at once by `AnswerAsync`'s path, or as `Press` waits); `TickAsync(need, options)`;
  `Hold(need, answer)`, `Undo(need)` and `TicksShown(need, number)` (each answer that a card sends, `CardAnswer.Option`,
  `Ticked`, `Reply` or `Typed`, waits 5 seconds with Undo in `StoreState.HeldAnswers` and then takes the path of the four
  above, the ticks and the typed words when the store can write; `Hold` gives the words that a quick reply that waits for
  nothing put in the box; `AnswerBoxLoad` says what a box and its ticks take at a draw; the screens call it in
  their place, and `RequestCard.Holds`, `RequestStep.Holds`, `RequestCard.Pause` and `RequestCard.OpensTask` say what the
  folded card shows); `ControlAsync(task, action)`; `GuideAsync(task, text)`; `RetryAsync()`; `DiscardRefused()`;
  `AddFileAsync(composer, name, bytes)`, `UploadAsync(composer, requestId)` (a file that did not go goes again) and
  `RemoveFile(composer, requestId)` (composers `agent:<name>` and `need:<id>`); `FileAsync(file)`; `EnrollAsync(code)`;
  `ConnectAsync(address)`; `ForgetKey()`; `ReadDeviceAsync()`; `Unlock()`; `FindHubAsync()`. A write that returns
  words returns the owner's words of what failed. **A press is never lost with no word**: `SendMessageAsync`, `AnswerAsync`,
  `TickAsync`, `ControlAsync` and `GuideAsync` give `Task<string?>`, null when the write went, else the
  owner's words. A press that comes while another write is on its way, or while the reading waits for a read that
  comes in front, waits and goes then, in the order of the presses (the window draws a change after the store made it,
  so a button can still show on). A lasting reason gives its words at once, and nothing goes: a request that waits
  ("A saved request waits. Check it in Settings."), the hub that does not answer (the connection line's words), the
  storage line, or "Not sent. The hub connection changed." for a press whose hub changed while it waited
  (`StoreState.HoldsWrites(now)` says which). A screen shows those words where the press was only where an approved
  element has a place for them (a composer's note); a Pause or a Stop has none, and its line over the page already
  says the same cause.
- **The second set** (windows-app-pictures-2.md, the owner's "Yes, as shown"; each a pure model of one state):
  - the request line of a write that waits (picture 14, the Mac's bar over the composer, on every page):
    `Screens.PendingBar(state, now)` (`State`, `Why`, `OtherHub`, `Text`, `Files`, `Actions`: Refresh receipt
    (`RefreshAsync`), Discard (`DiscardRefused`), Try again (`RetryAsync`)); his bubble has no words while it waits, and a
    refused message is not in the chat;
  - Search (picture 1, Ctrl+K): `Screens.Search(state, words, highlighted, now)`, `SearchModel.Move(highlighted, ±1,
    count)` for Up and Down, `model.Open(highlighted)` for Enter; the highlighted row goes back to 0 when the words change;
  - files (picture 4): `Screens.Tile(state, file, now)` for a file of a message (a picture whole, else its mark; "Not
    loaded" and Read again from `state.FilesUnloaded`, which `FileAsync` keeps), and `Screens.Chip(state, file)` for a
    file that he added (`ComposerModel.Chips`, `AnswerBoxModel.Chips`); the files of a message on its way are not in the
    composer;
  - the notification (picture 10): `store.Notified` gives each `Notice` that is due (`Title`, `Body`, `Tag`), once,
    also behind; take away a shown one whose `Tag` is no longer in `Notifications.Open(hub, fleet)`; a click opens Needs
    you at `Screens.NoticeTarget(state, notice)` (null: only to the front). A notice with no `Need` is the manager's
    warning, the Mac's second kind, which no yes of the owner covers yet: show it only after the coordinator's word;
  - the count on the taskbar icon (the owner's "Yes, add it"): `Screens.TaskbarCount(state)`, null for none;
  - the least size (picture 11): `AgentRow.LineText`, cut with "…", and `AgentRow.LineCount` (" · +N"), kept whole;
  - the small states: `ChatModel.Earlier` ("Earlier messages"; `Screens.Chat(..., shown)` shows the newest `shown`
    items, and each press adds `Screens.EarlierStep`), `ChatModel.LatestWords`, `ChatRow.TimeHover` and
    `ChatRow.CopyWords` (the footer under the pointer; Copy takes `Text`), `PaneModel.Reading` ("Reading the hub…",
    after a second), `NeedsModel.EmptyWords`, an ended request at hand when he chose it (`Screens.Needs(state, chosen,
    …)`, with `RequestStep.AnswerFiles`), `RequestCard.AnsweredHeading`, `YourAnswerLabel`,
    `WhyBlocks` (`NeedBody.Blocks`), `OptionsModel.CanSendTicks`, the board's
    `Waiting`, `PeriodLabel`, `AgentLabel` and their hovers, `EndedGroup.Mark`, `UsageRow.Hover`,
    `AgentPanel.UsageHeading`, `ControlsModel.PauseWords`, `StopWords`, `ResumeWords`, `SettingsModel.LastReadingLabel`,
    and `Screens.Line(state, now, page)` (no Settings button on Settings).
  - the words that a screen must not write itself (the rule of the lane "Localization": each a whole sentence of
    the library): `OptionsModel.SendingWords` (the pressed option's "Sending…", after a second),
    `ComposerModel.PlusHover` (the plus's hover, as the answer box's), `Screens.TaskbarWords(state)` (the taskbar
    count for assistive apps, the Mac's "1 item needs you" and "N items need you"; null with no count),
    `UsageRow.ShareWords` ("42%", as both apps write a share), `ChatModel.EmptyWords` (what an assistive app says for
    the empty chat's mark: "No messages with <name> yet") and `ChatModel.LoadingWords` ("Reading…", a chat's first
    read, after a second), and `ResultModel.OutputLabel` and `HowLabel`. The empty chat and its first read wait for
    their pictures before a screen draws them.
  - the time at the end of an agent's row (`AgentRow.Time`) is the time of its chat's last message
    (`ChatLine.LastTime`, FleetCore's `ChatList.lastTime` since 14 November 2026), also while the line names a task;
    none before the first message;
  - "Latest" and following the end (FleetCore's `ChatEnd`): each chat view and each task's thread keeps one `ChatEnd`
    from its first drawing. Give it the scroll's own measure: `Taken()` when he takes the view in hand (a drag, a
    wheel, a touch that moves it), `Stands(under, moved)` each time the view's offset, its content's height or its
    room changes (`under`: the points of content below the view's bottom edge; `moved`: the offset changed while the
    content's height and the room stayed), and `Rested(under, jumped)` when a scroll ends (`jumped`: the view made that
    scroll itself, to its newest row or to a jump). Go to the newest row when one comes only while `FollowsLatest`;
    draw "Latest" (`ChatModel.LatestWords`) only while `ShowsLatest`; set `FollowsLatest = true` when "Latest" is
    pressed, and false before and after a jump that takes the view from its end. The end is under `ChatEnd.Near` (100);
  - the third set (windows-app-pictures-3.md, the owner's "Yes, as shown" of 14 November 2026):
    - an ended task's result (`TaskPageModel.Result`): `ResultModel.What`, the check as a row that folds and stands
      folded as the page opens (`CheckOpensFolded`; its title `Check`), and inside it `OutputLabel`/`Output`,
      `HowLabel`/`How`, `Note` and `CheckedAt`; `ResultModel.Outputs` only for an accepted result (its states are in
      "The fourth set" below; `HasEffect` is gone: the button has its effect);
    - a task that waits: `WaitingLabel`, `WaitingValue`, `WaitingAgent`, and the state word in `Controls.StateWord` and
      the panel's State (`TaskWords.WaitingFor`, one sentence with its slot, as FleetCore's);
    - a reply in Markdown: `ChatRow.Blocks` (`MessageBlock`: heading, paragraph, item with its marker and level, code,
      quote, rule, table), each with `MessageBlock.Runs` (its inline marks; a code block is one run of code) and a
      table's `RowRuns`;
    - a chat with no message (`ChatModel.Empty`, `EmptyWords`) and at its first read (`Loading`, `LoadingWords`, after
      a second; no empty mark while the chat is not read);
  - a request's card where it was raised (the Mac's rule of 14 November 2026, `ChatPlaces.InTime`): `ChatModel.Rows`
    holds each card at its own time, his answer in his own words as his message (also on its way), and a pressed
    option as no bubble; a card whose answer is his message folds to its title (`RequestCard.Spoken`,
    `ShowsAnswerLine`), and words that he wrote have no check (`RequestCard.ShowsCheck`, `RequestStep.ShowsCheck`;
    `RequestCard.FoldedWords` for an assistive app); an hour's or a day's mark counts a card at the time it was raised.
    In the check's place a card and the answered request at hand draw `RequestCard.AnswerMark` and
    `RequestStep.AnswerMark` (owner API 1.280, `need_marks`; `Screens.AnsweredMark`, the Mac's
    `OwnerNeed.answeredMark`): its `Symbol` is the check, the work mark (the search card's green circle_hint, turning
    once in three seconds while `MarkMoves`, at rest on a last reading and where Windows' animation effects are off),
    the search card's red mark, or, where the task's row needs him, the orange mark (`AnswerSymbol.Attention`): the
    row's own symbol (`Row`, drawn with the search card's icon for it, `SearchCard.IconOf`, in its orange) and the row's
    words, for example "Outcome not known: check it", or, where his own pause that the hub confirmed holds the task (a
    hold of kind "pause" in the hub's state "stopped"), the gray pause mark (`AnswerSymbol.Paused`): the row's
    `TaskSymbol.Paused` in `Row`, drawn with the search card's pause icon in its muted gray, and the row's words,
    "Paused". A pause that waits for its helper's report and a stop stay the check. `Hover` shows under the pointer as the system's tooltip, and
    `Words` are its automation name. The work of a task has `Badge` (`AgentBadge.Of`: the agent's name and its mark at
    rest, grey where the agent is not there) and `Title` in place of `Hover`: its tooltip is the Mac's tag (the
    owner's "Yes, badge as drawn", 21 November 2026; `AnswerMarkView.WorkTag`), the badge then " · " and the title,
    wrapping at 360, under the mark with its words at the answer line's left edge (above it only where the window's
    bottom ends; `PlaceTag`). The view opens it after the Mac's rest of the pointer, 350 ms (`OpenTag`): WinUI puts a
    tooltip that its service opens for the pointer at the pointer, whatever its placement rectangle says. It goes when
    the pointer leaves, when the mark moves, and at a click, a key or a scroll in the window (`Watch`).
    `AnswerMark.Plain`, the check with no words, stands for words that he wrote, a key that answered the request, and
    an answer on its way.
    A request raised before the chat's oldest item stands only while the PC holds the chat's whole history
    (`ChatPageState.Whole`: its first read gave fewer than `StoreState.ChatFirstPage` items);
  - the inline marks of a reply as runs: `InlineMarks.Runs(text)` gives each `InlineRun` (`Text`, `Bold`, `Italic`,
    `Struck`, `Code`, `Link`), read as FleetCore's `MessageBlock.inline` reads them (the Mac's MessageText draws those
    runs); their words joined are always `InlineMarks.Plain(text)`. `Link` is only an http, https or mailto address
    (`InlineMarks.OpensInBrowser`); any other link is its words with no link. A bare address is a link too, as
    Apple's reader on the Mac makes one (the autolinks of GitHub's Markdown, measured on 15 November 2026): an http,
    https or ftp address, a `www.` address (to http) and an email address (to mailto), without a final `.`, `,`,
    `_` or other mark that ends a sentence, with its balanced parentheses, and never in inline code or in a link's
    words. The cases are in `swift-words.json` (`inline`). A code span is CommonMark's, as the Mac reads it (measured
    on 21 November 2026, `CardValuesTests`): a whole run of backticks that no backslash escapes, closed by one as long,
    also over a line's end (a space); one space goes from each end only when both have one; a backslash and an entity
    in it stay as written.
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
- **The fourth set** (the owner's "Yes, as shown" of 14 November 2026 to `~/dev/founderizer-plans/
  windows-app-pictures-4.md`; the Mac's rules at `origin/main` of that day):
  - **The checked outputs** (pictures 1a to 1e; the Mac's `ArtifactSection`): `ResultModel.Outputs` is a
    `CheckedOutputsModel`: `Heading`, the button `ViewWords` ("View outputs", or "Reload outputs" once listed) that calls
    `store.ListOutputsAsync()`, `Enabled` (the reading is current and no read runs; the button and each View),
    `ConnectionWords` in orange while the reading is not current, `Loading` ("Loading checked outputs…" or "Loading and
    verifying output…") with `CancelWords` that call `store.CloseOutputs()`, `Error` in orange (the Mac's sentences
    of `OutputException`, or "Hub refused the request (413): …" with the hub's words), `NoFilesWords` for a result with
    no file, `Files` (each `OutputFileRow`: `Path`, `IsImage` for the picture's mark or the text's, `ViewWords`, and
    `ViewName` for an assistive app; View calls `store.ViewOutputAsync(row.File)`), and `Opened`
    (`OpenedOutputModel`: `Path` in semibold and `CloseWords`, which call `store.CloseOutputs()`; `Text` in the code
    font in a scroll `TextHeight` high, or `EmptyWords` when `EmptyText`; or `Picture`, the verified bytes, with `Width`
    and `Height`, drawn from a thumbnail of at most `ThumbnailMost` pixels and at most `PictureMaxHeight` high, named
    `PictureName` for an assistive app; then the fold `Download`, "Verified download · 149 bytes", which opens on
    `Facts`: Snapshot commit, SHA-256 and Type). The store reads and checks each file as the Mac does (`HubClient
    .TaskArtifactsAsync`, `TaskArtifactAsync`: the hub, task and commit headers, the type, the size, the SHA-256, strict
    UTF-8, a PNG or JPEG of at most 16,384 a side and 40 million pixels); a list that changed takes the list with it; the
    section clears when its task's page closes, and holds only "Output discarded because the hub state is stale." when
    the reading turns old.
  - **The steps of a task** (pictures 2a and 2b; the Mac's `RuntimeActivity`, in full since the owner's words of
    14 November 2026, "it needs to match the mac"): `TaskPageModel.Thread` replaces `Notes` under what the task asks
    (`Notes` stays, the notes alone, until the window reads `Thread`). Each `ThreadRowModel` has its `Key` and `Kind`:
    `Steps` (`StepsModel`: `Symbol`, `Title` "8 steps" or the step that runs, `Status` "1 failed" (`Orange`), "Step 8 ·
    Running" or none, and its `Rows`), `Message` and `Note` (both `Words`, a `NoteRow`, drawn as the agent's reply),
    `Error` (`Text` in orange with the error's mark), `Truncated` (`Text`, muted), `Permission` (picture 2c:
    `PermissionRowModel`: the hand, `Title` the tool, `Status` "Waiting" in orange, and opened `Input` in the code font,
    then `Reason` once decided) and `Guidance` (`SteerRowModel`: his words in his bubble, `Line` "Guidance · Attempt 1 ·
    Read" under it, muted, and `Hover`). A thought is a step of its run, as on the Mac. Each step is a `StepRowModel`
    with its `Kind`: `Tool` (its `Symbol`, `Title`, `Status`, `Orange` and a chevron; opened, `FullTitle` in the code
    font, `Locations`, `Output` in the code font, `Script` with the fold `ScriptResultTitle` over `ScriptResult`, and for
    a child agent `ChildLines` and `OpenChildWords`, which opens `Screens.ChildThread(state, task, row.Child, …)`),
    `Thought` ("Thinking", its `Text` opened), `Plan` ("Plan", its `Plan` steps opened), and in a child agent's thread
    also `Message`, `Error` and `Truncated`. `StepSymbol` names each mark: `Read`, `Search`, `Edit`, `Execute`,
    `Fetch`, `Other`, `Thought`, `Subagent`, `Plan`, and `Steps` for a run with no step that runs. A child agent's
    thread (`ChildThreadModel`) takes the task thread's place: `BackWords` (one level up), `Title`, `AttemptWords`, its
    `Rows`, and `WaitingWords` while it has none. Over the thread: `ActivityError` (orange: its last read failed; leave
    it out while the window's line over the page shows) and `OfflineWords` (orange: the reading is not current). The
    page shows the last `StepWords.ShownAtOnce` (80) rows, `EarlierWords` shows 80 more, and rows that come while he
    reads further up add to what shows (`ThreadTopRows` grows). Under the thread while the task runs: `LivePlan`, the
    steps of the plan of the work that runs (`PlanStep`: its words, done muted, running, or to do). The panel: the fact
    "AI provider" after Attempt, then for each model of the attempt "Model requested", "Model used", "Reasoning
    requested", "Reasoning used", and a `Fact` with `Warning` ("The AI provider used other settings", orange, no label);
    after the facts, `TaskPageModel.ParentTask` ("Parent task · <title>" in the link's colour; a press opens
    `ParentTaskModel.Id`) and `Subtasks` (`Heading`, each `SubtaskRow` with its `Title` on two lines at most and its
    `Status` muted under it; a press opens `Id`), from the task read (owner API 1.163) or the reading's heads;
    `TaskPageModel.ChildAgents` (`Heading`, at most 20 `ChildAgentRow`s with their `State` mark, name, arrow and
    `Hover`; a row opens its thread; `MoreWords` past 20); and `TaskPageModel.ChangedFiles` (`Heading`, each
    `ChangedFileRow` with `Path`, `Action`, `Added` "+4" in green and `Removed` "−1" in orange, then `Footer`). On a
    current reading of a hub that offers `thread_events`, `Screens.Task` stays null until the first read of the task's
    record has every page, so the thread and the panel come in one frame, as the Mac's. The store reads the open task's
    record every 3 seconds while it is not behind (`OpenTask`), until a read after the task ended brings no more; the
    task read brings the guidance (owner API 1.162).
  - **A request that waits, as an agent's line** (the Mac's Founderizer 0.1.224, `ChatList.waitingRequest`): when the
    card of a request that waits for him is the newest thing in the agent's chat (the chat's own places, over its newest
    `ChatLine.RowReads` items), `AgentRow.Line` is its title with `NeedsYou` true: draw it in orange, whole, with no
    " · +N" count, and `AgentRow.Time` is the card's (`ChatLine.RequestTime`). While the agent works, the line of its work
    wins and `NeedsYou` is false. The status dot does not change. The search card's agent rows say the same line with
    `SearchAgentRow.NeedsYou`. A chat that the store has not read yet keeps the hub's last line until its read.
  - **A parked task** (picture 3 as the Mac draws it): its card stands in Waiting with `TaskCardRow.Why` "Until 16:00"
    (`Screens.Parked`), while no hold of the owner's and no usage limit holds it; its mark is no work now; its page says
    its state word, as the Mac's does. A task in state working whose session does no work now while subtasks of it are
    open stands in Waiting too, and its card's `Why` and `Hover` say "Waiting for" and their agents (the Mac's
    Founderizer 0.1.220; `Activity.SubtaskWaits`, owner API 1.162 gives each head its `parent`).
- **The Ended lane of every ended task** (the owner's "Yes, as the Mac" of 14 November 2026; owner API 1.166): with a
  hub that offers `mobile_ended`, the store reads `GET /ui/mobile/ended` (`HubClient.EndedAsync`) at its first pass
  and again whenever the reading's `MobileSnapshot.EndedMark` is not the `Mark` of the read that it holds
  (`StoreState.Ended`), and `Screens.Board` counts and opens every ended task of its period from it, as the Mac does:
  `LaneModel.Count`, `EndedModel.Failed`, `RestWords` and `Days`, with the runs of one schedule as one row
  (`MobileTaskHead.TriggerId`). Nothing changes for the window: the lane has the same models. With an older hub the
  lane is the 20 newest ended tasks of the reading, as before. The pane's Needs-you count, the agent filter, Search
  and a task's parent and follow-up title read the same heads (`StoreState.AllTasks()`). With a hub that offers
  `ended_blocks` (owner API 1.270), the store reads the heads of the newest ids (`HubClient.EndedWindowAsync`), and
  the older ones in blocks of 100 ids (`EndedBlocksAsync`, `EndedBlockAsync`), each once and again only when its mark
  moves; it keeps the blocks in its folder `ended` and joins them (`EndedBlocks`), so `StoreState.Ended` holds every
  ended head, and no read grows with the fleet's history.
- **The Mac's request card of Founderizer 0.1.239** (app commit `95811d21b`; the owner, 15 November 2026: "the task
  itself need to be very clear and also formatted like the chat messages (links, code format etc)" and "apply the
  style of the hover time (relative too)"). **Names beside the present ones**: the window keeps drawing the present
  fields, the look of the approved pictures, until the owner says yes to a picture of this card.
  - `OwnerNeed.TaskInFront` (`Kind` and `DoorCall` both null): the task stands on the front of the card.
  - `RequestCard.Body` and `RequestStep.Body`, a `RequestBody`. The reason is `WhyBlocks`, whole while `Short` or open,
    else `FoldedWhy` drawn with `InlineMarks.Runs` in at most three lines. The task on the front is `Task` and
    `TaskBlocks`, under the reason, with a message's room between them. A command is a `Kinds.Code` block: on a card,
    a well in the canvas's colour; on the request at hand, a step's code size; in both, the chat's copy icon.
  - The link is `MoreClosed`, `MoreOpen` and `MoreChevron`, or null when nothing stands behind it. A card with no
    details says Show all. Behind the link stand `DetailsBlocks` and the task that stays there, `TodoBehind` and
    `TodoBehindBlocks` under `TodoLabel`. The door's script (`DetailsIsScript`) is the one code block of the hub's own
    details: it wraps and has no copy icon, and its text has its own fence, so give it no second one.
  - The request at hand stands in the middle by `CentredClosed` and `CentredOpen`; a card reads from its edge.
  - Each value that the agent put in inline code is a chip with a copy icon (the owner's "Yes, as drawn" of 21
    November 2026): `WhyValues`, `TaskValues`, `DetailsValues` and `TodoBehindValues`, one list of `CardValue`s
    (`Start` in the block's plain words, `Text` to copy) for each block of `WhyBlocks`, `TaskBlocks`, `DetailsBlocks`
    and `TodoBehindBlocks` (`CardValues.OfBlocks`); none in a code block, a table or a door's script, and none for
    `FoldedWhy`. A chat's message has none.
  - `ChatRow.AgeWords` ("5 min ago", or the state of his message on its way), and its hover `AgeHover` (the exact date
    and time of a reply, or the present `TimeHover` of his message). While `AgeMoves` is true, read the words again
    when the footer shows, with `Screens.MessageAge(row.Time, now, context)`.
  - The room over the composer is the window's own measure: the Mac's `ManagerView.endRoom`, 88 points under the last
    row, which "Latest" leaves out of its measure.
- **Pictures as the options of a request** (owner feature `need_pictures`, owner API 1.285; the owner's "Yes, as shown"
  of 21 November 2026 to `w4-windows-chat.png` and `w4-windows-needs.png` in
  `~/dev/founderizer-plans/needs-you-picture-options-2026-11-20/`):
  - `OwnerNeed.Pictures`: one picture for each option, in their order, each a file of a message; null for an item with
    none. One option is a choice on an item with one picture for it.
  - `RequestCard.Options` and `RequestStep.Options`: `OptionsModel.Pictures` holds one `FileTile` for each option
    (`Screens.Tile`), only as `NeedPictures.Drawn` says: on a hub that names the feature, for an open item whose
    pictures are as many as its options, each a picture. Else it is empty, and the card is the card of before.
  - Draw them `NeedPictures.Columns` (three) in a row, a row more for each three more, each picture a square as wide as
    its column with a card's corners, the option's row under it (the rows of one row of pictures take one height), 7
    apart in a chat's card and 8 at hand, and "Your answer" under them. While its bytes come, the square keeps its size
    with the tile's words in it ("Reading…", or "Not loaded" with Read again), as a picture of a message.
  - A click goes through `OptionsModel.Click(index, onPicture)`: on a picture, `Open` with its `FileTile`, which opens
    it as a file of a message opens (`FileAsync`, then the app that Windows gives its kind), and sends nothing; on the
    words, `Press` with the option's index (`Press(need, index)`, `choice`), or `Tick` for options that combine, whose
    ticks and "Send N" stay under the pictures.
  - A page reads its pictures, a message's and an option's, through `PictureLoads<T>`: one read at a time, in the order
    asked (a card asks in the order of its options); a failed read stays failed until Read again (`Again`), so a draw
    after a failure starts no read; a picture is its id and its SHA-256, and `Generation` with the hub and its
    generation forgets every picture of another one. `Mark` gives a tile "Reading…" while its read waits or runs.
  - The read of the state says what this build draws: `GET /ui/mobile` carries `X-Fleet-Draws: need_pictures`
    (`HubClient.DrawsHeader`, `HubClient.Draws`), as a device and as the owner's computer. The hub raises an item with
    pictures only while each app of the owner's says it.
  - The proofs' sample state `pictures` (`Fleet/SampleStates.cs`) adds Marketing's request of three banners, whose bytes
    come from the folder that `FOUNDERIZER_SAMPLE_PICTURES` names.
- **Needs clarification on every card** (owner feature `need_clarify`, owner API 1.272; the same two drawings, which put
  the link under "Your answer"):
  - `RequestCard.Talk` and `RequestStep.Talk`: his talk with the agent (`TalkLine`: `Own`, `Text`, the agent's `Mark`),
    oldest first, from the reading or from the receipt of his last message (`StoreState.TalkOf`); only on a hub that
    names the feature. Draw it over the options: his lines in his chat's bubble at the trailing side, 48 in from the
    leading edge, and the agent's after its 16-pixel mark, 48 in from the trailing edge. A folded card has none; the
    request at hand keeps it over his answer once it ended.
  - `Clarify` (`ClarifyModel`), null where the card takes no message (`OwnerNeed.Clarifies`: an open item whose
    `clarify` is true, on a hub that names the feature): `LinkWords` under "Your answer", or, while `Stands`, the
    answer's box with no plus, `Placeholder` ("Message to" and the agent), `Draft`, and Send while `CanSend`. A press on
    the link is `OpenClarify(need)`, his keys `SetClarifyDraft(need, text)` (in memory only), Send or Enter
    `TalkAsync(need)`. The field goes back to its link once the outbox has his message; a refused one's Discard gives
    its words back. `OpenClarify` is true when the field stands.
  - Keep one `ClarifyField` for each view of a card: `Show(id, model, text)` says which words to put in the field (only
    when it comes to stand, for another card, or for a new `ClarifyModel.Given`) and whether it takes the cursor now
    (once, after `Opened(id)`, which the view calls when `OpenClarify` was true); `Typed(text)` gives the card of a
    change that is his, and null for a change that the view made (a text box reports those too) or of a field that
    does not stand.
  - The proofs' sample state `clarify` puts the feature on the hub, `clarify` on the manager's cards, and a question and
    a reply under the card about the email.
- **Words that look like a key wait for his choice** (UI-API 1.249; the Mac's `KeyHoldBanner`; the owner's "Yes, as
  drawn" of 22 November 2026 to `windows-key-hold-2026-11-22.png`, and his "Yes, as shown (Recommended)" of the same
  day to `windows-key-hold-card-2026-11-22.png` and `windows-key-hold-clarify-2026-11-22.png`): in the chat's
  composer, a request's answer box and the field of Needs clarification.
  - The rule is `KeyInText` (`First(text)`, its place in UTF-16 units, and `Contains`), FleetCore's rule for rule;
    `app/vectors/key-in-text.json`, which FleetCore's `KeyInTextVectorsTests` writes, holds the two equal
    (`KeyHoldTests`), and the test holds its 15 shapes and its run equal to the literals of `KeyInText.swift`. The
    vectors hold each text in parts that a reader joins, so that no file holds a key's whole shape. Where .NET's own
    rules differ from the Mac's, the rule takes the Mac's: ICU's word boundary (`KeyInText.Boundary`: a combining mark
    or a format character is skipped, and a letter outside the first plane is a letter), Apple's whitespace, which
    holds the zero-width space, and Foundation's search where it looks for `://`, `?` and `#` in a web address (by
    UTF-16 unit, and a find does not count when a non-spacing or enclosing mark, a variation selector or U+200C comes
    right after it; some other marks differ, see the commit).
  - `ComposerModel.KeyHold`, `AnswerBoxModel.KeyHold` and `ClarifyModel.KeyHold` (`KeyHoldModel`): while the box's
    words hold such a key and he did not keep it (`StoreState.HoldsKey(box, text)`, the boxes `KeyHold.Chat(agent)`,
    `Answer(need)` and `Talk(need)`), draw the hold over the line inside the field's edge, its `Words`, its `Line` and
    the button `KeepWords`, and no Send (`CanSend` is false; `AnswerBoxModel.CanSend(..., held:)`). The button is
    `KeepKey(box)`. Enter and Send do nothing while `HoldsKey` is true, also before the next draw.
  - The store sends no such words, by any path (`SendMessageAsync`, `Hold` of typed words, which then does not fold the
    card, `AnswerAsync`, `TalkAsync`), until `KeepKey`; "Keep it" lasts while the box's words hold a key, so the next
    key asks again. The hold is decided once, at his press, and a write that waits behind another write carries that
    decision: the field empties as his Send goes, which ends "Keep it". The drafts' file keeps no draft with such words,
    also after "Keep it", and a box that held one stays out of the file until it is empty or its words went
    (`StoreState.KeyDrafts`): one Backspace in a pasted key leaves words that no longer match. Undo marks the words
    that it gives back in the same way. The safe side, by choice: new words typed over a whole key (select all, then
    type) also stay out of the file until the box is empty once.
  - Not here, as the Mac has them: "Save it as a secret" (this app has no form of a secret yet, `secrets` waits for
    2.3), and the hold of a paste ("Paste it anyway"), which is that button's way to the clipboard: a pasted key stands
    in the box and the hold takes it. Guidance for a task and a card's feedback have no hold yet.
- An element that needs a hub feature asks the model, which reads `ui_features` (`state.Offers(...)`): the
  task's controls (`task_controls`) and its guidance (`task_steering`), the plus of the files
  (`attachments`), the chat of an agent other than the manager (`direct_chat`).
- `Directory.Build.props` no longer sets `InvariantGlobalization` (the self-check sets it for itself), so the screens
  write dates and times in the user's culture.
- **The owner's computer (step 2, piece L0, the seams; `windows-app-plan-v2.md`, sections 5.1, 5.2 and 6)**: the PC is a
  device of a hub (step 1) or that hub's owner's computer, one role for each hub. `state.Role` (`HubRole`: `Device`,
  `Owner`) is kept with the hub's address; a kept hub of step 1 reads as `Device`.
  - **The settings**: `Box`, the secret box (`new FileSecretBox(folder, protection)` under
    `%LOCALAPPDATA%\Founderizer\keys`, with an `IKeyProtection` whose purpose text is not the device key's; null: this
    PC can be no owner's computer); `Can`, the hub's names of what this build can do (`run`, `takeover`, `door`, and a
    page family's name: `agents`, `servers`, `secrets`, `apps`, `people`, `channels`, `knowledge`, `backup`,
    `devices`), which the window composes from the families that it has; `Welcome`, true once the window has the
    welcome page of the first run (piece U1).
  - **The first page**: with `Welcome`, a PC with no hub opens on the welcome page (`PageKind.Welcome`) once its search
    found no Tailscale or no hub on it (`HubSearch.NoNetwork`, `NoHub`), and on Add this PC while it looks, so a hub
    that the search finds opens Add this PC; without `Welcome`, as in step 1. The owner's computer of a hub never opens
    on Add this PC.
  - **The claim**: `ClaimAsync(claim, code)` sends the installer's code to `http://<address>:8765/claim` (only an
    address of 100.64.0.0/10) with the SHA-256 of this PC's new key (`OwnerPcKey`), and then is the owner's computer of
    that hub (`ConnectOwnerAsync(hub)`). Null when the hub took it; else the owner's words (the listener's own, or the
    Mac's). An answer that was lost loses no key: a claim made again sends the same key, and the first read that the
    hub takes with it makes it the key; and when the hub refuses the kept key while a key waits beside it (a second
    claim whose answer was lost), the next read carries the one that waits (the Mac's rule of two keys; a refused one
    that waits goes again after 30 seconds). `ConnectOwnerAsync(hub)` alone takes a hub that this PC owns already (the
    address is its number). Connect (`ConnectAsync`) keeps the role of the address that the PC has, and takes another
    address as the owner's computer when the box holds a key of the owner's computer for it, else as a device.
  - **The key on every call**: as the owner's computer, every call carries the key of the owner's computer for that
    hub, the device reads too; as a device, the device key. As the owner's computer, `ForgetKey()` takes nothing off.
    A box value that does not open stops no claim and no read: a claim makes a new key in its place.
  - **An owner page's calls**: a family's client calls `store.OwnerGetAsync(route, type)` and
    `store.OwnerPostAsync(route, body, bodyType, answerType)` with the `JsonTypeInfo` of its own JSON context. They go
    through `HubClient.OwnerGetAsync` and `OwnerPostAsync` with `store.Call()` (`OwnerCall`: the hub, the key, the
    generation, the client's label; its text holds no key): `db` on a read; `request_id`, `db` and `X-Fleet-Client` on
    a write, in the Mac's envelope. An `OwnerAnswer<T>` is its `Value`, or `IsGenerationChanged`, a 409 whose `code` is
    `hub_changed` or `hub_changed_sending`: the store then reads the fleet again by itself. Any other refusal, another
    409 among them (a stale base, a request number used again, an action that the state does not allow), is a
    `HubException` with the hub's words and its `Code`.
  - **What the PC says it is**: to a hub that offers `owner_computer` (owner API 1.273), the store sends
    `POST /ui/owner/computer` with exactly `{"can": [...], "kind": "windows"}` by itself after a claim, a new key, a
    start and a new generation (`SayComputerAsync`, true when the hub keeps a PC). An answer, a refusal among them, ends
    the tries until the next of those; no answer, or a fault of the hub, is tried again at the next read.
- **Tailscale's API and the cloud providers (step 2, piece L2; `windows-app-plan-v2.md`, sections 5.4, 5.6 and piece
  L2)**: `Founderizer.Setup/Network` and `Founderizer.Setup/Cloud`, with no Windows call. All HTTP of both goes through
  the `HttpMessageHandler` that the caller gives: the window gives `ProviderHandler.Create()` (no redirect followed, no
  cookie, the system's proxy). Every request carries one fixed User-Agent, `Founderizer/<version> (Windows)`, and a
  provider's ids are read as 64-bit numbers, as Swift's `Int` reads them (Hetzner's pass 32 bits). Each request, each reading of an answer and each word is the Mac's, held so by
  `app/vectors/tailscale-requests.json` and `cloud-requests.json`, which FleetCore's own code writes.
  - **The fleet key**: `new TailscaleApi(handler, box)`. `MakeFleetClientAsync(accessToken)` takes the token that the
    owner pastes once (`TailscaleApi.KeysPage`), adds `tag:founderizer` and the fleet's two grants to a policy file
    that Tailscale keeps (inserted bytes only, checked by Tailscale first, set against the version read), never writes
    a file that another tool keeps, and keeps the OAuth client in the box (`TailscaleApi.ClientName`); the token is
    kept nowhere. Its `FleetKeySetup` says whether the key was made, whether the file was written, and, when the tag is
    missing from a file that the PC may not write, the one line to add (`LinesToAdd`) and the page's line over it
    (`Asks`, by `PolicyPlace`). `IsHeld`; `AuthKeyAsync(hostname, life)`: one key for one machine, single-use,
    pre-authorized, tagged, not ephemeral (the Mac's `mintAuthKey`; the fleet key gives only its one tag, so the call
    takes no tags); `JoinedAsync(hostname, since)`, `DevicesAsync()`, `DeleteDeviceAsync(id)`. A stop is a
    `FleetKeyException` (`Failure`, `Says`, and the Mac's sentence with "PC" as `Message`).
  - **This PC on the network**: `PcNetwork.State(statusJson, installed)` gives the `Standing` (`Step`, `Address`,
    `Tailnet`, `Says`, `Mark`) from the text of `tailscale status --json`; `Devices`, `Live`, `OwnName`, `DeviceOf`,
    `Online`. `PcNetwork.InstallerFor(PcNetwork.Arch(RuntimeInformation.OSArchitecture), json)` picks Tailscale's MSI
    from `PcNetwork.Packages`: the window downloads it, checks `InstallerOrganisation` and `InstallerCountry` with the
    revocation check (section 8.2), and starts Windows' installer. `FleetReach.Keeps`, `Hidden`, `Unseen` and
    `Unreached` say why a server that joined is out of this PC's sight.
  - **A provider**: `CloudServers.For(provider, handler, box, zone, pause)` gives an `ICloud`: `CheckTokenAsync`
    (the token checked by a read and by writes that make nothing, then kept in the box under
    `provider.BoxName()`), `OffersAsync(use, except)` (each type that fits, at its cheapest and nearest place; a
    `CloudOffer` with its words `Size`, `Choice`, `Row`, `Brief`, `Pick`, `Amount`), `ServersAsync()` (a
    `CloudExisting` with its `Summary`), `MakeAsync(new CloudOrder(name, use, publicKey, authKey, offer))` (behind a
    firewall that lets nothing in, on the network from its first boot; a step that fails takes back what it made, or
    says what is left), `DeleteAsync(id, accepted)`, `FirewallsAsync`, `DeleteFirewallsAsync`, `DeleteFirewallAsync`,
    `DeleteKeyAsync`. A stop is a `CloudException`; `CloudStop` says whether it asks for the token again or reads the
    list again. `CloudJoin.WaitAsync` waits for a new server on the network for its key's hour. The page's link for a
    token is `provider.TokenPage()`. The rules of the list that need the install's systems, the hub's list or this
    PC's build records (the Mac's `unfit`, `reuse`, `hubAgain`) come with pieces L3 and L4.

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

### SSH from the PC: `Founderizer.Remote` (step 2, pieces L1 and L1a)

For `Founderizer.Setup` (the install, the claim, the root jobs): no page calls SSH (`windows-app-plan-v2.md`, 5.5
and 6). These names stay.

- `IRemote.RunAsync(RemoteCall, Action<string>? line, CancellationToken)` gives a `RemoteResult(ExitStatus, Output,
  Errors, Failure)`: one program on one server, on a connection of its own, as the Mac's `ssh` makes one for each
  program. A failure is a result, with `ExitStatus` null. `RemoteFailure` has the Mac's kinds of not reaching a server
  (`ServerCheck.unreached(_:said:)`), one sentence each: `NotFound` (the name), `Refused` (the port), `Closed` (the
  server closed the connection, or found no common way to talk, before any login) and `NoAnswer` (no answer in time);
  then `HostKeyChanged`, `HostKeyUnknown`, `LoginRefused`, `LoginNotOffered` (a password to a server that takes keys
  only: `PasswordOnce.refusal`; the password was not sent), `Dropped`, `TimedOut` and `Canceled`. An exception is a
  fault of the caller: a call that
  `RemoteRules.Check` refuses (an address or a user that the Mac's `InstallTarget.problem` refuses, a program with a
  carriage return or a NUL), or `AppKey` while the secret box has no key.
- `RemoteResult.LoginWays` (piece L4c; the owner's "Key row here too", 21 November 2026): with `LoginRefused` or
  `LoginNotOffered`, the ways in that the server named with its last refusal of the call's own login ("publickey",
  "password", "keyboard-interactive"), as it sent them. Null for every other result, for a server that named none, and
  for a server that refused before the call's own way was tried (it named none of the call's ways: SSH.NET keeps that
  first answer to itself). The call sends no password to learn it. The list chooses a page and nothing else; nothing
  keeps it. Proved against the scratch `sshd`, which takes keys only, and the same `sshd` with the password ways on.
- `RemoteCall(Target, Program, Input, Login, HostKey, Connect) { Limit = … }`. `Program` is the text that the Mac gives
  `ssh`, after `InstallPlan.throughSudo`; `Input` is its standard input, and null is an end of file at once (the Mac's
  `/dev/null`). SSH.NET sends the end of an input only after one byte of it, so such a program goes to the server as
  `/bin/sh -c 'exec "${SHELL:-/bin/sh}" -c "$0" </dev/null' '<program>'` (quoted as `InstallPlan.quote`): sh takes
  `/dev/null` and gives the program to the user's own login shell, as `sshd` would (tested with zsh and tcsh).
  `RemoteCall.ConnectTimeout` is the Mac's 20 s. `Limit` bounds the whole call, `RemoteCall.DefaultLimit` (600 s, the
  Mac's `LocalShell.run`) unless a step gives its own, and ends it as `TimedOut`. The Mac's `Runs.rootWithPassword`
  stays the caller's: the password's line first in `Input`, and the caller clears its `Input` after the call. A call's
  text (`ToString`) names its server alone: a program can hold a one-time code.
- `RemoteLogin.AppKey()`, or `RemoteLogin.PasswordOnce(char[])`, whose array the call clears when it ends. The password
  goes once: by keyboard-interactive (PAM's prompt) where the server asks so, else by the password method, never by
  both.
- `RemoteLogin.KeyOnce(byte[] KeyFile, char[]? Passphrase)` (piece L1a; the owner's "Choose key, as Mac" and "One
  field, only then", 21 November 2026): the bytes of the one file that the owner picked in Windows' own picker (the
  window reads it, at most `OwnerKeyFile.MaxLength`, 64 KiB; this library opens no file) and its passphrase or null.
  The call offers that key and no other (never the app's key, never a password), and clears both arrays as soon as it
  has read the key, before it connects, so they are zero after the call whatever its end. A server that does not take
  the key is `LoginRefused`. A file that does not open throws `ArgumentException` before any connection. An RSA key
  signs with `rsa-sha2-512` or `rsa-sha2-256`, never with SHA-1 (`ssh-rsa`), as the Mac's OpenSSH 10.
- `OwnerKeyFile.Check(byte[]? file, char[]? passphrase)` gives `OwnerKeyCheck.Usable`, `NotAKey`, `NeedsPassphrase` or
  `WrongPassphrase`, before any connection, so a wrong file or a wrong passphrase costs no login try at the server. It
  keeps nothing and changes neither array: give the same two to `KeyOnce`. A null or empty passphrase is none. The
  formats, each proved with a key that a test makes with the tool that owners use: OpenSSH's own (`ssh-keygen`'s
  default: Ed25519, RSA, ECDSA), PEM (PKCS#1 `RSA PRIVATE KEY`, SEC 1 `EC PRIVATE KEY`), PKCS#8 (`PRIVATE KEY`,
  `ENCRYPTED PRIVATE KEY`) and PuTTY's `.ppk` (versions 2 and 3, of `puttygen` 0.81), each with and without a
  passphrase. Not read, so `NotAKey`: DSA (with or without a passphrase: the type, which OpenSSH's format and PuTTY's
  keep in clear text, says so before any passphrase is asked), a public key, and an ECDSA key in PEM or PKCS#8 whose
  curve is written as numbers and not by its name (what `ssh-keygen` with LibreSSL 3.3.6 writes on macOS; OpenSSL 3
  names the curve). A key that opens must sign and check its own signature, or it is no key. SSH.NET 2026.0.1 reads
  Ed25519, ECDSA and RSA only, so a security key's file (`sk-ssh-ed25519@openssh.com`) is no key by the same rule (not
  measured: making one needs the hardware).
- `line` gets each line of standard output and of standard error as it comes, without its line end, one at a time,
  never after the call has returned. `Output` and `Errors` keep the first 1 MiB each. The Mac's `LocalShell` gives one
  text for both streams; their order between each other is the order of `line`.
- `new SshRemote(new HostKeys(appFolder), () => box.Read(AppSshKey.BoxName))`: the function gives a fresh copy of the
  key's private half, which the call clears. `DisposeAsync` cancels each call that runs and waits for it.
- `HostKeys`: `known-hosts.json` in the app's folder; the owner's own `%USERPROFILE%\.ssh` is never read or written.
  `TakeNew` (`accept-new`) keeps the key of a server with none on record. Under either rule, a server with a key on
  record must show that key, of that type; a key of another type is a changed key (OpenSSH's `accept-new` would take
  it). **The rule by port** (the Mac's `hostKeyOptions`, 22 November 2026): only port 22, or a port that the owner gave
  for that very host (`RemoteTarget.PortGivenFor`, `PortIsOwners`), has a line of its own and keeps a new key. At any
  other port, a port of the hub's record, the server must show the key of the host's port 22 line (the Mac's
  `HostKeyAlias`) under either rule, and a line of `[host]:port` is not read. The owner's typed `user@host:port`
  (`SetupStore.Target`) gives its port for its host; an install's move to the private address that the server printed
  keeps it (`Installer.Moved`); a move to an address of the hub's (`MachineReach.Reaching`) does not. `Forget(host, port)` when a server is removed, `ForgetAll()` at start again. A file that cannot be read refuses
  every server as `HostKeyChanged`, and nothing writes over it, until `ForgetAll`. No method takes a changed key, and
  none is added.
- `AppSshKey.Make()` gives `(PrivateKey, PublicLine)`: 32 bytes for the box under `AppSshKey.BoxName`, and
  `ssh-ed25519 <base64> founderizer` for a server's `authorized_keys`. The key is never a file.

| The Mac's `ssh` (`InstallPlan.arguments`, `PasswordOnce.passwordLogin`) | `SshRemote` |
| --- | --- |
| `ConnectTimeout=20` | `Connect`: the connection, the greeting, the key exchange and each wait of the login |
| `LocalShell.run(timeout:)`, 600 s unless the step gives its own | `Limit`, `RemoteCall.DefaultLimit`; `TimedOut` |
| `ServerAliveInterval=30` | a keep-alive every 30 s |
| `BatchMode=yes`, `NumberOfPasswordPrompts=0` | `Login` alone |
| `StrictHostKeyChecking=accept-new`, `=yes` | `HostKeyRule.TakeNew`, `.Known` |
| `IdentitiesOnly=yes -i KEY` | `RemoteLogin.AppKey` |
| `-i` with the file of "Choose key" (`MachineInstallView`), kept in the server's record | `RemoteLogin.KeyOnce`, for the one call that adds this PC's key; nothing is kept, not even the path |
| `SSH_ASKPASS` and its pipe, `NumberOfPasswordPrompts=1` | `RemoteLogin.PasswordOnce`, sent once |
| status 255 and `ssh`'s own line | `Failure`, one kind for each line that the Mac reads |
| OpenSSH 10's algorithms | the same: no SHA-1 key exchange, no CBC, no `ssh-rsa` host signature, no compression |

Where it differs: a server that goes silent (no reset, no answer) ends the Mac's `ssh` after three keep-alives with
no answer (about 90 s); SSH.NET's keep-alive asks for no answer, so the call ends when the PC's TCP gives up on the
keep-alive that waits (not measured on Windows), and at the latest at its `Limit`, as on the Mac. A server that ends
the connection is `Dropped` at once on both.

### The install and the claim: `Founderizer.Setup/Install` (step 2, piece L3)

For piece L4 (the first run and the agent setup, as models) and the window's build pages. The Mac's
`MachineInstall.swift`, `MachineInstaller.swift`, `ServerCheck.swift`, `InstallCause.swift`, `InstallRetry.swift`,
`InstallPhases.swift`, `InstallRecord.swift`, `VerifyChecklist.swift` and `BuildRecord.swift`, with the same steps, the
same programs and the same readings: `../vectors/remote-install.json` and `install-reads.json` hold them, made by
FleetCore's own code (`Tests/FleetCoreTests/RemoteInstallVectorsTests.swift`), and `InstallVectorTests` holds the C#
equal to them. A sentence is the Mac's with "PC" for "Mac" (rule 14). Namespace `Founderizer.Setup.Install`. These
names stay.

- **The plans**: `InstallPlan.Hub(target, source, authKey, managerName, oneServer, shape, runtime)`,
  `.Join(target, line, code, authKey)`, `.Check(target, machine)`, `.Restart(target, machine)`,
  `.Update(target, machine, agent, label)`. `InstallTarget(Host, User = "root", Port = 22, BecomeRoot = false)`, with
  `Problem` (the Mac's three sentences) and `Remote` (the `RemoteTarget`). `ServersStep { One, Two, Each }` and
  `ManagerName.AgentName(typed)` (the Mac's FleetShape and ManagerName: L4 takes them from here). A plan's `Steps` are
  `InstallStep(Id, Title, Says, Action)`, and `Redactions` the auth key and the join code; its text names neither.
  `InstallPlan.Command(program, reaching, runs)` is the command that the server gets (the last word of the Mac's
  `ssh` arguments, after `throughSudo`); `plan.Redact(line)` takes the secrets out of a line. The join step sends
  `InstallPlan.VerifyLater` before the hub's line, so that join.sh leaves its checks to the plan's own last step.
- **The installer**: `Installer.For(plan, hubClient, box, authKey, sudoPassword, firstRun, policy)`, or `new
  Installer(plan, authKey, sudoPassword, claim, readHub, clock, verifyPause, firstRun, policy)`; `firstRun` and
  `policy` choose the words of a failure once, for each step's detail and its error's line alike; then `RunAsync(IRemote, Action<InstallProgress>, CancellationToken)` gives the
  server's `VerifyChecklist`, or throws an `InstallError`. A keyed plan's network step sends the installer's `authKey`, so each installer of such a
  plan takes the key that the plan was made with; one made with none stops at that step and sends nothing. `Reached` is where the install reaches the server (its private address after the network step),
  `ClaimedHub` the hub that the claim step claimed (`http://100.x.y.z:8765/`), which the first run then gives
  `OwnerStore.ConnectOwnerAsync`. Every call logs in with the app's own key under `HostKeyRule.TakeNew` (the Mac's
  `accept-new`), with the Mac's time limit of its step (`RemoteCall.Limit`: the check 120 s, a program 1800 s, the join
  3600 s, the network key 3000 s, a read of a wait 120 s). The installer clears the sudo password's array when it ends.
- **`InstallProgress(Step, Title, Says, State, Lines, Detail)`**, as the Mac's: each step as it starts and as it ends,
  its last 12 lines with no secret in them (the auth key, the join code, the link code of a new hub's claim, and the
  sudo password), and a wait's lines as the installer's own steps come.
- **`InstallError`**: `Kind` (`CannotStart`, `Step`, `NotRoot`, `TimedOut`, `NoClaimCode`, `NoChecklist`,
  `CheckStopped`, `NeedsPassword`), `Title`, `Says`, `Failure` (the way IRemote did not run the step's program),
  `Description` (the Mac's `errorDescription`), and `Plain(host)`, the stop row's one line (the Mac's `plain`), whose
  words of a failure take the error's own `FirstRun` and `Policy`. `InstallStops.Of(error)` gives its kind (`InstallStop`, the Mac's names by `.Name()`), and
  `InstallCauses.Of(error)` the installer's cause (`InstallCause`).
- **The check of a server before an install**: `ServerCheck.RunAsync(remote, target, job, login, holdsSudoPassword,
  tailnet, firstRun, policy)` gives `Result(Verdict, Reading)`; `Verdict` is `Ready(Summary, Changes)`, `Wait(Says)`,
  `NeedsPassword(Need)`, `KeysOnly(Says)` or `Stop(Says)`. The app's own key refused reads the ways that the server
  named with its refusal (`RemoteResult.LoginWays`; piece L4c): a password way ("password", "keyboard-interactive")
  among them, or no list, asks for the password once (`NeedsPassword(PasswordNeed.Ssh)`), whose page also takes the
  owner's key; ways with no password way are `KeysOnly`, the stop of a server that takes keys only, at once and with no
  password try ("… Choose its key."). A password that a server refuses as not offered still says so. `Read`,
  `VerdictOf` and the words are the Mac's.
- **The words of a call that failed**: `ServerCheck.Failed(server, port, user, failure, login, firstRun, policy)`, with
  `Unreached(server, port, failure, policy)` for the four ways of not reaching a server (the Mac's
  `ServerCheck.unreached(_:said:)`, and `FleetReach.dropped` for a silent server on the private network; `policy` is
  where the Tailscale policy is kept, which the piece of Tailscale's API knows). **Two sentences are the PC's own, new
  words for set 8:** `ServerCheck.HostKeyChanged(server, firstRun)` ("If the server was rebuilt, start again." in the
  first run, "remove it and add it again." after it: the Mac's sentence names `ssh-keygen -R`) and
  `ServerCheck.KeyRefused(server)` (the Mac's says "Choose its key", and the PC has none to choose); and
  `ServerCheck.HostKeyUnknown(server, firstRun)` (a server with no key on record, under `Known`), the description of
  `NeedsPassword(Ssh)` ("That server does not take this PC's SSH key, and asks for a password.") and of `NoClaimCode`
  ("… for this PC. Try again.": the Mac's sends the owner to the server's log).
- **The claim**: `Claim.SendAsync(hubClient, box, claim, code)` sends only to `Claim.IsTarget` (HTTP, a number of
  100.64.0.0/10, the path `/claim`, nothing else) through L0's `OwnerPcKey.ClaimAsync`. The plan's contract said
  `Claim.SendAsync(http, claim, code, keySha256)`: the key's SHA-256 is made from the box there, so the box comes in
  its place. `Claim.ReadHubAsync(hubClient, box, hub)` is the wait's read of the hub (`HubRead`). `ClaimCode` reads the
  installer's line (`Found`, `Read`, `Grouped`, `IsPrivateAddress`).
- **The reads**: `NetworkSignIn.Found(lines)` and `Tags(line)`; `InstallPhases.Of(reported, planned, runningFor)` (the
  four steps, the minutes left, the status line, the parts of the bar); `InstallRetry.Decision(...)`, `StoppedBy`,
  `WaitAsync`, `FailedStep`, `KeepsCode`; `VerifyChecklist.Read(output)`, `Decode`, `HoldsList`, `Title`, `Summary`.
- **The records**: `InstallRecord` and `InstallLog` (the record of the install that runs: `Hide`, `Place`, `Note`,
  `Done`, `Stop`, `Retry`, `Cancel`; `InstallRecord.WordsOf(error, host)`), and `BuildRecord` (`Begin`, `Made`,
  `CallEnded(AtProvider)`, `Joined`, `End`, `IsUnjoined`, `NamesInUse(records, now, life)`). Which `AtProvider` a
  provider's error leaves is the providers' piece (L2), and so is the life of a join key in `NamesInUse`.
- **Not here**: the records' store and file form (the Mac's `KeptRecords`) and the password once (`PasswordOnce`) are
  piece L4's (the section after this one); the report of a stop (`InstallReport`) and the prompt to fix one
  (`InstallFixPrompt`) come with their pages.

### The first run and the agent setup: `Founderizer.Setup/FirstRun`, `Agents` and `Founderizer.Owner/Reads` (step 2, piece L4)

For the window's pieces U1 to U3. The Mac's `FirstRunModel`, `FirstRunWork`, `FleetNetworkModel`, `FleetCloudModel`,
`FleetVPSModel` and the flow of `FirstRunView.swift`; FleetCore's `FleetShape.swift`, `FleetBuild.swift`,
`AgentSetupFlow.swift`, `MachineSignin.swift`, `StartAgain.swift`, `PasswordOnce.swift` and `KeptRecords.swift`; and the
reads of `Servers.swift`, `Machines.swift` and `Team.swift`. Each sentence that FleetCore holds, and each rule that decides
from a reading, is held to `../vectors/setup-words.json`, and the password's program to `remote-password.json`, which
FleetCore's own code writes (`Tests/FleetCoreTests/SetupWordsVectorsTests.swift`). These names stay.

- **The store**: `new SetupStore(new SetupSettings { Owner, Box, Remote, HostKeys, Records, Tailscale, Cloud, Status })`
  with `Tailscale = new FleetNet(new TailscaleApi(ProviderHandler.Create(), box))`, `Cloud = p => CloudServers.For(p,
  ProviderHandler.Create(), box)`, `Status` the PC's `tailscale status --json`, `Records = new SetupRecords(appFolder)`,
  and `Choices` the kept answers (`ISetupChoices`: the name, the AI, the slider, the reports' answer; no secret). `State`
  is a `SetupState` (its `Page`, `Progress` for Back's line, `HoldsWindow`, the hub's and the manager's `CloudStep.View`,
  `Vps`, `Install`, `ManagerInstall`), and `Changed` comes after each change, on no thread in particular.
- **One method for each press**, in the Mac's order: `SetUp`, `ChooseReports`, `TypeName` and `ChooseName`, `ChooseAi`,
  `MoveSlider` and `ChooseServers`; `ReadPc(statusJson, installed)` from the window's poll, `PressConnect`,
  `NetworkStopped(words)`; `SendKeyAsync(token)` (also on the install's page of a stop for the network's key: a key that
  Tailscale ended makes `FleetKeyEnded`, and the key's page comes again before a server until a paste makes a new key); `ChooseProvider`, `ChooseOtherVps`, `SendTokenAsync`, `ChooseOffer`,
  `ChooseManagersOffer`, `ChooseExisting`, `HubAt`, `ManagersAt`, `SendManagersTokenAsync`, `ShowManagersMore`;
  `MakeFleet()` (the one press: false when a build runs already), `MakeManagersServerAgain()`; `CheckVpsAsync(address)`,
  `GivePasswordAsync(char[])` (the array is cleared, unless the server's sudo asks for it: then the install takes it and
  clears it), `VpsAgainAsync`, `InstallVps`; `ChooseKey(bytes, name)`, `GiveKeyPassphrase(char[])` and `ForgetKey()` (below);
  `InstallAgain()` (Try again of a stopped install, and Install again after a new key of the network); `OpenApp()` ("Open
  Founderizer" under checks that did not pass, piece U3: only once `State.HubAnswers`; the hand-over then comes as after
  checks that passed); `Back()` (nothing while `Runs`). The network page goes on by itself when
  `ReadPc` sees the PC on its tailnet; the key's page when the key is made. While an install waits on Tailscale's link
  (`InstallView.NetworkSignIn`: the join of the manager's own server, when the fleet's key cannot give the join line's
  tags) the build page gives way to the install's own page, with the Mac's two rows and Open link (piece U3).
- **The pages**: `SetupScreens.Of(state, store.Runs, store.ShowsBuild)` gives a `SetupScreen`: its name, title (which moves
  while `Waits`), its muted line, its controls (`SetupControl`: a card, a button, a link, a field, a paste field, a secret
  field, steps whose link is written `[words](address)`), its orange line, and whether it has Back. The words are its
  constants (`SetupScreens.WelcomeTitle`, …). The build page's line of each server is a `FleetBuildRow`.
- **The build**: `CloudStep` is the Mac's `FleetCloudModel` over `ICloud`: a token, the choice before anything is made,
  and the build of exactly the offer that the owner chose, with its `BuildRecord` written from the moment the provider is
  asked. The hub's server is kept under the hub's address to be (`StartAgain.HubAddress`), and the manager's own server
  under the same address, so that Start again finds both by its records.
- **The install, the claim and the join**: the hub's plan gets the manager's name in the installer's form
  (`ManagerName.AgentName`), "1 server", the slider's step and the chosen AI; up to three tries for a stop that passes
  (`InstallRetry`), never after a sudo password. At the claim the store calls `OwnerStore.ConnectOwnerAsync` with the
  hub that the installer claimed, and the manager's own server joins that hub with the hub's one-time line
  (`OwnerReads.JoinCodeAsync`). Each install keeps its `InstallRecord`. **The hand-over is one decision, asked at each
  change that can make it true** (a state of the store, a change of the owner's store, the end of the join's wait), and
  taken once: the hub's checks passed, the hub answers this PC, and the manager's own server neither builds, nor joins,
  nor waits for a choice that can lead on (the Mac's `onChange` of the install page). It gives `HandedOver`: the manager,
  the provider that the owner chose, the server that joined for it, whether the sign-in was asked, and the server that
  the run made and that did not join (the manager's setup installs it). The first run's answer on "Help improve
  Founderizer" goes to the hub (`POST /ui/error-reports`) once the hub offers `error_reports`. `SetupSettings.Calls` and
  `Fleet` are the new hub's owner calls and reading (the owner store's, unless a test gives its own).
- **Start again**: `StartAgainPlanAsync(hub)` gives the plan (the servers that this PC's records prove, the machines of
  the private network), `StartAgainRunAsync(plan)` runs its steps (`StartAgain.RunAsync`, the Mac's rules), and its last
  step forgets this hub's records (and no other's), calls `HostKeys.ForgetAll()`, and forgets the hub
  (`OwnerStore.ForgetOwnedHub(hub, hubServerDeleted)`: the store is as on a PC that was never given a hub, and the key of
  the owner's computer goes only when the run deleted the hub's own server). `ForgetServer(addresses)` calls `HostKeys.Forget(address,
  22)` for a server that the app deleted.
- **The records**: `KeptRecords<T>` (one file for each record under `records/builds` and `records/installs`, a time as
  whole milliseconds, a record of an earlier start that runs read as cut off), `BuildRecord` and `InstallRecord` (L3's).
- **The password once**: `PasswordOnce.RunAsync(remote, target, need, password, publicLine)`: the Mac's program in one
  call, the password as its login (`Ssh`) and on the first line of its input, then the proof that the app's key alone
  opens the server.
- **The owner's key once** (the owner's "Choose key, as Mac" and "One field, only then"; on L1a's `RemoteLogin.KeyOnce`
  and `OwnerKeyFile.Check`). **Where the key's card shows** (`VpsView.TakesKey`; the owner's "Key row here too" of 21
  November 2026, picture 14b, W15, piece L4c): on the stop of a server that takes keys only ("… Choose its key.", which
  the check reaches with no password try when the server names no password way), and on the password's page of an SSH
  password, under the password's field and its line, where the owner gives the password or the key. Not on the
  password's page of a `sudo` password, where the app's key got in. There the window gives `ChooseKey(bytes, name)` the
  one file that the owner picked (at most 64 KiB; the model takes the array and clears it); anywhere else the model
  clears the bytes and does nothing. A password given on that page takes the place of a chosen key, which goes.
  The check runs before any connection and off the caller's thread: a file that is no key says "This app cannot read that
  file as an SSH private key."; a key with a passphrase shows the one field (W14), and `GiveKeyPassphrase` with a wrong one
  says "That passphrase does not open this key." with no call; a key with none is its own press. Then one call with the
  key (`PasswordOnce.KeyAsync`, the password's program), the proof with the app's key alone, and every later call with the
  app's key. A sudo that asks for its password gets it asked once, and the same call goes again with it on its input's
  first line. A refused key says "<server> did not take that key for <user>." under the card, on the page that it was
  chosen on, its row empty again. The model's only copies of the bytes and
  the passphrase are cleared when the call ends, when another file is picked, when the step is left, and when the app's
  key is found to work, with the file's name; no record, setting, box or line ever holds them, nor the file's path.
- **The agent setup**: `AgentSetupFlow` (the Mac's rules: `Page`, `StartOf`, `Stopped`, `InstallBar`, `Blocker`, …),
  `ManagerSetupStart` and `ManagerSetupSteps`, `SignIn` (`Line`, `Page`, the provider's steps), and `AgentSetupModel(calls,
  agent, placing)` for one agent's setup (`placing`: the manager of a new fleet): `ReadAsync(fleet)`, `Page`,
  `PlaceChosenAsync` (its server and its provider in one move, read again once after a changed team), `ChooseAsync` (its
  own provider's sign-in, or its failed install again), `SendCodeAsync`, `OpensByItself`, and the machine's check and the
  activation (below). A link that the window opens is only ever `SignInPage.Link`, which is a link of the provider's own
  hosts.
- **The manager's first setup in the window** (piece U3, `Agents/ManagerSetup.cs`): `ManagerSetupMark` (what this PC
  keeps of it in the first run's kept answers, `ISetupChoices`: the hub's address, its generation, the manager, the chosen
  provider, the server that joined, and the server that the first run made and that did not join, by its name and its
  address on the private network (`FirstRunServer`, the Mac's `firstRunServerFor`); the first run writes it at each change after the claim and last at its hand-over,
  `ManagerPlacing.NoteAsync(state, now)` writes it at a current reading of a manager with no server, the manager's run
  and Start again take it away, and `ManagerSetupMark.Shown(state, choices)` is the mark that the window shows),
  `ManagerSetup(new ManagerSetupSettings { Calls, Fleet, Choices, Refresh }, mark)` with `View` (a `ManagerSetupView`),
  `Changed`, `RunAsync(cancel)` (a read every 2 s while something goes on, else every 5, and what runs by itself after
  each read, until `View.Ended` or the cancel; a read that throws is tried again at the next turn), the presses `ChooseAsync(provider)` and `SendCodeAsync(code)`, and `TakeOpening()` and
  `Opened()` for the provider's page; `ManagerSetupScreens.Of(view)` gives each page as a `ManagerSetupScreen` (with
  `SetupControlKind.Bar` for the job's steps and `Code` for Codex's code; `Drawn` false for a page of wave B or C, whose
  frame alone would show). `View.Shows` is the Mac's `fillsWindow` (`AgentSetupFlow.FillsWindow`), and
  `ManagerSetupScreens.TakesWindow(view)` is that with a page that this build draws: a page that is not drawn leaves the
  window to the manager's page with its pane. One gap stays until wave C: with "1 server", an app that ends in the
  seconds between the claim and the first reading keeps no mark, so the manager's sign-in has no page at the next start.
- **The setup of an agent that is not the manager of a new fleet** (piece L4b): `ManagerSetup.ForAgent(settings, hub, db,
  agent)`, with the same loop, presses and pages, for an agent that the hub shows in setup (a team card added it, and the
  hub's job installs it on its server) or signed out. **No window makes it yet**: the window of piece U5 (or wave C's
  agent page) will, for an agent whose reading says so (`AgentSetupFlow.Shows(SetupAgent.Of(row, null, null), features)` is
  true for one that is not active); today `StoreSource` makes the manager's setup alone. `View.TakesChat` says
  that its pages take the place of its chat; it never fills the window (`Shows` is false), it has no steps on Back's line,
  it keeps no mark and leaves the manager's mark as it is, and `View.Ended` comes when its chat takes the place of its
  setup. **Once its machine reports it signed in, the machine's check and then the activation go by themselves**, each once
  on a visit (the Mac's `follow`), under the moving "Setting up <Agent>"; what stopped them is `View.Activation`: the page
  "Activate <Agent>" with one orange line (the check's first item that did not pass, the check's own detail, or the hub's
  words) over Try again (`TryAgainAsync`; only while `ManagerSetupSettings.CanWrite`, the Mac's `store.canWrite`), and
  nothing goes again before it, but a new visit (`Visit`), as the Mac's view whose states start again. One point differs
  from the Mac: a check whose
  request got no answer is asked again at the next read, where the Mac's request line sends it again (the hub keeps one
  check that waits).
- **The server's page of a manager with no server** (piece L4b, drawn by U3b): `ManagerSetupSettings.Server`
  (`AgentServerSettings`: the box, the remote, the records, the tailnet, the providers, the PC's status) makes
  `ManagerSetup.Server`, an `AgentServerStep`, with `View.NewServer` (an `AgentServerView`). The pages are the Mac's, in
  its order: "<Manager>'s server" with the way "VPS" (`ChooseVps`; the PC has no Mac way), then "A VPS for your agents"
  with the providers' cards. Presses: `ChooseProvider`, `SendKeyAsync` (the fleet's Tailscale key, only when the box holds
  none or Tailscale ended it), `SendTokenAsync`, `ChooseOffer`, `MakeServerAsync` (it asks the hub first, and makes
  nothing while the hub does not answer, with the Mac's words, `HubWords`, nor on another generation of the hub, with no
  words: the window makes that generation's setup), `JoinAgain` (Try again), `Back` (nothing while `Runs`); a new visit
  (`Visit`) opens it on its first page, as the Mac's view. The build is `CloudStep` for this hub, so that Start again finds its server;
  **its server joins only while the owner's store is on this setup's hub and generation** (`ManagerSetupSettings.Hub` and
  the calls' `Database`; the Mac's `store.hub == fleet`), with the hub's one-time line, up to three tries as on the Mac,
  its bar held through a retry (`InstallView.Reported`, F4), and goes to the manager by itself as soon as the hub offers it
  (a count of reads, 40, three seconds apart). The server that joined is in the manager's mark from the join's end, so a
  start of the app before the hand-over still gives it, and a hand-over that did not give it keeps it there, unless the
  hub lists it with another agent: the setup's own rule checks it again at each read and at each start (the Mac's
  `handOver`). **The server that the first run made and that did not join is
  installed by itself, once**, with no second server: only the one in the manager's mark (`ManagerSetupMark.Made`), at
  its address on this PC's network, also when the hub lists it free (the hub takes a server at the join's POST, before
  the steps after it; `ServerList.TakesFirst`), and never one that the hub lists as its own or with another agent;
  `ManagerSetup` asks for it once for each opening of the page (`Visit`), as the Mac's `installFirst`, and the page joins
  it once by itself, with its tries, also when the first run's own join of it stopped. The mark notes that this join
  started (`FirstRunServer.Tried`), and lets the server go only when a join of it ended well. Once that join started, a
  stop of it, or a cut by a closed app, does not run again by itself: this PC's install records keep it, and each later
  opening shows that stop with its words (this run's, else the record's line, else the step where it stopped) and Try
  again, which joins it again. The mark keeps the server from the first run's claim on (`SetupStore.KeepClaimedMark`), so
  that an app that ends while the first run's join of it runs does not lose it. Here the PC departs from the Mac in two
  points, until wave C gives the PC the provider's row "Use this server": the Mac lets the server go as its join starts
  and keeps that row for it, and its `installFirst` returns when the hub lists the server (its provider's list offers it),
  where the PC joins it while it is free and no job runs there (`why` has no "busy", as the Mac's reuse reads it). The page
  joins nothing by itself while a join of that server runs on this PC (its newest join record reads Running): **for U3b,
  `AgentServerSettings.Records` must be the first run's own `SetupRecords`**, one instance in the app, since `KeptRecords`
  reads its folder once and a second instance does not see the first run's join. A server that this page made, or a
  build of an earlier run, is never joined again by itself. `View.Free` are the fleet's servers that the manager can take,
  and `TakeServerAsync(name)` gives one: **the hub's list is read again first, and a server that another agent took, that
  is the hub's own or that left the fleet is not given and not kept**. The pages are `AgentServerScreens` (through
  `ManagerSetupScreens.Of`, `Drawn` false until U3b draws them), with no card for a free server: the Mac has one in its
  provider's list alone, so it is the owner's to say. `Join(target, name, sudo)` is the join of a server that a check of
  the PC proved: **Other VPS is not here yet**, because its check, the password once and the key once are in `SetupStore`,
  for the hub's install alone.
- **The reads**: `OwnerReads.ServersAsync`, `MachinesAsync`, `TeamAsync` (the Mac's caps and checks), and the writes
  `JoinCodeAsync`, `MoveAsync`, `SignInAsync`, `SignInCodeAsync`, and of L4b `CheckAsync`, `ActivateAsync` and
  `AddAgentAsync` (a failed install again), through `OwnerReads.Of(store)`. The text of a
  `SignInPage`, a `JobPrompt`, a `MachineLogin` and a `JoinCode` names no link, no code and no command. A field that the Mac reads
  with `try?` is a `JsonElement` with a reader that never fails the list; fields that no page of the setup reads are
  skipped. `MobileAgent.Alive` is the sessions of an agent's helper, for the end of the manager's first setup.
- **Not here, and why**: an agent on a key or a model server (its seal is wave B); a change of an agent's provider
  (wave C's agent page); the account's own servers' re-install of the hub (`hubAgain`) and the three lines over the
  press of a list (wave C, with Add server); the second way of the welcome page; the Mac's `MadeServers` notes (each server
  that the PC makes has a build record with its hub). The sentences that the Mac holds only in its view files are copied
  in `SetupScreens` and held to the Mac's string catalog (`app/Localization/Localizable.xcstrings`) by a test; the area
  "Setup, servers and owner tools" has queued a FleetCore `FirstRunWords` that the writer will then read.

### The root jobs: `Founderizer.Setup/RootJobs` (step 2, piece L6)

For the window's piece U4 (`Fleet/RootRounds.cs`, which starts the rounds from the store's read) and the vault's
`VaultRound` (after piece L5). The steps that the owner's Mac runs by itself as root on the fleet's servers
(`OwnerAccessSweep.swift`, `ServerHardening.swift`, `ServerBrowser.swift`, `CentralVault.swift` `CentralVaultRemote`,
`OwnerMacKey.swift` the registration), with the same rules and the same programs: `../vectors/remote-root.json` and
`remote-vault.json` hold them, made by FleetCore's own code (`Tests/FleetCoreTests/RootVectorsTests.swift` and
`RemoteVaultVectorsTests.swift`), and `RootVectorTests` holds the C# equal to them, byte for byte. **Nothing of it is on a
page**: what a run said is a line for the log. **No program's text comes from the hub or from a server**: each is of this
build's own code (rule 12). Namespace `Founderizer.Setup.RootJobs`. These names stay. The folder names no type of L5.

- **The engine** (`RootJob.cs`): `JobTries` (the Mac's VaultTries: a failure waits ten minutes, six in a row and then it
  waits for good), `SweepMemory` and `SweepReading` / `SweepStep` / `SweepOutcome` (the Mac's `ServerHardening.Memory`,
  `Reading`, `Step`, `Outcome`), `RootJob.Step` (**the two-rounds rule**: a fault runs its program only when the round
  before read it too) and `RootJob.TurnAsync` (**a try is a kept run only when the program started**, which its own first
  line says; a try that reached no server, a host key that is not on record, a login that was refused, nothing that
  answered, is counted for this start of the app only). The Mac's memory of an older build's reasons (`ofRuns`) has no
  counterpart: a PC never kept one.
- **The call** (`RootCall`): `AnswerAsync(remote, target, program, limit)` gives the program's lines (both streams in their
  order, at most 1 MiB) and the way the call failed; `RunAsync` gives the text alone, with the failure as its last line.
  Every call has **`HostKeyRule.Known`** (the Mac's `StrictHostKeyChecking=yes`), the app's own key, and root through
  `sudo -n` for a user that is not root (`InstallPlan.Command`). A server with no host key on record gets no program, and the
  job counts a try that ran nothing. **How a PC learns the key of a server of a fleet that it took over is not decided** (see
  "Open").
- **The records** (`RootRecords`): one file, `records/root-jobs.json` in the app's folder, for what the jobs keep between two
  starts: the counts of the sweeps (`Sweep`, `KeepSweep`), the browser parts (`BrowserOf`, `KeepBrowser`) and the marks of
  the access line (`Marks`, `KeepMarks`), by `RootRecords.NameOf(hub, server)` (the hub's address, the server's name, its
  private address). No secret. A file that does not read is an empty record: each server then has at most six more tries;
  so is a member or a server's record that is null. Two objects of one folder (the round's and the access line's) share
  one lock, kept by the path with no regard to case, and each reads the file again after another wrote it, so none writes
  over the others' records. A record that the disk did not take stays in that object's memory only until the file is read
  again (another object wrote it, or it changed on disk): then it is lost, and that server may get one run more than its
  count.
- **The round** (`RootRound(records).RunAsync(fleet, servers, tailscaleStatus, run, now)`, every `RootRound.Every` =
  300 s): for each server that the hardening is for, the hardening's turn and then the browser parts', each server reached
  only with `servers.RootConnectionAsync` (`ServerRecords`, below). A cancel ends it before a server or between a
  server's two turns, and the next round is then a first round. `RootFleet(Hub, Time, Join, Servers,
  Agents, Tasks)` is what the store read: `Time` is the hub's clock (`ServerList.Time`), `Servers` the rows of `GET
  /ui/servers` as `RootServer.Of(entry, row)`, `Agents` and `Tasks` the whole state's (`BrowserAgent.Of`, `BrowserTask.Of`),
  null where there is none (the browser parts then wait). It gives the log's lines. The L15 sweeps (memory, restart,
  libraries) are each a turn more here.
- **The hardening** (`Hardening`), **the browser parts** (`Browser`, `BrowserParts`, `AgentUsers`, `BrowserWant`; the Mac's
  rules of 24 November 2026: a reading's row with a port outside 9300-9399 or 5910-5999, or a port or a user that an earlier
  row has, is no row (`Browser.Assign`); no table names such a port (`Browser.Table`); the worker user is the service's own,
  `fleet`, with a uid that is not 0, not the broker's and no agent's (`Browser.WorkerFits`); the step checks both again on
  the server (`ports-refused`, `worker-refused`); a reading's numbers are 64-bit, as the Mac's `Int`;
  `../vectors/server-browser-ports.json`, by the Mac's `ServerBrowserVectorsTests.swift`, holds them), **the
  owner's access line** (`AccessLine(records).RoundAsync(hub, servers, publicLine, connections, tailscaleStatus, run, now)`,
  every `AccessLine.Every` = 900 s; the key's public line comes from the caller, as plain text, and a text that is not one
  line "`ssh-ed25519 <base64> founderizer-owner-access`" with a base64 that reads (`AccessLine.IsAccessLine`) throws before
  any program is made or any server is reached: the Mac makes the line from the key. Each mark is the fingerprint of the
  line's own key (`AccessLine.Fingerprint`, the Mac's `OwnerAccessKey.fingerprint`), never one given beside it, which could
  be another key's), **the connection**
  (`ServerRecords(machines, own, keptOf).RootConnectionAsync(server, tailscaleStatus)`, the one way of a root job to a
  server: the connection that this PC keeps from an install (`keptOf`), else the fleet's own record of the server, **whose
  user other than root is none for a root job**, and **only at an address that this PC's own Tailscale names as that
  server** (`TailnetNodes`), the connection's address and never the row's; `MachineAccess` and `OwnServer` are plain rows of
  `GET /ui/machines` and `GET /ui/vault`; `ServerRecords.Target(…, rootOnly: false)` for the key registration alone).
- **The vault** (`VaultInstall.Program(ownerKey, keepOwner, releaseKeys)`, `.Installed(output)`, `.HubMachineStop` (the
  install and the update run only on the node that this PC's Tailscale names as both the connection's host and the hub's
  address, by node ID, never by a first label) and `.PinRefusal` (an update or the app's own install never moves a pin that
  this PC holds); `VaultPins.TrustAsync`, which signs a pin **only when this PC's own Tailscale names the connection's address
  as that server**, the key that was read there is the one that the hub reports, and the clocks agree, and reads a server as
  a Mac only when the hub's `kind` and the node's Tailscale `OS` both say so (`VaultPins.ReadOf`); else as root, never as a
  record's user that is not root). All take plain values: the owner key's public half as base64, the release keys as text
  (the window's `ReleaseChannel.ShippedKeys` and `EarlyKeys`), the Tailscale status as JSON, an `IOwnerKey`. `VaultRound`,
  which joins them with L5's `VaultPlan`, keeps the pins and the Mac server pin's guard (the Mac's `MacVaultPin`, VAULT.md
  limit 10) and sends the statement, is written after L5 is on `main`, with three rules of the Mac that it must keep: the
  Mac server pin's guard comes **before** `VaultPins.TrustAsync`, which signs inside; it makes an owner key only when the
  store says that none is there, and stops on a read that failed (the Mac's `OwnerKeychain.lookup`, 09edee16b); and the
  PC's maker of the owner access key (whose public line `AccessLine` takes) keeps the key on a read that failed, and makes
  one only where none is there (the Mac's `FleetKeychainItem.held` and `mayMake`, 5bc07c316).
- **For U4, which starts the rounds**: (1) a kept connection keeps its `PortGivenFor` (the Mac's kept record,
  `Machines.swift`, `portGivenFor`), else a hub at the owner's port 2222 is checked against the host's port 22 key and
  every root job stops as `HostKeyUnknown`, with no word on a page; (2) the root jobs' `SshRemote` takes the first run's
  `HostKeys` folder (`AppFolders.Setup`, as `Fleet/StoreSource.cs` does), so a key that an install kept is the one that a
  root job reads; (3) one new `ServerRecords` for each round, as the Mac, so the list of machines is read once a round and
  never kept from an earlier one.
- **The owner's computer key** (`OwnerKeyProof.RunAsync(hub, box, post, read)` and `OwnerKeyPlan`): the registration of a key
  with the one-time proof that the PC reads over SSH. `OwnerPcKey` and the store call it in the repair (next piece of this
  entry).

**Open, for the owner** (9.1 of `windows-app-plan-v2.md`, "it is a question for the owner before piece L6, and no builder
settles it"): how a PC learns a server's host key without a console when it has none on record (a new PC that takes over a
fleet, a server that joined some other way). The Mac's sentence says "Connect to it once with ssh from Terminal". Every job
runs under `Known`, so such a server gets no root program and no pin until the key is on record. The words that stand
meanwhile are the PC's own `ServerCheck.HostKeyUnknown` ("This PC has no host key on record for <server>. Remove the server
and add it again."), which no job shows on a page: only `VaultPins` gives it, as a reason of a Secrets page row (wave B's
window).

**Where L6 differs from the Mac**: no `ssh` and no Terminal; no `SSHKeyLedger` gate (the PC has one key); no `~/.ssh`; the
Mac's old marks of before 14 November 2026 are not read (a PC never wrote one); the public SSH check (`PublicSSHCheck`), the
system libraries, the memory limit and the restart settings are L15's. A PC reads `GET /ui/servers` rows' `reading.browser`
and `reading.agents`, and `GET /ui/machines`' `access`, which `Founderizer.Owner/Reads` skips today: U4 takes the raw rows
(`RootServer.Of(entry, row)`) or adds the members to those records after L4b is on `main`. The Mac's host key rule by port
(22 November 2026: a new key only at port 22 or at a port that the owner gave, else the key of the host's port 22) is in
the SSH layer (`HostKeys`, L1), for every call: a root job takes no new key at any port, because every one runs under
`Known`, and at a port of the hub's record it compares the server's key with the host's port 22 line.

### The first run in the window (step 2, piece U1)

How the window draws the library's first run, for the window pieces after it (U2, U3, U6 and on).

- **The switch**: only a build with `-p:FounderizerWelcome=true` on its command line has the welcome page
  (`Fleet/FirstRunSwitch.cs`, which `StoreSettings.Welcome` reads); an environment variable of that name turns it off,
  and `release/build-release.ps1` passes `-p:FounderizerWelcome=false` to every build. No build that a person gets has
  it before U3, U4 and U5 are in it (plan, section 13); without it a PC with no hub opens on Add this PC, as in step 1.
- **The first page**: a window with the welcome page and no hub draws no page while the search of this PC's Tailscale
  looks, then opens the welcome page (no Tailscale, or no hub on it) or Add this PC (a hub on it). While the welcome page
  shows and no press was made, a hub that appears opens Add this PC. The first run fills the window: no pane, no Back,
  Forward or Search in the title bar, one canvas (`MainWindow.Fill`).
- **The store**: `StoreSource.FirstRun()` makes the library's `SetupStore` once, over the daily store and its secret box
  (`%LOCALAPPDATA%\Founderizer\keys`, under Windows' protection of the user's data with a purpose of its own); its records,
  the servers' host keys and the owner's kept answers (`FileChoices`) are in `%LOCALAPPDATA%\Founderizer\setup`.
- **The frame** (`Pages/FirstRun/FirstRunHost.cs`): Back, the steps on Back's line, the page's step in the middle; Esc is
  Back and Enter the page's way on (`IStepView.Enter`). It reads this PC's Tailscale once when it opens and every two
  seconds on the network's page, and gives it to `SetupStore.ReadPc`.
- **A page joins the first run through the registry**: a family's own file `Navigation/Routes.<Family>.cs` holds one
  field, `internal static readonly Family X = Add(new Family { Can = [...], Steps = { [SetupPage.Key] = host => new
  KeyPage(host) } });`, and edits no other file. `Can` is the hub's names of what the family can do, which
  `StoreSettings.Can` sends the hub; `Steps` are the first run's pages that it draws. A page that no family draws shows
  its frame alone. The parts of a step are in `Pages/FirstRun/StepParts.cs` (`StepColumn`, `StepControls`, `StepField`,
  `StepMarks`, `Frames`), and the window's own words of the first run in `SetupViewWords.cs`, held to the Mac's catalog.
- **Tailscale on this PC** (`Fleet/TailscaleSetup.cs`): Connect downloads Tailscale's MSI for this kind of PC from
  `pkgs.tailscale.com` (no redirect, 200 only), holds the file open while `Publisher.SignedBy` checks it (the revocation
  of the whole chain, the signer Tailscale Inc. of CA) and while `msiexec.exe /i <file> /passive /norestart` runs, and
  removes it after; a file that fails the check is removed and nothing runs. Then Tailscale's own sign-in:
  `tailscale up` with no setting of its own, whose link opens in the default browser only when it is
  `https://login.tailscale.com/…`. `tailscale.exe` runs only after the same publisher check (`WindowsTailscale`).
- **On the owner's computer**: Settings shows no Forget the key, and the line over a page says one sentence of the PC
  for each refusal of the owner's key (`Fleet/OwnerKeyLine.cs`), until piece L6 repairs them by itself.
- **The key, the VPS and the build pages (piece U2, `Navigation/Routes.Fleet.cs`)**: `KeyPage` (Your Tailscale key,
  with the Mac's `PolicyLines` for a policy file that the PC may not write), `CloudPage` (A VPS for your fleet),
  `TokenPage` (a provider's token, "Your fleet" with a combo box under each server, the account's list, the token of
  the manager's own provider, and the build while the hub's server is made), `VpsPage` (Other VPS: the address, the
  check, the password once, the key's card "SSH key · Choose key" where `VpsView.TakesKey` says, and the passphrase's
  field only for a key with a passphrase), and `InstallPage` (the build page, the stop with each step and Try again, a
  stop for the network's key, checks that did not pass; Report a problem comes with its form, piece U11). The parts are in `SetupParts.cs`
  (`PasteField`, `SecretField`, `FleetSelect`, `ServerBoxes`, `BuildLine`); the build page's lines and the motion of its
  title are `BuildRows`, the Mac's view logic, which `Founderizer.Windows.Tests` reads.
- **The owner's key once (`Fleet/KeyFile.cs`)**: Windows' own picker (`IFileOpenDialog`, on a thread of its own, with
  hidden files shown and no entry in Windows' recent files) opens in `%USERPROFILE%\.ssh` when that folder is there; the
  window reads the one file once, at most 64 KiB, and gives its bytes and its name to `SetupStore.ChooseKey`. It keeps no
  path and no copy. Windows keeps one trace of a pick: the picker's list of last folders (`ComDlg32\LastVisitedPidlMRU`)
  has the app's name with the folder of the last pick, not the file. A typed password or passphrase goes to the model as
  characters, and its field is empty again, also when the page shows a state without the field (WinUI keeps the typed
  words as a string, which .NET cannot clear, until the garbage collector takes it). The step fields have Windows' spell
  check and text prediction off: with them on, Windows changed a word typed into the address field.
- **A proofs' build** (`-p:FounderizerProofs=true`) with `FOUNDERIZER_PROVIDERS=http://10.0.2.2:<port>` sends every
  request to a provider's own API to `vm/provider_standin.py` on the Mac (`Fleet/ProviderStandIn.cs`); a build without
  the switch has no such class.
- **The manager's setup (piece U3, `Pages/Agents/Setup/ManagerSetupPage.cs`)**: once the first run hands over, the
  window goes to the manager's page (`MainWindow.HandedOver`), where the setup stands in place of its chat and fills the
  window while `StoreSource.ManagerSetup()` gives one that takes the window (the mark of this hub and generation, the
  manager in the reading, a page that this build draws), also after a new start of the app; when the manager runs, its
  chat takes the page. The window's line (`Screens.Line`) stands over the setup as over every page: with the hub not
  reached, the moving title is not alone. The page
  draws pictures 18 to 20 and the Mac's other pages of that setup (the provider's cards, "Setting up <Manager>"): the
  manager's four steps on Back's line, no Back, the provider's logo at 48 or the manager's mark (96 while it waits for
  the session), the job's steps as a bar (`StepsBar`), Claude Code's field (`PasteField`, a code of `MachineLogin.CodeOf`'s
  shape) and Codex's code with Copy (`CodeBox`). The first step's link opens the model's link only (`SetupParts.Steps`
  with `open`), and puts Codex's code on the clipboard. Each Copy of the app writes the clipboard through
  `Pages/ClipboardText.cs` (`Fleet/ClipboardGuard.cs`): a write that Windows refuses, as while another program holds the
  clipboard, copies nothing, says no Copied, and does not end the app. The install's page has "Open Founderizer" under checks that did
  not pass, and Tailscale's link of a join with Open link; the checks' footer, which sends the owner to the server's own
  page, waits for that page (piece U7).
- **A proofs' build** with `FOUNDERIZER_SETUP_READINGS=<folder>` gives the manager's setup the readings of that folder in
  place of the hub's owner routes, and with `FOUNDERIZER_SETUP_SAMPLE=checks|approve` the first run's page shows that state
  of the hub's install (`Fleet/SetupStandIn.cs`; `vm/README.md`, "The manager's setup against a stand-in").

## Build and test

You need the .NET 10 SDK (`dotnet --version` says 10.0.x; `global.json` takes any 10.0 SDK). These runs are not a
release: a release builds with one exact SDK and restores in locked mode (`release/README.md`, "The SDK and the lock
files").

```bash
dotnet test app/windows/Founderizer.Core.Tests/Founderizer.Core.Tests.csproj
```

The first run's library (step 2), which reaches no network and no provider: every request goes to a stand-in.

```bash
dotnet test app/windows/Founderizer.Setup.Tests/Founderizer.Setup.Tests.csproj
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

The tests of `Founderizer.Remote` start a scratch `sshd` (`/usr/sbin/sshd`, as this user, on a loopback port) and,
for the password and `sudo -S`, an `sshd` in a Docker container (image `founderizer-remote-test-sshd:3`, made at the
first run; it also holds `puttygen` and OpenSSL's `ssh-keygen`, which make the owner's keys of
`OtherToolsKeyTests`); each test removes its server and its container. Without Docker, those tests are inconclusive.
A passphrase of a test reaches `ssh-keygen` and `puttygen` on their standard input only.

```bash
dotnet test app/windows/Founderizer.Remote.Tests/Founderizer.Remote.Tests.csproj --filter "TestCategory!=Long"
```

The run of 30 minutes (a line every 20 s on one connection, across the server's key exchanges), alone:

```bash
FOUNDERIZER_REMOTE_LONG=1 dotnet test app/windows/Founderizer.Remote.Tests/Founderizer.Remote.Tests.csproj --filter "TestCategory=Long"
```

The tests of `Founderizer.Setup` (the install and the claim over a stand-in server, and the two install vector
files), with no server and no network:

```bash
dotnet test app/windows/Founderizer.Setup.Tests/Founderizer.Setup.Tests.csproj
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
- **SSH.NET** in `Founderizer.Remote` only (`[2026.0.1]`, on nuget.org since 14 November 2026, 18:56 UTC; MIT), with
  its logging package Microsoft.Extensions.Logging.Abstractions (`[8.0.3]`; no logger is ever given to it, so it logs
  nothing) and BouncyCastle at the library's version. From 2026.0.0 it fixes two faults that this app can meet. A
  message of the call no longer goes out after the PC's part of a key exchange that the server started (a strict server,
  such as ProFTPD's, ended the connection; OpenSSH takes the message). An RSA signature of a host whose leading zero
  bytes were removed is checked as a whole one: Windows' own RSA refuses the short form (measured in the build VM, .NET
  SDK 10.0.404; macOS's takes it), so 2026.0.0 on a PC failed about 1 in 256 key exchanges with a server that sends
  that form (OpenSSH sends the whole form). Its two security fixes are in `SftpClient` and `ScpClient`, which the app
  does not use. No test covers the two fixes: OpenSSH, which the tests run, shows neither fault. Four more of its
  changes are on the app's path: the socket's buffer sizes (SSH.NET's pull request 1821), the socket's waits (1850),
  the read of a program's output (1849) and the read of a field's bytes in each message (1848); the tests of
  `Founderizer.Remote`, the 30-minute run included, pass with them.
- The tests take MSTest 4.5.1 and Microsoft.NET.Test.Sdk 18.11.0, with their own lock file.
- The lock files are the same on each .NET 10 SDK: the SDK's own package Microsoft.NET.ILLink.Tasks is at the release
  SDK's version on every SDK (`FounderizerReleaseRuntime` in `Directory.Build.props`), so a restore on this Mac changes
  none, and a lock file that it writes for a new package is the release's too (`release/README.md`).
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
- **The space before AM and PM is Windows' own**: the times are written from the PC's culture data, which .NET reads
  from Windows' own ICU (`C:\Windows\System32\icu.dll`; no `UseNls`, no invariant mode). Windows' icu.dll, ICU 72.1 (CLDR
  42), on build 26100 (Windows Server 2025 and Windows 11 24H2) writes en-US's short time `h:mm a` with U+0020, as
  Windows' own clock does; the Mac's ICU writes it with U+202F, which `swift-words.json` holds. Both read as a space.
  Measured on Azure lane 2, 25 November 2026: .NET 10.0.15 in ICU mode, NLS mode and the user's own regional settings
  all give U+0020 there; .NET's conversion of an ICU pattern keeps the space that it gets (U+202F stays U+202F), and the
  same icu.dll gives es-US U+202F, so the difference is in Windows' data. The app takes no ICU of its own and changes no
  space. `SwiftVectorTests.TheRowTimeAndTheAgeAreFleetCoresInTwoLocales` asks the machine's data for en-US's short time
  and takes exactly the separator before its AM/PM marker, U+0020 or U+202F only; every other difference fails, and its
  message names the data that it found.
- **Stricter than Swift**: a shape is anchored at both ends of the text, so a final newline never passes; a manifest's
  `hold` must be JSON true or false (Swift also takes 0 and 1), and its `build` and `size` JSON whole numbers (Swift
  also reads true as 1).
- **Keys** are software keys behind `IOwnerKey`. The key in the TPM is a later slice (1.5), on Windows.
- **The install (piece L3)** differs from the Mac's where the PC has no `ssh` and no console. A step that IRemote did
  not run stops with the way it failed, where the Mac reads `ssh`'s words; a connection that broke while a program ran
  is `server_unreached` (the Mac's own words do not say it, and its retry of the code and the plan steps is for a
  server that SSH lost), a program that a signal ended fails its step with its last line (with no line, the connection
  broke), and a call past its limit is the Mac's `timedOut`. The link code that a new hub's installer
  prints is in no line of a step once it is read (the Mac shows the installer's line, and its report then cleans it).
  `ClaimCode.IsPrivateAddress` reads exactly four numbers of one byte each (Swift's drops a part that is no number).
  The check of a server tries the app's own key alone, and its refusal asks for the password once: the PC has no key
  files of the owner's, so neither the Mac's key files nor its count of tries (`KeyTries`) are here.

## Before the first release

- The .NET runtime of a build that ships must be 10.0.14 or later: GitHub's advisory GHSA-p3jp-9v83-76w9
  (CVE-2026-111497, a Brotli decoder out-of-bounds write, 3 November 2026) covers every .NET 10 runtime before it.
  The client never decodes Brotli from the network, but the runtime of the app carries the decoder.
- The decode twin becomes a part of the app decode check of `COORDINATION.md` after the first Windows release.
