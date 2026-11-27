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
| `task_limit` | built | each task's own `limit` (owner API 1.330): with the feature, a task's "Usage limit", its mark, its lane and its page's limit line come from `task.limit` alone (`TaskLimit`), else from its agent's `limit`; the agent's row and chat keep the agent's `limit`. The page's line names the agent only when its own route is held, else "Usage limit until <time>". Later, with the Mac and the iPhone: an agent's dot reads its tasks' marks with no limit (`States.cs` `limited: false`), so it says "Working" for a desktop task that a hold of its screen route keeps waiting |
| `outcome_checks` | built | TaskOutcome.Checker; WaitsOnOwner(…, routed) in Activity.OwnerChecks and the task page's limit line (ScreensTests) |
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
| `machine_check` | waits (2.1) | the check of an agent's machine, by itself once it is signed in, is in the library (piece L4b: `OwnerReads.CheckAsync`, `AgentSetupModel`); its page waits (U3b, U5) |
| `file_changes` | built | the latest completed report of each path from the task's record (`ActivityTimeline.ChangedFiles`, `ChangedFilesModel`); the panel's "Changed files" (`Pages/TasksPages.cs` `ChangedFiles`, fourth set, 2a) |
| `subagents` | built | the child agents of the record (`ActivityTimeline.ChildAgents`, `ChildAgentsModel`, `Screens.ChildThread`); a step's child rows and "Open agent thread" (`Pages/TaskRows.cs`), the panel's "Child agents" (`Pages/TasksPages.cs` `ChildAgentsView`) and the child agent's thread with "Back" (`ChildHeadRowView`) |
| `vault_isolation` | not planned | the Mac app's row "Vault token" stood only in the old details of a server, which no hub since October 2026 showed; it went with them on 19 November 2026 |
| `triggers` | waits (2.4) | wake-up rules. For that phase: a rule's check can have the form `read` (UI-API.md 1.191), and a last run in the state `joined` is no trouble (`TriggerRun.goodStates`) |
| `trigger_checks` | waits (2.4) | |
| `agent_setup` | waits (2.2) | `active` of an agent is read (built); the setup of the manager of a new fleet, from its install to its first session, is built (piece U3: `ManagerSetup`, `Pages/Agents/Setup/`); the setup of any other agent, with its machine's check and its activation by themselves, is in the library (piece L4b: `ManagerSetup.ForAgent`, `OwnerReads.ActivateAsync`, `AddAgentAsync`); its window waits (U5) |
| `wakeups` | waits (2.4) | |
| `screen_model` | waits (2.2) | |
| `agent_auth` | waits (2.2) | |
| `vault_access` | waits (2.3) | |
| `runtime_switch` | waits (2.2) | |
| `account_email` | waits (2.2) | |
| `secrets` | waits (2.3) | the library is built (L5): the secure form as a model (`SecretForm`), the seal and the fingerprints; the key card is U4's, the pages are wave C's |
| `login_create` | waits (2.3) | |
| `login_capture` | waits (2.3) | |
| `api_request` | waits (2.3) | |
| `owner_knowledge` | built | `GET /ui/knowledge`, one file with its text |
| `secret_grants` | waits (2.3) | the library is built (L5): `SecretAccess.ChangeAsync`, signed before `POST /ui/secrets/grant` for a give and after it for an end; the pages are wave C's |
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
| `secret_requests` | waits (2.3) | an item's `secret` is read (built); its answer is the secure form of 2.3, whose library is built (L5: a new key, a new value of a key that the fleet holds, a login with its 2FA). Until the key card (U4), an owner with only a PC cannot give one |
| `signed_grants` | waits (2.3) | the statement writer is built (`OwnerStatement.Grant`), and the signing with its clock (L5: `VaultSigning`, `GrantClock`); the owner key in the TPM is U4's |
| `agent_rename` | waits (2.2) | |
| `manager_rename` | built | "Name your manager" of a hub whose first run did not ask, in the manager's setup (piece U3b: `ManagerSetup.TakeNameAsync`, `OwnerReads.RenameAsync`, `Pages/Agents/Setup/ManagerNamePage.cs`), with Back to it on the provider's page, as the Mac (`BackToName`) |
| `agent_spelling` | built | owner API 1.339: `MobileAgent.Spelling`; `AgentBook.Of` takes each spelling only from a hub that serves it, and `AgentBook.Label` names the agent by it (`AgentSpellingTests`). `AgentBook.Spelling` is the rule of the add and rename commands' `spelling`, for the PC's rename (U3b) and Add agent when they come. **Two gaps.** A task that an agent opened from the owner's message begins with hub.py's own sentence, which keeps the id ("The owner asked for this in their own words, in devops's chat: …"); the Mac takes that sentence away (`FleetTask.ownersWords`), and the PC shows it in the task's first row (`Screens.Task` `Asks`) until piece 2 of the AI mark, which changes that row. Narrator's name of a chat's page is set when the page opens (`MainWindow.ShowPage`), so a spelling or a role that changes while that chat is open is named at its next opening |
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
| `recovery_copy` | waits (D5) | needs the QR's `bind` value; the seal for the phone is built (L5: `RecoverySeal`). **Built**: an item's `add_device` is read: the first option of a card with `add_device` 1, which opens the Add device picture on the Mac, stands grey and not enabled, and no route of the store sends it, as the row `door_setup` says |
| `server_ai_choice` | waits (2.1) | |
| `manager_server` | waits (2.1) | the first run's server that joined goes to the manager with the chosen provider by itself, and the setup fills the window until the manager runs (piece U3); the server's page of a manager with no server is in the library for a new server at a provider, its join and its hand-over, the first run's server that did not join, and a free server of the fleet (piece L4b: `AgentServerStep`, `ManagerSetup.TakeServerAsync`); Other VPS there waits (its check is in `SetupStore`), and the drawing waits (U3b). Two departures from the Mac until wave C gives the PC the provider's row "Use this server" (the Mac's `MadeServers`, `firstToReuse`). First, the first run's server leaves the manager's mark only when a join of it ended well, where the Mac lets it go as the join starts. Second, the page also joins it by itself when the hub lists it free (`ServerList.TakesFirst`, and no "busy" in its `why`, as the Mac's reuse reads it), where the Mac's `installFirst` returns when the hub lists it (its provider's list offers it). The page joins it by itself once, as the Mac, also when the first run's own join of it stopped, and the mark keeps it from the claim on; after that join of the page stopped or a closed app cut it off, each opening of the page shows that stop with Try again (this PC's install records) and nothing joins by itself, and after Back from that stop the same opening offers only "Make the server" (the stop comes back at the next opening). With no row that offers the server by name, a device that is online at another address (it registered again in Tailscale) leaves the page on its first page with nothing of the server, and the only way on is a second paid server |
| `knowledge_edit` | waits (step 2) | a write of the owner's knowledge stays on the Mac |
| `door_setup` | waits (2.4) | the App itself (GitHub's manifest flow) waits. **Built**: an item's `github_app` is read (`OwnerNeed.FirstOptionOnTheMac`, FleetCore's `OwnerNeed.firstOptionStartsOnTheMac`, which the iPhone's `MobileStore.startsOnTheMac` holds to: two options or more, no team yes, no full access and no give): the first option of a card whose `github_app` names an account stands with its own words, grey and not enabled (UI Automation too; `OptionsModel.OnlyOnTheMac`, `Pages/Requests.cs` `Row`), its click does nothing, and no route of the store sends choice 0 for it (a press, a press that waits, the 5-second hold, ticks and their hold, and the last check of a write, `OwnerNeed.OnlyOnTheMac`); the card stays open, and its other options, its other ticks and his words still go (`OptionOnTheMacTests`). A press on Windows had answered the card with choice 0: the hub closed it, and nothing started |
| `agent_remove` | waits (2.2) | |
| `repo_picker` | waits (2.3) | |
| `need_talk` | built | the short card, Details and options that combine (`RequestCard`, `RequestStep`, `OptionsModel`), and an old outbox's question of Discuss (which left in owner API 1.158; its record's kind `need_talk`) is dropped; the talk under a card, whose route is back since owner API 1.272, is the line `need_clarify` |
| `need_clarify` | built | Needs clarification on every card (owner API 1.272, hub release 2026.11.718; the owner's "Yes, as shown" of 21 November 2026 to `w4-windows-chat.png` and `w4-windows-needs.png`, and his "Keep Your answer too" of 20 November for the Mac and the iPhone): an item's `clarify` and `talk` (`OwnerNeed.Clarifies`, `ShownTalk`, `NeedMessage`); his message under a card is a command on its own route (`OwnerCommand.Talk`, `POST /ui/needs/<id>/talk`, also from a device; its outbox kind `need_clarify`), saved and sent once, whose command's receipt names the item and carries its talk (`ControlReceipt.Need`, `Talk`; `PendingRequest.IsConfirmedBy`). The field's words are the store's, in memory only (`StoreState.ClarifyDrafts`, `OwnerStore.OpenClarify`, `SetClarifyDraft`, `TalkAsync`): they leave the field once the outbox has the message, and the link comes back; a refused message's Discard gives them back to the card's field, never to a chat's draft; a 422 takes them off the PC with the drafts. The card shows the message from the receipt until a reading has it (`StoreState.TalkTaken`, `TalkOf`); a press on the card's options behind its own unsent request is dropped (`StoreState.WaitsUnsent`); a lost receipt is confirmed by the next read whose talk has more of his lines with those words than at the send (`OwnerStore.ReplayTakenTalk`), never by an older line and never without this PC's key. The request line names it "Ask about" and the item's title, Settings "Message to" and its agent. The window (`AnswerParts.ShowClarify`, `Screens.RequestCard.Talk` and `Clarify`, `RequestStep.Talk` and `Clarify`): the talk over the options, his lines in his chat's bubble at the trailing side and the agent's after its mark, and on the request at hand over his answer once it ended; the link in muted words at the leading side under "Your answer" in a chat's card (12 on 16) and in the middle at hand (15 on 21), and in its place the answer's box with no plus, "Message to" and the agent, Send with Enter. A folded card in a chat shows no talk (the Windows card does not open after the answer). The view's field (`ClarifyField`) loads the store's words only when it comes to stand, for another card, or when the store gave words of its own (`ClarifyModel.Given`, the Discard), passes on only his own changes of a field that stands (so the words stay through the fold of an answer that the hub then refuses), and takes the cursor once, for the card whose field the store opened (`NeedClarifyTests`). **Words that look like a key wait for his choice before they go** (UI-API 1.249: "those apps hold text that looks like a key before it goes"): **built** (the owner's "Yes, as drawn" of 22 November 2026 to its picture `windows-key-hold-2026-11-22.png`, the strip in the chat's composer, and his "Yes, as shown (Recommended)" of the same day to `windows-key-hold-card-2026-11-22.png` and `windows-key-hold-clarify-2026-11-22.png`, the strip in a request's answer box and in the field of Needs clarification, as on the Mac). In this field, the chat's composer and a request's answer box, the words that FleetCore's rule (`KeyInText`, held equal to the Swift by `app/vectors/key-in-text.json`) reads as a key do not go by any path, Send stands down, and the Mac's hold stands over the line (`KeyHoldModel`, `Field.ShowHold`): "This message holds what looks like a key.", the start of its second line, and "Keep it" (`OwnerStore.KeepKey`), which lets them go while the key stays in the box; the drafts' file never keeps them (`KeyHoldTests`). The Mac's "Save it as a secret" and its hold of a paste are not here, because this app has no form of a secret yet (`secrets`, 2.3); guidance for a task and a card's feedback have no hold yet |
| `need_marks` | built | an item's `team_state`, `team_reason`, `task` and `give` (owner API 1.280; `OwnerNeed`), the mark in the place of an answered card's check in a chat and of the answered request at hand in Needs you (`AnswerMark.Of`, the Mac's `OwnerNeed.answeredMark`; `Screens.AnsweredMark`, `RequestCard.AnswerMark`, `RequestStep.AnswerMark`; `Pages/Requests.cs` `AnswerMarkView`): the check with the Mac's words (the raising agent's name and "has your answer", "Changed", "Given", "Done", or the task's state word), the turning green mark of work ("The hub makes the change", or the task agent's name and the task's title), the red mark of a result that is no success, the orange mark where the task's row needs him (the owner's "Orange mark" of 21 November 2026; `AnswerSymbol.Attention` with the row's `TaskSymbol` in `AnswerMark.Row` and the row's words, as "Outcome not known: check it"; the search card's icon for that symbol, `SearchCard.IconOf`, in its orange), the gray pause mark where his own pause that the hub confirmed holds the task (the owner's "Gray pause, as the row" of 21 November 2026; `AnswerSymbol.Paused` for a hold of kind "pause" in the hub's state "stopped", with the row's `TaskSymbol.Paused` in `AnswerMark.Row` and the row's words, "Paused"; the search card's pause icon in its muted gray, at the check's 12 pixels), in the Mac's order (`FleetTask.tint`, then `OwnerNeed.answeredMark`: an outcome that is not known and the owner's hold before a result and before work, so a failed task that his pause holds is the gray pause; then work; then his pause); the words on hover (the system's tooltip) and as the automation name; for a task's work the hover is the Mac's tag (the owner's "Yes, badge as drawn" of 21 November 2026; `AnswerMark.Badge`, `AgentBadge.Of`, `AnswerMarkView.WorkTag`): the agent's badge (its mark at rest and its name, on the link's colour) then " · " and the task's title, wrapping at 360, as the system's tooltip under the mark, its words at the answer line's left edge and above the mark only where the window's bottom ends (`PlaceTag`, the Mac's HoverTag), which takes no focus and no click; the view opens it after the Mac's rest of the pointer, 350 ms (`OpenTag`), because WinUI puts a tooltip that its service opens for the pointer at the pointer, whatever its placement rectangle says, and it goes when the pointer leaves, when the mark moves, and at a click, a key or a scroll in the window (`Watch`), and stays away until the pointer leaves; the plain check for words, a saved key and an answer on its way; the turning mark, the orange mark and the gray mark of his pause open their own card's task (`RequestCard.OpensTask`; see "An answer waits 5 seconds with Undo" below) |
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
| `central_vault` | waits (2.3) | the library is built (L5): `VaultReading`, `VaultSealKey`, `VaultPlan`; the rounds that run the plan are L6's |
| `pool_default` | waits (2.3) | the library is built (L5): `OwnerStatement.DefaultPool`, `VaultReading.PoolDue` (`standing.due`), `VaultSigning.PoolsAsync` (at most 32 a round, the ends first, a `default_pool` only while the clocks agree); L6's `VaultRound` calls it |
| `kept_pins` | waits (2.3) | `VaultPlan` is built (L5), the round is L6's; the Mac signs each machine's kept pin again with the owner's key; a PC holds no owner key in step 1 |
| `secret_replace` | waits (2.3) | Add secret puts a new value under a key that the list has, with the owner's signed statement: the library is built (L5: `OwnerStatement.Replace`, `SecretForm`) |
| `contact_roles` | waits (2.4) | |
| `connected_apps` | waits (2.4) | the Mac alone today: no device route |
| `connect_offer` | not planned | Turn on runs a root step over the Mac's SSH and takes a Tailscale access token, and `/ui/connect*` is no device route |
| `need_pictures` | built | pictures as the options of a request (owner API 1.285; the owner's "Yes, as shown" of 21 November 2026 to `w4-windows-chat.png` and `w4-windows-needs.png`): `OwnerNeed.Pictures`, and one option is a choice on an item with one picture for it; `NeedPictures.Drawn` (only on a hub that names the feature, with one picture for each option, each a picture; else the card of before, and an answered item as before); `OptionsModel.Pictures` (each a `FileTile`) and `OptionsModel.Click`, the one command of the options: a click on a picture opens it as a file of a message opens and answers nothing, a click on its words answers with that option's index, and options that combine keep their ticks and "Send N". Every read of the state (`GET /ui/mobile`, as a device and as the owner's computer) says `X-Fleet-Draws: need_pictures` (`HubClient.DrawsHeader`, `Draws`). The window: `AnswerParts` and `OptionPictureView` in the chat's card and the request at hand, three in a row and a row more for each three more, the words under each, a square that keeps its size while its picture comes; the pictures read one at a time in the order of the options, a failed one again only by Read again, each by its id and SHA-256 in one generation (`PictureLoads`) (`NeedPicturesTests`). "Needs clarification" under "Your answer" is the line `need_clarify` |

## What no feature name carries

- **The background repair of servers that exist** (the Mac's sweep in `OwnerAccessSweep.swift` and `FleetStore.swift`: `ServerHardening`, `ServerMemory`, `ServerRestart`, `ServerUplink`, and the start guard for cloud-init's units that the area Setup, servers and owner tools builds now): **waits.** On a server that exists, the hub's own included, these root steps come only from the owner's Mac, so a fleet whose owner has only a PC gets each guard on new servers (the installers) and never on the servers that exist. The owner, 22 November 2026: "we need something reliable for ALL servers". It adds no element to a screen. Its order is rule 7 of section 0.1 of `~/dev/founderizer-plans/reliability-test-fleet-2026-11-21.md` (tested with the fault made on purpose, one server first, his fleet before the customers' track, one step takes it back), and its root part is read by the area Door and security, as the Mac's is. It needs the owner's computer on a PC (Windows step 2) before it can run. Piece L6 (the library, `Founderizer.Setup/RootJobs`) has the engine, the hardening, the browser parts and the access line, with the Mac's programs byte for byte; no round runs before the window's U4 starts it, and `ServerMemory`, `ServerRestart`, `ServerUplink` and `ServerLibraries` are the plan's L15.
- **No first host key of a Mac, or of a server that the hub has not reported as Linux, at any port** (the Mac's
  `macServer` rule, `93d95edfb` and `b64e9670f`: such a key is the owner's own step, and `ssh` keeps none by itself):
  no PC counterpart yet. Every `HostKeyRule.TakeNew` call of the PC is the first run's: its check (`ServerCheck`, the
  server that the owner typed), its password or key step (`PasswordOnce.RunAsync` and `KeyAsync`, the same server), the
  install of the hub's server (`Installer`, the server that the owner typed or, from `MakeFleet`, the one that the PC made
  at the provider, also a try again), and the join of the manager's server, which the PC made at the provider
  (`SetupStore.RunJoinAsync`). The Mac's own first install keeps a first key in the same way (`portGivenFor`), for a
  server that no hub has reported yet. So no such call of the PC reaches a server of a hub's list, and every root job runs
  under `Known`. The piece that first connects the PC to a server of the hub's list (a server's page check, a Mac server's
  screen or vault) takes the Mac's rule.
- **The line, the minutes and the bar of an install on the first run's build page** (F4 of the owner's feedback of 22
  November 2026, pieces 2 to 5; the Mac's `InstallPhases`, `InstallHold`, `MachineInstallModel.record` and
  `FleetBuildLine`): built, through the shared vectors (`install-reads.json`, `InstallVectorTests`). The line is the one
  table's phrase of each plan step and of each heading of `hub.sh` (`InstallPhases.StatusOf`, `HubHeadings`). The
  minutes count from the start of the step that runs, not from its last report (`InstallView.Reported`), and show only
  while they are true: not past the step's estimate, and not while three reads in a row of the installer's log reach no
  server (`InstallProgress.Unreachable`): there the PC and the Mac match, and on the Mac's build page too that is all
  that piece 5 changes. Each part of
  the bar is the units that ended (the plan's steps and the installer's headings, `InstallPhases.InstallerHeadings`),
  never the clock; one press's hold, kept at each report, keeps the furthest share of each part while the press runs,
  and the line of a heading that the table does not have (`InstallHold`, in `InstallView.Hold`, applied by
  `InstallView.Phases`); a new press starts it again. The part that runs breathes
  (`BuildLine`, the owner's "Yes, as drawn" to the Mac's picture P7). The PC shows no install page with the steps under
  a title, so the Mac's look (a) of Add server has no place here yet. **Waits:** the stall line under the bar (the
  Mac's "This Mac cannot reach web-1 now. It tries again.", piece 5): the PC has no page for it yet. A join says
  "Installing Founderizer" for its whole step on both apps; piece 1 (join.sh headings, and a reader of a join's lines as
  they come) is not built on either, and `JoinHeadings` waits for it. The server's sign that makes itself by the steps
  (piece 6) stays the Mac's, as an agent's making does.
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
  keep a step, or whose "1 server" needs that root step, does not have its page: the setup does not take the window
  there, and the manager's page shows with the pane (wave B, pieces L6 and U3b). Where the
  wait for the hub's own server stops, the PC says the Mac's words over Try again, which waits again; the Mac shows its
  slider there with Continue.
- **Enter on the hub's checks that did not pass** (the Mac's `MachineInstallRun`, found by piece U3): the Mac's "Open
  Founderizer" is no default action, so Return does not press it. The PC's page does not press it on Enter either, but
  WinUI gives the first button of a page the keyboard focus when the window opens, and a focused button takes Enter
  before the page does (measured in the VM on the welcome page): on a page that opens on these checks, Enter presses
  "Open Founderizer" through its focus. A page that does not keep the first focus on that button closes the gap; it
  touches the focus of every page of the first run, so it waits for its own piece.
- **A request card in a window of its own** (the Mac's `NeedWindows`, 21 November 2026): gone on the Mac too. This row
  is older than F12: the Mac made that window the one badge at the foot of the sidebar, which holds Undo for 5 seconds
  (Founderizer 0.1.482, `bbceecaa5`). The PC takes F12 in U5.
- **An answer waits 5 seconds with Undo, Pause stands on its card while its task works, and the mark opens the task**
  (the Mac's `AnswerHolds`, `NeedRequestCard.lineEnd`, `NeedAnswered.waits` of Founderizer 0.1.435, which F12 (Founderizer
  0.1.482, `bbceecaa5`: one held answer for the app, the card completes at once, ONE badge holds Undo for 5 seconds) replaced
  on the Mac; the PC takes F12 in U5; the owner's "Yes, 5
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
- **An agent by its name, with its role beside it** (the Mac's `AgentNames.label` and `AgentNames.role`; the owner's
  answers of 22 November 2026 to F16, option (a): "Each place of the Mac, iPhone and PC apps ...", and "The name with
  the role in grey"): built. `AgentBook.Label` gives the owner's spelling of the name where the hub keeps one
  (`agent_spelling`), else the name with capitals, and the role only when one word of it is the name ("Fleet Manager"); `AgentBook.Role` gives the role beside it, and `AgentBook.Matches` still finds an agent by
  its role. Every `Names.Label` follows ("From Wren · 14:32", "Message to Wren"). The pane's row draws the name, then
  " · " and the role, muted (`AgentRow.Role`, `AgentRowView`), and the chat's panel the name over the role
  (`AgentPanel.Role`, `Pages/Panels.cs`). The words are the vectors' (`swift-words.json`, `label` and `role`). The
  pill over a chat shows the name, then " · " and the role muted, as the Mac's chat header (F16 piece 5;
  `ChatModel.Role`, `PillTrail`, `Pages/ChatPage.cs`), and an assistive app reads "Chat with <name>" (`PillWords`), as
  VoiceOver reads the Mac's. **A follow-up:** the pill's words are a TextBlock in a horizontal StackPanel, which never
  cuts, so a very long role widens the pill past a narrow chat column, where the Mac cuts the line's end; a `MaxWidth`
  from the column would cut the role first. The search card's agent row draws the name, then " · " and the role
  muted, as the Mac's search palette row (`SearchAgentRow.Role`, `Trail`, `Spoken`, `Pages/SearchCard.cs`), and an
  assistive app reads the name, the role and the row's line, as VoiceOver reads the Mac's.
- **An icon button has no grey ground at rest** (the owner, 23 November 2026: "dont add the grey backgroundto the icon
  buttons unless on hover"; the Mac's `IconMetrics.fill`). Windows: built. `Buttons.IconOnly` drew Windows' button face at
  rest in two places (Read again of a picture that did not load, in a chat and in a request's option); it draws none now,
  as every other icon button of the window, and Windows' subtle fill comes under the pointer and on the press
  (`WindowRulesTests`). The iPhone has no pointer, and nothing changes there. **While one cannot be pressed its mark is
  dimmed** (0.45, the Mac's): its mark has a brush of its own, which the style's disabled colour never reached, so a
  disabled Pause or Stop looked as one that acts, with its face and without it.
- **A create after a 5xx or no answer is not "nothing there"** (finding 3 of the checked audit of 24 November 2026; the
  Mac's `CloudServers.madeMeanwhile`, `followUp`, `failed`, `create` and `remove`, `CloudError.unsure` and `takenBack`,
  and `BuildRecord.AtProvider.after`, `003053345` to `ee720b384`, with the vectors of `442ce8f17`): built. After the
  provider's own fault answer (a 5xx), or no answer, to the call that makes the server, `CloudServers` reads the
  servers with the call's own mark before it takes anything back (`MadeBehindAsync`: at Hetzner the servers behind the
  call's firewall, at Akamai its firewall's Linodes, at Vultr the instances of that name behind its group, at
  DigitalOcean the droplets with its tag, which the droplet now carries with the tag of what it is for). The one there
  goes with the firewall (`TakenBack`, which the build's record reads as nothing); every other end takes nothing back
  (`Unsure`, read as not known, so the name stays in use), and reads on for the mark every 30 seconds for the join
  key's hour (`FollowUp`, `FollowReads`), which deletes the server that comes, again while it stays, and never two. A
  server that does not go keeps its firewall; Hetzner's `locked` deletion is asked again; a gateway's page of HTML is
  said by its status; the words are the Mac's catalog's (the vectors hold them). A 4xx stays a refusal with no read.
  The PC's two differences: (1) the Mac's Back on its way is a stop of the call (a cancel) on the PC, which ends as a
  call with no answer; the PC's first run has no Back while a build runs (`SetupStore.Runs`), and a cancelled build
  changes nothing of its page (`CloudStep`, as the Mac's build); (2) a stop before the call for the server goes sends
  nothing (`CloudServers.CreateCallAsync`): the PC takes the firewall back, and the build's record stays not known
  (`CloudStep`'s cancel), where the Mac reads the mark and ends `Unsure`. The PC's way is the safer one: no request
  went, so no server can come, and the name stays in use all the same. **A gap:** the account's list carries what this
  app made each server for (`CloudExisting.MadeFor`, at DigitalOcean now too), and no PC code reads it yet: the Mac's
  `CloudExisting.unfit` ("Used by Founderizer") comes with pieces L3 and L4, so until then a stray server of an unsure
  end (a `hub-1` that the provider made late) can show as a card in the first run's list (`SetupScreens`) until the
  reads delete it. It costs nothing: a chosen server makes no build (`CloudStep.MakeNew`). L4 ports `unfit` with
  `madeFor`. Start again's firewall deletion is the Mac's and did not change:
  a 5xx at Vultr or Akamai is asked again, at most 10 times, and there only a firewall that nothing but the deleted
  servers uses is asked. **A limit, as on the Mac:** the reads run while the app runs; the mark is not kept in the
  build's record, so a start of the app does not read for it again (the words tell the owner what to delete).
