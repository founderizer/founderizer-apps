# Founderizer for Mac and iPhone

Founderizer runs always-on AI agents on servers that you own. A hub on one of your servers keeps the agents, their
tasks and their records. These two apps are how you work with them:

- **Founderizer for Mac** sets up a fleet and operates it.
- **Founderizer for iPhone** reads the fleet and answers it when you are not at your Mac.

The apps run no AI. They talk to your own hub on your private network (Tailscale), and the agents use your own
accounts with the AI providers.

The hub is a separate repository: <https://github.com/founderizer/founderizer>.

## What the Mac app does

- **Set up a fleet.** It makes a server at Hetzner Cloud, DigitalOcean, Vultr or Akamai, or takes a server that you
  already have, puts it on your private network and installs the hub. It adds more servers and always-on Macs later.
- **Chats.** One conversation with each agent, with files, and the requests that the agent asks you.
- **Needs you.** Each request that waits for your answer, and each task that only you can move.
- **Tasks.** A board of the fleet's work, and the thread of each task.
- **Agents.** Each agent with its role, its server, its AI account and its usage.
- **Settings.** General, Servers (with your own devices), Updates, Backup, System status, Secrets, Knowledge, Apps
  (GitHub, Google Drive, Gmail and MCP servers), People and Reporting lines.
- **Help › Report a problem.** It lists what the app can see is wrong, with the fix for each item.

The package also builds three helpers: the setup service (an XPC service inside the app), **Founderizer Installer**
(for a Mac that stays on and runs agents) and **Fleet Vault** (the helper that keeps secrets on a Mac).

## What the iPhone app does

- **Chats**, **Needs you** and **Tasks**, as on the Mac, in the system's light and dark appearance.
- You add the phone with a one-time code from the Mac app (Settings › Servers › Add device). The phone keeps its own
  key in the keychain, behind Face ID.
- A new request can ring the phone, with the request's options as buttons. The hub sends each notification, sealed
  with the phone's own key, through the relay at founderizer.com. That relay sends only to the builds that Amura
  Ventures SL publishes, so a build that you sign yourself gets no notification from it.

## What you need

- A Mac with macOS 15 or later, and an Xcode that has the macOS 26 and iOS 26 SDKs or later ones: the source uses
  their APIs behind availability checks. The tests pass with Xcode 27.2. The apps run on macOS 15 and iOS 18 or
  later.
- A checkout of the hub repository. The Mac app's setup service carries the hub's `onboard.py`.
- For Fleet Vault only: an Apple Developer ID.

## Build and run the Mac app

```sh
swift test
```

runs the unit tests of the shared code (`FleetCore`, `FleetMark`) and of the vault (`FleetVaultCore`). A few vault
tests need the `age` and `age-keygen` programs.

```sh
git clone https://github.com/founderizer/founderizer.git ../founderizer
FLEET_KIT_SOURCE=../founderizer ./run.sh
```

builds a release build, makes `build/Founderizer.app` with the setup service inside it, signs it ad hoc and opens it.
Quit a copy of the app that runs before you open a new build.

```sh
./installer.sh
```

builds `build/Founderizer Installer.app`, signed ad hoc.

`run.sh` and `installer.sh` are for a run on your own Mac. An app that other people download must have your own
Developer ID signature and Apple's notarization.

### Fleet Vault and the signing team

Fleet Vault keeps its items in a keychain group, and the app accepts only a vault that the publisher's Apple team
signed. The team identifier `6EBZ756H9Q` (Amura Ventures SL's team) is therefore part of the source: in
`Sources/FleetVaultCore`, `Sources/FleetVaultIPC`, `Vault/` and `ios/Sources/SealedPing.swift`. To ship builds of your
own, replace it with your team identifier in each of those places, and build the vault with your identity:

```sh
FLEET_SIGN_IDENTITY="Developer ID Application: Your Name (YOURTEAMID)" \
FLEET_VAULT_PROFILE=/path/to/your.provisionprofile python3 Vault/build.py
```

## Build and run the iPhone app

Open `ios/FleetMobile.xcodeproj` in Xcode, choose an iPhone simulator and run. Or from a terminal:

```sh
cd ios
xcodebuild -project FleetMobile.xcodeproj -scheme FleetMobile \
    -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=18.6' build
xcodebuild test -project FleetMobile.xcodeproj -scheme FleetMobile \
    -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=18.6'
```

Name a simulator that your Xcode has. The project uses the package in the repository's root as a local dependency.
For a build on your own iPhone, set your own team and bundle identifiers in the project's signing settings.

## What is where

| Path | What it is |
| --- | --- |
| `Package.swift` | The Swift package: the Mac app, its helpers and the code that both apps share. |
| `Sources/FleetCore` | The hub's API and each rule with no view. Both apps use it, and most tests are for it. |
| `Sources/FleetMark` | The marks of the agents, the brand and the providers. |
| `Sources/Founderizer` | The Mac app. |
| `Sources/FleetSetupService`, `Sources/FleetSetupIPC` | The setup service and its interface. |
| `Sources/FleetVault`, `Sources/FleetVaultCore`, `Sources/FleetVaultIPC`, `Vault/` | Fleet Vault, its interface, and its build, install and update scripts. |
| `Sources/FounderizerInstaller`, `Installer/` | The installer for an always-on Mac. |
| `ios/` | The iPhone app, its two notification extensions and its tests. |
| `Tests/` | The tests of the package. |
| `test-support/` | Local stand-ins for a hub and small probes, for checks of the app with no fleet. Each one says what it does at its head. |
| `UI-PATTERNS.md` | How each view of the Mac app is drawn. Read it before you change a view. |

## Licence

Founderizer is licensed under the Apache License, Version 2.0. See [`LICENSE`](LICENSE) and [`NOTICE`](NOTICE).

The name Founderizer and its logo belong to Amura Ventures SL, and the licence gives no right to use them (section 6).
You can say that your work is based on Founderizer. A changed copy that you share uses a different name and a
different logo.

The provider logos in `Sources/FleetMark`, the chat app marks and the GitHub mark are the marks of their owners. The
apps show them only to name each one. The chat app and cloud provider marks are Simple Icons paths (CC0). The GitHub
mark's path is from Octicons, under the MIT License; its notice stands beside it in
`Sources/Founderizer/LibraryPages.swift`.

## Changes from outside

Issues and pull requests are welcome. This repository is a copy that we publish from our own repository, so we do not
merge a pull request here. We apply its change to our repository, run the tests, and publish the next copy with it.
Then we close the pull request with a link to that copy. The commit of that copy names you as co-author, so GitHub
lists you as a contributor. Under section 5 of the licence, what you send is under the Apache License 2.0. Before you
send a change, run `swift test`.

## Credit

Created by Miguel Pieras, <https://x.com/mpieras>.

Copyright 2026 Amura Ventures SL.
