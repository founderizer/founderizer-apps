import AppKit
import FleetCore
import Foundation
import os

/// **A GitHub App of the owner's own, made from a Needs-you item** (DevOps plan 13, item 4, and plan 2.20; the
/// customer's path of PRODUCT.md 4.6; the coordinator, 6 November 2026: "no new element in our app; the manager raises
/// one Needs-you item ...; the key goes straight to the door with the app's own signed grant, and the App ID goes to the
/// hub; nothing else from him").
///
/// The hub tells the manager about an account where agents hold repositories and that no App of the door reaches, and
/// the manager raises one item that names it (`OwnerNeed.github_app`). His press of its first option on this Mac opens
/// GitHub's own page that makes a private App there with its permissions filled in (`GitHubManifest`). GitHub returns
/// to this Mac's loopback page with a one-time code, this Mac trades it for the App and its key, and the browser goes
/// on to GitHub's page that installs the App, where he chooses the account's repositories. The key goes to the door as
/// the GitHub App rows' Save gives one (`DoorKeys.put`, with the grant that this Mac signs), the door's file names it
/// for that account, and the hub gets the App's ID. Nothing of Founderizer's shows, and the key is in memory only.
@MainActor
enum GitHubManifestFlow {
    private nonisolated static let log = Logger(subsystem: "com.founderizer.app", category: "github-app")
    /// One flow for each account at a time: a second press takes the first one's place.
    private static var listeners: [String: GitHubManifestListener] = [:]

    /// The owner pressed the first option of an item that names this account. A fleet with no door, a hub without
    /// `door_setup`, or an account whose App the door holds already, starts nothing.
    static func start(owner: String, store: FleetStore) async {
        guard GitHubManifest.isLogin(owner), store.state?.ui_features?.contains(DoorSetupClient.feature) == true,
              let database = store.state?.db, await DoorKeys.hasDoor(store) else {
            log.notice("No GitHub App flow: this fleet has no door, or its hub does not take one.")
            return
        }
        let key = owner.lowercased()
        if let view = try? await DoorSetupClient().view(hub: store.hub, database: database), view.github_apps?[key] != nil {
            log.notice("The door holds the GitHub App of \(owner, privacy: .public) already.")
            return
        }
        let account: GitHubManifest.Account
        do {
            account = try await GitHubManifest.account(owner)
        } catch {
            log.error("GitHub did not name the account \(owner, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return
        }
        let state = GitHubManifest.random(bytes: 24)
        let fallback = GitHubManifest.appsPage(owner: account.login, organization: account.isOrganization)
        listeners[key]?.stop()
        let flow = GitHubManifestListener(state: state) { code in
            do {
                let app = try await GitHubManifest.convert(code: code)
                Task { @MainActor in await Self.keep(app, store: store, database: database) }
                return GitHubManifest.installPage(slug: app.slug) ?? fallback
            } catch {
                Self.log.error("GitHub did not give the new App: \(error.localizedDescription, privacy: .public)")
                return fallback
            }
        }
        let port: UInt16
        do {
            port = try flow.start()
        } catch {
            log.error("The GitHub App flow could not listen on this Mac's loopback address.")
            return
        }
        guard let redirect = URL(string: "http://127.0.0.1:\(port)/done"),
              let manifest = try? GitHubManifest.manifest(owner: account.login, redirect: redirect,
                                                          suffix: GitHubManifest.random(bytes: 2)),
              let open = URL(string: "http://127.0.0.1:\(port)/start") else {
            flow.stop()
            return
        }
        flow.serve(GitHubManifest.startPage(action: GitHubManifest.newAppPage(owner: account.login,
                                                                              organization: account.isOrganization,
                                                                              state: state), manifest: manifest))
        listeners[key] = flow
        NSWorkspace.shared.open(open)
    }

    /// The key to the door, its name in the door's file for the account, and the App's ID to the hub: each step tried
    /// three times, because GitHub gives the key once.
    private static func keep(_ app: GitHubManifest.Made, store: FleetStore, database: String) async {
        let owner = app.owner.login, appID = String(app.id)
        let made = DoorKeyReference.make()      // one for the three tries: a failed try leaves no second catalog entry
        guard let reference = await tries({ () async throws -> String in
            _ = try await GitHubAppKey.app(appID: appID, pem: app.pem)
            return try await DoorKeys.put(GitHubAppKey.vaultValue(app.pem), variable: GitHubAppKey.variable(owner: owner),
                                          store: store, reference: made)
        }) else {
            log.error("The new GitHub App \(appID, privacy: .public) of \(owner, privacy: .public) did not go to the door.")
            return
        }
        guard await tries({ () async throws -> Bool in
            if let problem = await store.doorModel().addGitHubApp(owner: owner, login: reference, appID: appID) {
                throw DoorKeys.Stop(problem)
            }
            return true
        }) != nil, await tries({ () async throws -> Bool in
            try await DoorSetupClient().recordApp(hub: store.hub, database: database, client: store.installation,
                                                  owner: owner, appID: appID)
            return true
        }) != nil else {
            log.error("The door's file or the hub did not take the new GitHub App \(appID, privacy: .public).")
            return
        }
        log.notice("The door holds the new GitHub App \(appID, privacy: .public) of \(owner, privacy: .public).")
    }

    private static func tries<T>(_ step: () async throws -> T) async -> T? {
        for attempt in 1...3 {
            do { return try await step() } catch {
                log.error("Attempt \(attempt) of a GitHub App step: \(error.localizedDescription, privacy: .public)")
                if attempt < 3 { try? await Task.sleep(nanoseconds: 5_000_000_000) }
            }
        }
        return nil
    }
}
