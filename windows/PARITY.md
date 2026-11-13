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
| `thread_events` | waits (1.4) | `GET /ui/tasks/<id>/events`, the task's thread; the iPhone does not read it |
| `task_controls` | built | `OwnerCommand.Control`, `POST /ui/tasks/<id>/control`, with its receipt |
| `limit_holds` | built | the agents' `limit`: "Usage limit" in a chat's waiting line, a task's page and the panel |
| `liveness` | built | `MobileAgent.HelperIsRecent` |
| `live_desktop` | waits (step 2) | a task's screen; not at the iPhone's level |
| `machines` | waits (2.1) | a setup page of the Mac |
| `goals` | waits (step 2) | `/ui/goals` is no device route; a task's goal text is built |
| `profiles` | waits (2.2) | a setup page of the Mac |
| `goal_tokens` | waits (step 2) | |
| `task_steering` | built | `OwnerCommand.Steer`, `POST /ui/tasks/<id>/steer`, with its receipt |
| `health` | waits (2.5) | |
| `reporting_lines` | waits (2.2) | |
| `leads` | waits (2.2) | |
| `browser_desktop` | waits (step 2) | |
| `machine_check` | waits (2.1) | |
| `file_changes` | waits (step 2) | part of a task's thread |
| `subagents` | waits (step 2) | part of a task's thread |
| `vault_isolation` | waits (2.3) | |
| `triggers` | waits (2.4) | wake-up rules |
| `trigger_checks` | waits (2.4) | |
| `agent_setup` | waits (2.2) | `active` of an agent is read (built) |
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
| `servers` | waits (2.1) | |
| `responsibilities` | waits (step 2) | duties |
| `server_prepare` | waits (2.1) | |
| `mobile` | built | `GET /ui/mobile` with its ETag, the chat and task pages, enrollment with the PC's `kind` (owner API 1.149), the devices list with each device's `kind`; the key kept between starts (`FileKeyStore` through the screens' `IKeyProtection`) and Forget the key |
| `attachments` | built | `OwnerStore.AddFileAsync` keeps a picked file's bytes in the store's folder, then sends it up with its own number before its message (the iPhone's StagedFile: it stays between starts, `UploadAsync` sends one that did not go again, `RemoveFile` takes it out); `FileAsync` reads one back with its size and SHA-256 checked (the device routes since `afb3188de`); the twin's `files` test |
| `resource_grants` | waits (2.3) | |
| `machine_signin` | waits (2.2) | |
| `releases` | waits (2.5) | the fleet's updates page; the line format of a fleet release is built (`FleetRelease`) |
| `entitlement` | not planned | Founderizer has no subscription since 10 November 2026 |
| `agent_signin` | waits (2.2) | |
| `github_app` | waits (2.4) | |
| `need_options` | built | `OwnerNeed.Choices`, `OptionsModel` (presses, ticks, the quick replies), `OwnerStore.Press` and `TickAsync` |
| `restore` | waits (2.1) | |
| `manager_start` | waits (2.5) | |
| `agent_notes` | waits (2.2) | |
| `edit_in_place` | built | `SendReceipt.Edited` and `MessageRequestId` |
| `machine_access` | waits (2.1) | |
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
| `manager_server` | waits (2.1) | |
| `knowledge_edit` | waits (step 2) | a write of the owner's knowledge stays on the Mac |
| `door_setup` | waits (2.4) | |
| `agent_remove` | waits (2.2) | |
| `repo_picker` | waits (2.3) | |
| `need_talk` | built | the short card, Details and options that combine (`RequestCard`, `RequestStep`, `OptionsModel`); no Discuss since owner API 1.158: the talk route answers 404, and an old outbox's question is dropped |
| `person_scope` | waits (2.4) | |
| `history_messages` | waits (step 2) | |
| `secret_compare` | waits (2.3) | |
| `default_models` | waits (2.2) | |
| `web_hosts` | waits (2.2) | |
| `chat_waits` | built | `MobileAgent.WaitsSince` |
| `central_vault` | waits (2.3) | |
| `kept_pins` | waits (2.3) | the Mac signs each machine's kept pin again with the owner's key; a PC holds no owner key in step 1 |
| `secret_replace` | waits (2.3) | Add secret puts a new value under a key that the list has, with the owner's signed statement |
| `contact_roles` | waits (2.4) | |
| `connected_apps` | waits (2.4) | the Mac alone today: no device route |
| `connect_offer` | not planned | Turn on runs a root step over the Mac's SSH and takes a Tailscale access token, and `/ui/connect*` is no device route |

## What no feature name carries

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
