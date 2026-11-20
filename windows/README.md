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
  the answer with the box's files, sent at once by `AnswerAsync`'s path, or as `Press` waits); `TickAsync(need, options)`; `ControlAsync(task, action)`; `GuideAsync(task, text)`; `RetryAsync()`; `DiscardRefused()`;
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
    the empty chat's mark: "No messages with <role> yet") and `ChatModel.LoadingWords` ("Reading…", a chat's first
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
    A request raised before the chat's oldest item stands only while the PC holds the chat's whole history
    (`ChatPageState.Whole`: its first read gave fewer than `StoreState.ChatFirstPage` items);
  - the inline marks of a reply as runs: `InlineMarks.Runs(text)` gives each `InlineRun` (`Text`, `Bold`, `Italic`,
    `Struck`, `Code`, `Link`), read as FleetCore's `MessageBlock.inline` reads them (the Mac's MessageText draws those
    runs); their words joined are always `InlineMarks.Plain(text)`. `Link` is only an http, https or mailto address
    (`InlineMarks.OpensInBrowser`); any other link is its words with no link. A bare address is a link too, as
    Apple's reader on the Mac makes one (the autolinks of GitHub's Markdown, measured on 15 November 2026): an http,
    https or ftp address, a `www.` address (to http) and an email address (to mailto), without a final `.`, `,`,
    `_` or other mark that ends a sentence, with its balanced parentheses, and never in inline code or in a link's
    words. The cases are in `swift-words.json` (`inline`).
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
  - `ChatRow.AgeWords` ("5 min ago", or the state of his message on its way), and its hover `AgeHover` (the exact date
    and time of a reply, or the present `TimeHover` of his message). While `AgeMoves` is true, read the words again
    when the footer shows, with `Screens.MessageAge(row.Time, now, context)`.
  - The room over the composer is the window's own measure: the Mac's `ManagerView.endRoom`, 88 points under the last
    row, which "Latest" leaves out of its measure.
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
