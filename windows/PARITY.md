# Founderizer for Windows: parity with the hub's owner API

One line for each feature name that the hub serves in `ui_features` (`hub.py` `UI_FEATURES`, and the four names that
`ui_features()` adds while a switch is on). `python3 app/windows/parity.py` prints each name that has no line here, and
each line whose name the hub no longer serves. It is a report, not a gate (windows-app-plan.md, section 7).

The states:

- **built**: the logic library (`Founderizer.Core`) reads or writes it, its store and screen models use it, and a test
  proves it. The screens (`Founderizer.Windows`) draw it from slice 1.2 on, with the elements of the seven pictures.
- **waits**: a later slice of the plan, named in the line. Step 1 is the iPhone's level (slices 1.2 to 1.7); step 2
  is an owner with only Windows (slices 2.1 to 2.5).
- **not planned**: the plan leaves it out, with the reason in the line.

Step 1 is a PC of an owner who has a Mac, at the device level of `hub.py` `DEVICE_PATHS`: the setup pages stay on the
Mac, and a device route is all that the PC reaches.

| Feature | Windows | Note |
| --- | --- | --- |
| `direct_chat` | built | `MobileSnapshot.CanChat`, `Screens.UnavailableWords`; a message to an agent with `recipient` |
| `corrections` | waits | the request's `replaces_request_id` is built; no picture of step 1 shows Correct, so the store has no correction yet |
| `thread_events` | built | `GET /ui/tasks/<id>/events` every 3 seconds for the open task (`HubClient.TaskEventsAsync`), the Mac's whole thread (`TaskThread.cs`, `Screens.Task` `Thread`); the iPhone does not read it |
| `task_controls` | built | `OwnerCommand.Control`, `POST /ui/tasks/<id>/control`, with its receipt; also the Pause at the end of an answered card's line while the mark is its task's work (`RequestCard.Pause`) |
| `limit_holds` | built | the agents' `limit`: "Usage limit" in a chat's waiting line, a task's page and the panel |
| `liveness` | built | `MobileAgent.HelperIsRecent` |
| `live_desktop` | waits (step 2) | a task's screen; not at the iPhone's level |
| `machines` | waits (2.1) | a setup page of the Mac |
| `goals` | waits (step 2) | `/ui/goals` is no device route; a task's goal text is built |
| `kpis` | waits (step 2) | the Mac's agent page only in version 1 (`lanes/agent-kpis.md`) |
| `profiles` | waits (2.2) | a setup page of the Mac |
| `goal_tokens` | waits (step 2) | |
| `task_steering` | built | `OwnerCommand.Steer`, `POST /ui/tasks/<id>/steer`, with its receipt |
| `health` | waits (2.5) | |
| `reporting_lines` | waits (2.2) | |
| `leads` | waits (2.2) | |
| `browser_desktop` | waits (step 2) | |
| `machine_check` | waits (2.1) | |
| `file_changes` | built | the latest completed report of each path from the task's record (`ActivityTimeline.ChangedFiles`, `ChangedFilesModel`); the panel's "Changed files" (`Pages/TasksPages.cs` `ChangedFiles`, fourth set, 2a) |
| `subagents` | built | the child agents of the record (`ActivityTimeline.ChildAgents`, `ChildAgentsModel`, `Screens.ChildThread`); a step's child rows and "Open agent thread" (`Pages/TaskRows.cs`), the panel's "Child agents" (`Pages/TasksPages.cs` `ChildAgentsView`) and the child agent's thread with "Back" (`ChildHeadRowView`) |
| `vault_isolation` | not planned | the Mac app's row "Vault token" stood only in the old details of a server, which no hub since October 2026 showed; it went with them on 19 November 2026 |
| `triggers` | waits (2.4) | wake-up rules. For that phase: a rule's check can have the form `read` (UI-API.md 1.191), and a last run in the state `joined` is no trouble (`TriggerRun.goodStates`) |
| `trigger_checks` | waits (2.4) | |
| `agent_setup` | waits (2.2) | `active` of an agent is read (built); the setup of the manager of a new fleet, from its install to its first session, is built (piece U3: `ManagerSetup`, `Pages/Agents/Setup/`); the server's page of a manager whose server did not join, and the check and the activation of another agent, wait (L4b, U5) |
| `wakeups` | waits (2.4) | |
| `screen_model` | waits (2.2) | |
| `agent_auth` | waits (2.2) | |
| `vault_access` | waits (2.3) | |
| `runtime_switch` | waits (2.2) | |
| `account_email` | waits (2.2) | |
| `secrets` | waits (2.3) | |
| `login_create` | waits (2.3) | |
| `login_capture` | waits (2.3) | |
| `api_request` | waits (2.3) | |
| `owner_knowledge` | built | `GET /ui/knowledge`, one file with its text |
| `secret_grants` | waits (2.3) | |
| `integrations` | waits (2.4) | |
| `chat_apps` | waits (2.4) | |
| `people` | waits (2.4) | |
| `conversations` | waits (2.4) | an item's `conversation` is read (built) |
| `agent_messages` | waits (2.4) | |
| `google` | waits (2.4) | |
| `mcp` | waits (2.4) | |
| `mcp_check` | waits (2.4) | |
| `mcp_program` | waits (2.4) | |
| `mcp_packages` | waits (2.4) | |
| `mcp_find` | waits (2.4) | |
| `servers` | waits (2.1) | |
| `responsibilities` | waits (step 2) | duties |
| `server_prepare` | waits (2.1) | |
| `mobile` | built | `GET /ui/mobile` with its ETag, the chat and task pages, enrollment with the PC's `kind` (owner API 1.149), the devices list with each device's `kind`; the key kept between starts (`FileKeyStore` through the screens' `IKeyProtection`) and Forget the key |
| `mobile_ended` | built | `GET /ui/mobile/ended` (owner API 1.166): every ended task with its schedule, read when `ended_mark` of `GET /ui/mobile` moves (`HubClient.EndedAsync`, `StoreState.Ended`); the Ended lane counts and opens all ended tasks of its period with FleetCore's schedule groups (`EndedLaneTests` against `swift-words.json`) |
| `ended_blocks` | built | `GET /ui/mobile/ended` with `window=1`, `blocks=1` and `block=<from>` (owner API 1.270): the heads of the newest ids, and the older ones in blocks of 100 ids with marks, each block read once and again only when its mark moves (`HubClient.EndedWindowAsync`, `EndedBlocksAsync`, `EndedBlockAsync`); the store keeps the blocks in its folder `ended` and joins them (`EndedBlocks`), so `StoreState.Ended` holds every ended head, as the whole read did (`EndedLaneTests`, the twin's `mobile_ended`) |
| `secrets_import` | waits (step 2) | an import of secrets in one command, a setup page of the Mac; no device route |
| `attachments` | built | `OwnerStore.AddFileAsync` keeps a picked file's bytes in the store's folder, then sends it up with its own number before its message (the iPhone's StagedFile: it stays between starts, `UploadAsync` sends one that did not go again, `RemoveFile` takes it out); `FileAsync` reads one back with its size and SHA-256 checked (the device routes since `afb3188de`); the twin's `files` test |
| `resource_grants` | waits (2.3) | |
| `machine_signin` | waits (2.2) | the manager's first sign-in is built (piece U3: its start from a provider's card, Claude Code's code, Codex's code, the provider's page by itself after a press); the sign-in of an agent that ran before (the Mac's `SignInWizard`, `MachineSignInSection`) waits (wave C) |
| `releases` | waits (2.5) | the fleet's updates page; the line format of a fleet release is built (`FleetRelease`) |
| `entitlement` | not planned | Founderizer has no subscription since 10 November 2026 |
| `agent_signin` | waits (2.2) | |
| `github_app` | waits (2.4) | |
| `need_options` | built | `OwnerNeed.Choices`, `OptionsModel` (presses, ticks, the quick replies), `OwnerStore.Press`, `TickAsync` and `Reply` (a quick reply sends at once) |
| `restore` | waits (2.1) | |
| `manager_start` | waits (2.5) | |
| `agent_notes` | waits (2.2) | |
| `edit_in_place` | built | `SendReceipt.Edited` and `MessageRequestId` |
| `machine_access` | not planned | the Mac app's row "Not on record" stood only in the old details of a server and went with them on 19 November 2026; no view of the apps writes the record |
| `push` | not planned | decision D4: a ping goes through founderizer.com to Apple; the PC notifies while it is open |
| `attachment_knowledge` | waits (step 2) | |
| `asking_and_waiting` | built | `TaskWords` and the task page's "Waiting on" or "Waiting for" (`Screens.Task`) |
| `account_limits` | waits (2.2) | |
| `secret_requests` | waits (2.3) | an item's `secret` is read (built); its answer is the secure form of 2.3 |
| `signed_grants` | waits (2.3) | the statement writer is built (`OwnerStatement.Grant`) |
| `agent_rename` | waits (2.2) | |
| `agent_memory` | waits (2.2) | |
| `live_changes` | built | `GET /ui/wait`, `LiveToken`, `WakeCap`, `WakeBackoff`, `LiveWatch` |
| `settings` | waits (step 2) | `/ui/settings` is no device route |
| `standing` | waits (step 2) | |
| `history` | waits (step 2) | |
| `costs` | waits (step 2) | |
| `server_names` | waits (2.1) | |
| `mac_setup` | not planned | the sitting at a new Mac runs on that Mac |
| `agent_move` | waits (2.2) | |
| `server_access` | waits (2.1) | |
| `servers_for_apps` | waits (2.1) | |
| `sealed_push` | not planned | decision D4 |
| `device_by_code` | built | `HubClient.EnrollAsync` with a code and the kind `windows`: the hub adds the PC as "PC" (`pc`, then "PC 2"), and its messages say `via=Windows` (owner API 1.149) |
| `door_calls` | waits (D5) | the PC's yes needs the QR's `bind` value; the statement writer and the binding are built |
| `door_modes` | waits (D5) | the owner's signed mode of a server |
| `door_mode_set` | waits (step 2) | |
| `recovery_copy` | waits (D5) | needs the QR's `bind` value |
| `server_ai_choice` | waits (2.1) | |
| `manager_server` | waits (2.1) | the first run's server that joined goes to the manager with the chosen provider by itself, and the setup fills the window until the manager runs (piece U3); Add server's pages for a manager with no server wait (L4b, U5) |
| `knowledge_edit` | waits (step 2) | a write of the owner's knowledge stays on the Mac |
| `door_setup` | waits (2.4) | |
| `agent_remove` | waits (2.2) | |
| `repo_picker` | waits (2.3) | |
| `need_talk` | built | the short card, Details and options that combine (`RequestCard`, `RequestStep`, `OptionsModel`), and an old outbox's question of Discuss (which left in owner API 1.158; its record's kind `need_talk`) is dropped; the talk under a card, whose route is back since owner API 1.272, is the line `need_clarify` |
| `need_clarify` | built | Needs clarification on every card (owner API 1.272, hub release 2026.11.718; the owner's "Yes, as shown" of 21 November 2026 to `w4-windows-chat.png` and `w4-windows-needs.png`, and his "Keep Your answer too" of 20 November for the Mac and the iPhone): an item's `clarify` and `talk` (`OwnerNeed.Clarifies`, `ShownTalk`, `NeedMessage`); his message under a card is a command on its own route (`OwnerCommand.Talk`, `POST /ui/needs/<id>/talk`, also from a device; its outbox kind `need_clarify`), saved and sent once, whose command's receipt names the item and carries its talk (`ControlReceipt.Need`, `Talk`; `PendingRequest.IsConfirmedBy`). The field's words are the store's, in memory only (`StoreState.ClarifyDrafts`, `OwnerStore.OpenClarify`, `SetClarifyDraft`, `TalkAsync`): they leave the field once the outbox has the message, and the link comes back; a refused message's Discard gives them back to the card's field, never to a chat's draft; a 422 takes them off the PC with the drafts. The card shows the message from the receipt until a reading has it (`StoreState.TalkTaken`, `TalkOf`); a press on the card's options behind its own unsent request is dropped (`StoreState.WaitsUnsent`); a lost receipt is confirmed by the next read whose talk has more of his lines with those words than at the send (`OwnerStore.ReplayTakenTalk`), never by an older line and never without this PC's key. The request line names it "Ask about" and the item's title, Settings "Message to" and its agent. The window (`AnswerParts.ShowClarify`, `Screens.RequestCard.Talk` and `Clarify`, `RequestStep.Talk` and `Clarify`): the talk over the options, his lines in his chat's bubble at the trailing side and the agent's after its mark, and on the request at hand over his answer once it ended; the link in muted words at the leading side under "Your answer" in a chat's card (12 on 16) and in the middle at hand (15 on 21), and in its place the answer's box with no plus, "Message to" and the agent, Send with Enter. A folded card in a chat shows no talk (the Windows card does not open after the answer). The view's field (`ClarifyField`) loads the store's words only when it comes to stand, for another card, or when the store gave words of its own (`ClarifyModel.Given`, the Discard), passes on only his own changes of a field that stands (so the words stay through the fold of an answer that the hub then refuses), and takes the cursor once, for the card whose field the store opened (`NeedClarifyTests`). **Not built**: words that look like a key are not held back before they go, in this field as in every field of this app (the hub refuses only registered login text, 422), where UI-API 1.249 says of the Mac's app and a PC's that "those apps hold text that looks like a key before it goes"; that is a piece of its own for every field |
| `need_marks` | built | an item's `team_state`, `team_reason`, `task` and `give` (owner API 1.280; `OwnerNeed`), the mark in the place of an answered card's check in a chat and of the answered request at hand in Needs you (`AnswerMark.Of`, the Mac's `OwnerNeed.answeredMark`; `Screens.AnsweredMark`, `RequestCard.AnswerMark`, `RequestStep.AnswerMark`; `Pages/Requests.cs` `AnswerMarkView`): the check with the Mac's words (the raising agent's role and "has your answer", "Changed", "Given", "Done", or the task's state word), the turning green mark of work ("The hub makes the change", or the task's role and title), the red mark of a result that is no success, the orange mark where the task's row needs him (the owner's "Orange mark" of 21 November 2026; `AnswerSymbol.Attention` with the row's `TaskSymbol` in `AnswerMark.Row` and the row's words, as "Outcome not known: check it"; the search card's icon for that symbol, `SearchCard.IconOf`, in its orange), the gray pause mark where his own pause that the hub confirmed holds the task (the owner's "Gray pause, as the row" of 21 November 2026; `AnswerSymbol.Paused` for a hold of kind "pause" in the hub's state "stopped", with the row's `TaskSymbol.Paused` in `AnswerMark.Row` and the row's words, "Paused"; the search card's pause icon in its muted gray, at the check's 12 pixels), in the Mac's order (`FleetTask.tint`, then `OwnerNeed.answeredMark`: an outcome that is not known and the owner's hold before a result and before work, so a failed task that his pause holds is the gray pause; then work; then his pause); the words on hover (the system's tooltip) and as the automation name; for a task's work the hover is the Mac's tag (the owner's "Yes, badge as drawn" of 21 November 2026; `AnswerMark.Badge`, `AgentBadge.Of`, `AnswerMarkView.WorkTag`): the agent's badge (its mark at rest and its role, on the link's colour) then " · " and the task's title, wrapping at 360, as the system's tooltip under the mark, its words at the answer line's left edge and above the mark only where the window's bottom ends (`PlaceTag`, the Mac's HoverTag), which takes no focus and no click; the view opens it after the Mac's rest of the pointer, 350 ms (`OpenTag`), because WinUI puts a tooltip that its service opens for the pointer at the pointer, whatever its placement rectangle says, and it goes when the pointer leaves, when the mark moves, and at a click, a key or a scroll in the window (`Watch`), and stays away until the pointer leaves; the plain check for words, a saved key and an answer on its way; the turning mark, the orange mark and the gray mark of his pause open their own card's task (`RequestCard.OpensTask`; see "An answer waits 5 seconds with Undo" below) |
| `person_scope` | waits (2.4) | |
| `history_messages` | waits (step 2) | |
| `secret_compare` | waits (2.3) | |
| `default_models` | waits (2.2) | |
| `web_hosts` | waits (2.2) | |
| `hub_shared` | waits (2.1) | the hub's own server that takes agents (owner API 1.168): the hub install's word `FLEET_HUB_SERVER=shared` and `hub_shared` of `GET /ui/servers`, which is no device route; no app turns it on yet |
| `chat_waits` | built | `MobileAgent.WaitsSince` |
| `chat_waits_answers` | built | `ChatWaiting.WaitsOnAnswers`: the manager's chat line and its row wait on his answer to a request too (`Screens.WaitingLine`, `StoreState.Thinks`), only from a hub that names it |
| `diagnostics` | waits | `GET /ui/diagnostics`, the hub's own faults and refused calls (UI-API.md 1.167), for the Mac's Report a problem; the Windows app has no Report a problem yet (lane "Bug reports") |
| `error_reports` | waits | `GET` and `POST /ui/error-reports`, the owner's switch of Settings › Help › Help improve Founderizer (UI-API.md 1.204; a group of General until 16 November 2026), and the Mac's own crashes; the Windows app has no such switch yet (lane "Error reports") |
| `owner_key` | waits (2.1) | the owner's computer sends its own key with its address (owner API 1.169); a PC at the device level calls with its device key, which the hub's device rule takes as before, so step 1 needs nothing; the key file, the claim's header and `POST /ui/owner/key` are the first run of an owner with only Windows |
| `owner_computer` | waits (2.1) | the owner's computer says that it is a Mac or a PC and what its app can do (owner API 1.273): `POST /ui/owner/computer` `{kind: "windows", can}` after the claim, after a new key, at each start and when `db` changes, with the names of the build's families; `owner_computer` of `GET /ui/state` and `GET /ui/mobile`. A PC at the device level is refused there (`device_not_allowed`) and needs nothing |
| `central_vault` | waits (2.3) | |
| `kept_pins` | waits (2.3) | the Mac signs each machine's kept pin again with the owner's key; a PC holds no owner key in step 1 |
| `secret_replace` | waits (2.3) | Add secret puts a new value under a key that the list has, with the owner's signed statement |
| `contact_roles` | waits (2.4) | |
| `connected_apps` | waits (2.4) | the Mac alone today: no device route |
| `connect_offer` | not planned | Turn on runs a root step over the Mac's SSH and takes a Tailscale access token, and `/ui/connect*` is no device route |
| `need_pictures` | built | pictures as the options of a request (owner API 1.285; the owner's "Yes, as shown" of 21 November 2026 to `w4-windows-chat.png` and `w4-windows-needs.png`): `OwnerNeed.Pictures`, and one option is a choice on an item with one picture for it; `NeedPictures.Drawn` (only on a hub that names the feature, with one picture for each option, each a picture; else the card of before, and an answered item as before); `OptionsModel.Pictures` (each a `FileTile`) and `OptionsModel.Click`, the one command of the options: a click on a picture opens it as a file of a message opens and answers nothing, a click on its words answers with that option's index, and options that combine keep their ticks and "Send N". Every read of the state (`GET /ui/mobile`, as a device and as the owner's computer) says `X-Fleet-Draws: need_pictures` (`HubClient.DrawsHeader`, `Draws`). The window: `AnswerParts` and `OptionPictureView` in the chat's card and the request at hand, three in a row and a row more for each three more, the words under each, a square that keeps its size while its picture comes; the pictures read one at a time in the order of the options, a failed one again only by Read again, each by its id and SHA-256 in one generation (`PictureLoads`) (`NeedPicturesTests`). "Needs clarification" under "Your answer" is the line `need_clarify` |

## What no feature name carries

- **The background repair of servers that exist** (the Mac's sweep in `OwnerAccessSweep.swift` and `FleetStore.swift`: `ServerHardening`, `ServerMemory`, `ServerRestart`, `ServerUplink`, and the start guard for cloud-init's units that the area Setup, servers and owner tools builds now): **waits.** On a server that exists, the hub's own included, these root steps come only from the owner's Mac, so a fleet whose owner has only a PC gets each guard on new servers (the installers) and never on the servers that exist. The owner, 22 November 2026: "we need something reliable for ALL servers". It adds no element to a screen. Its order is rule 7 of section 0.1 of `~/dev/founderizer-plans/reliability-test-fleet-2026-11-21.md` (tested with the fault made on purpose, one server first, his fleet before the customers' track, one step takes it back), and its root part is read by the area Door and security, as the Mac's is. It needs the owner's computer on a PC (Windows step 2) before it can run.
- **The hub on this PC's Tailscale** (the Mac's `FleetOnTailscale`): built. `Tailnet` reads `tailscale status --json`,
  asks each device's `/health` in two seconds, and takes the first that answers; the store looks every five seconds while
  it is in front with no hub (`StoreState.Search`). The screens give `ITailscaleStatus`, which runs Windows' Tailscale.
- **Connect** with the iPhone's rules for an address: built (`OwnerStore.ConnectAsync`, `HubClient.Address`).
- **Fewer changes** from the store: built. A change only when a model of a screen changed, with its parts
  (`StoreChange.Parts`).
- **The key in the TPM, and its unlock by Windows Hello**: waits (the screens' `IKeyProtection`; plan, slice 1.5).
- **A press that comes while the store cannot write** (the window draws a change after the store made it): built. It
  waits for the write before it, or for the read that comes, and goes then, in the order of the presses; a lasting
  reason gives the owner's words (`StoreState.HoldsWrites`). The Mac draws its buttons on the thread of its store, so
  no press comes between there.
- **The app's own update** (the Mac's `AppUpdate` and `AppUpdateInstaller`, slice 1.6): the library's part is built:
  the Windows build's manifest (`WindowsManifest`, a third kind of signed text, `founderizer-windows-1`), the read of
  the channel and the comparison of builds (`WindowsUpdate`), and the download with its size and SHA-256
  (`BuildDownload`). The publisher check, the unpack, the launcher and the swap wait for the screens; the release job
  and the website wait (`~/dev/founderizer-plans/windows-app-release-design.md`).
- **Pings while the app is closed**: not planned in step 1 (decision D4).
- **An answer that waits 5 seconds with Undo, Pause on an answered card while its task works, and a press of its mark
  that opens the task** (the Mac's `AnswerHolds` and `NeedRequestCard.lineEnd`, 21 November 2026; the owner's "Yes, 5
  seconds (Recommended)", "Both (Recommended)", "Yes, open task", "Gray pause, as the row" and "Yes, Undo there
  too"): waits. A Windows card owes all three. The iPhone's card has them (`MobileStore.hold`, `pausable` and
  `taskOpened` in `ios/Sources/MobileStore.swift`), its Pause through `POST /ui/tasks/<id>/control`, which a device
  may use.
- **Two presses of the first run's provider pages** (the Mac's `CloudChoice` and `FirstFleetChoice`; found by piece U2
  of step 2, 22 November 2026): gaps of the PC's model, not drawn until it has them. "Servers in another project?"
  under a Hetzner list (the Mac's `askAnotherProject`: the next token takes the place of the one this computer holds)
  has no press in `SetupStore`, and set 8 draws none. "Use this server" for a server of the account's list (the Mac's
  `useExisting`: the hub's install on a server that the account holds) has no press either: the window draws the
  account's servers grey, with the new server chosen and "Make the server". Each waits for a library piece of its own.
- **The other provider's card on the provider page of a manager that has its server** (the Mac's `providers` in
  `AgentSetupWizard`, found by piece U3 of step 2, 22 November 2026): a gap of the PC's model. The Mac draws both cards,
  and a press on the other one starts its preparation and then the switch (`AgentSetupFlow.Start.prepare`,
  `prepareServerRuntime`, `agentRuntime`). The PC's `AgentSetupModel.Cards` gives the manager's own provider alone,
  because the PC has no write for the preparation and the switch yet: a second card would do nothing. That page shows
  only after a failed install or a sign-in that stopped; a manager with no server still gets both cards. It waits for
  the change of an agent's provider (wave C, the agent's page).
- **The slider of "Your fleet's servers" in the manager's setup, with its root step on the hub's own server** (the Mac's
  `fleetServers` with `HubShareModel`, found by piece U3): a manager with no server of a fleet whose first run did not
  keep a step, or whose "1 server" needs that root step, shows the frame of its page alone (wave B, piece L6). Where the
  wait for the hub's own server stops, the PC says the Mac's words over Try again, which waits again; the Mac shows its
  slider there with Continue.
- **Enter on the hub's checks that did not pass** (the Mac's `MachineInstallRun`, found by piece U3): the Mac's "Open
  Founderizer" is no default action, so Return does not press it. The PC's page does not press it on Enter either, but
  WinUI gives the first button of a page the keyboard focus when the window opens, and a focused button takes Enter
  before the page does (measured in the VM on the welcome page): on a page that opens on these checks, Enter presses
  "Open Founderizer" through its focus. A page that does not keep the first focus on that button closes the gap; it
  touches the focus of every page of the first run, so it waits for its own piece.
- **A request card in a window of its own** (the Mac's `NeedWindows`, 21 November 2026): not planned: it is the
  Mac's alone, an AppKit panel over every app, also over a full-screen one.
- **An answer waits 5 seconds with Undo, Pause stands on its card while its task works, and the mark opens the task**
  (the Mac's `AnswerHolds`, `NeedRequestCard.lineEnd`, `NeedAnswered.waits`, Founderizer 0.1.435; the owner's "Yes, 5
  seconds (Recommended)", "Both (Recommended)", "Yes, open task", "Gray pause, as the row" and "Yes, Undo there too" of
  21 November 2026): built. Each answer that a card sends (an option, the ticked options, a quick reply, his words with
  the box's files) waits in the store's state for 5 seconds (`OwnerStore.Hold`, `StoreState.HeldAnswers`,
  `HeldAnswer`, `OwnerStore.AnswerWait`), and nothing of it reaches the outbox or the hub meanwhile; then it goes on
  its path of before (`Press`, `TickAsync`, `Reply`, the typed answer's), only to the hub and generation of the press,
  and the card stays folded with no Undo until that press went or was dropped (`HeldAnswer.Leaving`). The ticks and
  his words wait until the store can write, as an option's press does (`OwnerStore.WritableAsync`, the Mac's
  `writable`): a request that waits in the outbox or a reading that is not current does not lose them. His typed words
  stay in the store's draft and its file while they wait (`SetAnswerDraft` keeps out the view's empty box), and the
  receipt takes them out, so a crash, a kill or the app's end loses none; an answer that did not go opens its card
  with its ticks and words (`LeftAsync`). It is taken in
  one step with the check that it still waits, so the wait, the app's end and Undo never send it twice. The folded card
  in a chat and the request at hand on Needs you show his answer with "Undo" at the end of the line and no mark
  (`RequestCard.Holds`, `RequestStep.Holds`); the request stays at hand for the wait, then leaves as one on its way.
  Undo (`OwnerStore.Undo`) opens the card as it was: his typed words back in the box, his ticks, his files
  (`StoreState.Undone`, `AnswerBoxModel.Given`, `OptionsModel.Ticked`), the ticks once, to whichever view shows the
  card next (`AnswerBoxLoad`, `OwnerStore.TicksShown`, the Mac's `restoredTicks(of:)`); after the wait it does
  nothing. A quick reply that is not held stands in the box as in the store's draft (`Hold` gives its words). A newer answer
  of the request takes the place of one that waits, also of a press or a quick reply that waits for the store. Not
  held, as on the Mac: a key request's answer, a card whose own request waits unsent (its press is dropped), and a
  quick reply while a file of its box goes up. The window's close and an update's restart end the store
  (`DisposeAsync`), which sends what waits at once: what the store can write now is in the outbox before the store
  ends; one that cannot go in this run (another write on its way, or a reading that is not current) goes nowhere, and
  its request stays open on the hub. The update waits while an answer waits (`Updater.CheckSwap`). Pause
  (`RequestCard.Pause`): the task's Pause icon, 20 square, at the end of the folded card's line, only while the mark is
  that task's work, on a hub with `task_controls`, for a task that is not over and that no hold holds; it sends
  `OwnerCommand.Control` for that task, and is off while the store cannot write. The mark opens the task's page
  (`RequestCard.OpensTask`, `Pages/Requests.cs` `MarkPress`): the turning mark of a task's work, every orange mark and
  the gray mark of his pause, with the hand, a soft round fill under the pointer, the system's focus frame, Enter or
  Space, and "Open the task" for an assistive app; the check, the red mark and the plan's "The hub makes the change"
  open nothing. On Needs you only Undo, as the Mac. The proofs' sample state `undo` shows a folded card with Undo, and
  `work-mark` a card with Pause (`AnswerHoldTests`, `RequestCardAsTheMacTests`, `SwiftWordsTests`). Windows has no
  card window, so nothing closes one.
- **A request card's one badge for a name beside its role, and a chip with a copy icon on each value** (the Mac's
  `CardJoin` and `CardValueText`, 21 November 2026; the owner's "Yes, as drawn"). The iPhone's card has the chip (`CardValueWords` in `ios/Sources/CardValueChips.swift`); the iPhone
  draws no name badges, so the one badge does not apply to it.
  Windows: **the chip is built.** Each value that the agent put in inline code (`CardValues` in `Founderizer.Core`,
  FleetCore's rule with no names; `RequestBody.WhyValues`, `TaskValues`, `DetailsValues`, `TodoBehindValues`, none
  in a door's script) is a chip in the reason, the task, the steps and the details of a request's card in a chat and
  of the request at hand in Needs you (`Pages/ValueChips.cs`, `Blocks.FillValues`), never in the folded start of a
  reason, his answer or a chat's message: inline code's fill, a copy icon (Fluent's copy) after the value, muted,
  in the words' colour and the chip a little lighter under the pointer, the hand, a press anywhere on the chip
  copies the value exactly to the system's clipboard and the icon is a check for 1.5 s; Tab reaches the icon, Enter
  or Space copies, and an assistive app reads "Copy <value>". No character is added (the icon's room is the spacing
  after the value's last character), and a value that wraps has its icon on its last line. The library reads a code
  span as CommonMark and the Mac do (`InlineMarks`: one space from each end only when both have one, a line's end as
  a space, a backslash and an entity in code as written, a whole run of backticks), so that a copy holds the Mac's
  characters (`CardValuesTests`). The proofs' sample state `values` shows such a card. **The one badge waits:**
  Windows draws no name as a badge in a card's words (no `CardNames` yet), so there is nothing to join; and so a
  knowledge file's path in inline code is a value on Windows, where the Mac draws its badge.
