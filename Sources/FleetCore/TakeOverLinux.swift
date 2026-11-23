import Foundation

/// **Take over for an agent on a Linux server** (build plan 04, S6; owner feature `takeover_linux`, UI-API.md 1.225).
/// The card's Take over opens the screen of the agent's own browser on its server: his press asks the hub
/// (`TakeOverClient.takeOverScreen`), whose answer is the agent's screen-sharing port and a one-time password of 8 letters
/// and digits; this Mac opens its own SSH tunnel to that port as root (`ScreenSharingConnection.linux`) and Screen
/// Sharing at an address with the password in it (`viewerAddress`), so that Screen Sharing asks nothing. The password is
/// in memory only: no log line, no file and no record of the app holds it.
public enum TakeOverLinux {
    /// The owner feature of the hub's route.
    public static let feature = "takeover_linux"
    /// The helper feature of the step that opens and closes the agent's screen.
    public static let helperFeature = "takeover_screen"

    /// Whether the agent's helper can open its screen: its machine's reading, as the hub judged it when the app read it
    /// (`stale`), names a helper that reported and does the step. With no helper online the card has no Take over, and
    /// he answers in words. No clock of the app's own: a card that stays on screen keeps its Take over, as a Mac's does,
    /// and the hub refuses a press for a helper that went away since (`takeover_no_screen`).
    public static func helperReady(_ machine: MachineStatus?) -> Bool {
        guard let machine, machine.reported_at != nil, machine.stale != true else { return false }
        return machine.features?.contains(helperFeature) == true
    }
    /// How long his press waits for the hub, which waits up to 20 seconds for the agent's server.
    public static let wait: TimeInterval = 40

    /// **Whether `agent` runs on a Linux server**: the hub's servers list says so, or the system that its machine's
    /// reading names (`MachineStatus.os.name`) is not macOS. Such an agent has only the way to its own browser's
    /// screen: a Screen Sharing way that team.json names for its server goes to that server's 5900, which no password
    /// and no rule of the server guard.
    public static func onLinuxServer(_ agent: String, servers: [ServerEntry]?, systemName: String?) -> Bool {
        if servers?.contains(where: { $0.kind == "linux" && $0.agents.contains(agent) }) == true { return true }
        return systemName.map { !$0.hasPrefix("macOS") } ?? false
    }
}

/// The hub's answer to one press (`POST /ui/needs/<id>/takeover`).
public struct TakeOverScreen: Decodable, Equatable, Sendable {
    public let agent: String
    public let server: String
    public let port: Int
    public let password: String

    public init(agent: String, server: String, port: Int, password: String) {
        self.agent = agent; self.server = server; self.port = port; self.password = password
    }

    /// A port of the agents' screen-sharing range and a password of 8 letters and digits, the most that a VNC password
    /// holds.
    public var isValid: Bool {
        ServerBrowser.screenPorts.contains(port) && TakeOverScreen.passwordShape(password)
    }

    static func passwordShape(_ password: String) -> Bool {
        password.range(of: "^[A-Za-z0-9]{8}$", options: .regularExpression) != nil
    }

    /// Whether this is the screen that the press's tunnel reaches: its agent, its server and its port. A server's
    /// ports are its own, so another server's agent can hold the same number.
    public func opens(agent: String, server: String?, port: Int) -> Bool {
        self.agent == agent && server != nil && self.server == server && self.port == port
    }
}

/// The one route of a Linux take-over, on a session of its own: the hub waits up to 20 seconds for the agent's server,
/// longer than the app's other reads wait (`HubClient`).
public final class TakeOverClient: Sendable {
    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = TakeOverLinux.wait
        configuration.timeoutIntervalForResource = TakeOverLinux.wait + 5
        session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }

    /// **His press of Take over on a Linux agent's item**: the hub has the agent's helper start the sharing of its
    /// screen with a new one-time password, and answers with the port and the password. A refusal is
    /// `HubError.refusal` with its code (UI-API.md 1.225), whose words the card's line shows.
    public func takeOverScreen(hub: URL, database: String, need: Int, client: String) async throws -> TakeOverScreen {
        var request = URLRequest(url: hub.appendingPathComponent("ui/needs/\(need)/takeover"))
        request.httpMethod = "POST"
        request.timeoutInterval = TakeOverLinux.wait
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(client, forHTTPHeaderField: "X-Fleet-Client")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["db": database])
        let (data, response) = try await session.hubData(for: request)
        HubWrites.note(request)
        guard let response = response as? HTTPURLResponse else { throw HubError.invalidResponse }
        guard response.statusCode == 200 else { throw HubError.refusal(.read(status: response.statusCode, body: data)) }
        guard data.count <= 4096, let screen = try? JSONDecoder().decode(TakeOverScreen.self, from: data),
              screen.isValid else { throw HubError.invalidResponse }
        return screen
    }
}

extension ServerEntry {
    /// **The screen-sharing port of `agent` on this Linux server**, as the server's own reading names it (owner API
    /// 1.224): the parts ready, and the row of the ports file of the OS user that the agent runs as. nil otherwise.
    public func screenPort(of agent: String) -> Int? {
        guard kind == "linux", agents.contains(agent), let reading, reading.browser?.state == "ready",
              let user = reading.agents?.users[agent]?.user else { return nil }
        return reading.browser?.ports?.first(where: { $0.user == user }).map(\.screen)
            .flatMap { ServerBrowser.screenPorts.contains($0) ? $0 : nil }
    }
}

extension ScreenSharingConnection {
    /// **The tunnel to an agent's screen on its Linux server**: this Mac's own record of the server (`target`), to the
    /// agent's screen-sharing port there. Only as root: the port rule of the server (D11) lets root and the server's
    /// worker user reach that port, and a user who becomes root with `sudo` would be refused there. nil otherwise.
    public static func linux(target: InstallTarget, port: Int, agent: String) -> ScreenSharingConnection? {
        guard target.user == "root", !target.becomeRoot else { return nil }
        let way = ScreenSharingConnection(address: target.host, user: target.user, port: target.port, remotePort: port,
                                          identityFile: target.identityFile, agent: agent,
                                          portGivenFor: target.portGivenFor)
        return way.isValid ? way : nil
    }

    /// **The address that Screen Sharing opens** for the tunnel at `localPort` to this agent's screen on a Linux
    /// server: its one-time password, with which Screen Sharing asks for nothing (probe 2: with no password it asks
    /// for one), and a user of its own, `takeover-<agent>` (`vnc://takeover-<agent>:<password>@127.0.0.1:<port>`; no
    /// account of the fleet has that name, unlike `fleet-<agent>`), so that Screen Sharing should take no sign-in that
    /// it keeps for 127.0.0.1, which can be another Mac's and which a server of the agent's own on that port could ask
    /// for (x11vnc reads no user; measured on 19 and 20 November 2026 on one Mac: Screen Sharing used only this
    /// address's password, and its user where the server asks for one, never the kept sign-in, also with a server that
    /// took Apple's older sign-in after Screen Sharing's warning or refused the first sign-in; the hub's SECURITY.md
    /// says what was not measured). A Mac's own screen opens at `screenSharingAddress`, as the machine's own user. nil
    /// for a way that names no agent, or a password that is not of the shape that the hub gives.
    public func viewerAddress(localPort: Int, password: String) -> URL? {
        guard isValid, let agent, (1024...65535).contains(localPort), TakeOverScreen.passwordShape(password) else {
            return nil
        }
        var parts = URLComponents()
        parts.scheme = "vnc"; parts.user = "takeover-" + agent; parts.password = password
        parts.host = "127.0.0.1"; parts.port = localPort
        return parts.url
    }
}

/// **What the first line of a screen's program says about it** (the owner's yes of 20 November 2026 to this guard and
/// to its words, after S6's live check; the hub's SECURITY.md). A Linux agent's screen is its own `x11vnc`, which
/// greets with version 3.8 of the protocol: the tunnel helper reads the 12 bytes of the greeting before Screen Sharing
/// opens, and the relay reads them again on each of Screen Sharing's own connections (`ScreenRelay`), so Apple's
/// greeting, the measured way to Screen Sharing's warning "could not verify the authenticity", or any other greeting
/// no longer reaches Screen Sharing from an agent's port. What a program that greets as `x11vnc` does can do after its
/// greeting is not checked here (the hub's SECURITY.md). A Mac's own screen is not checked: any whole greeting of the
/// protocol opens it, as before this guard (the owner's "Drop the Mac half").
public enum ScreenGreeting: Equatable, Sendable {
    /// The program that should answer there: Screen Sharing opens.
    case expected
    /// Fewer than 12 bytes came (or, on a Mac, no greeting of the protocol): the screen did not answer, as before.
    case none
    /// 12 bytes on a Linux agent's screen that are not x11vnc's greeting: another program, and Screen Sharing stays
    /// closed.
    case foreign

    /// The helper's answer for `foreign`, which the app says in the owner's words
    /// (`ScreenSharingConnection.failureWords`).
    public static let foreignDetail = "screen-greeting-foreign"
    /// The greeting of a Linux agent's `x11vnc`: version 3.8, the only one that the fleet's `x11vnc` sends
    /// (`fleet.vnc_arguments` names no other; x11vnc 0.9.16 with libvncserver 0.9.14 greeted so through SSH on 20
    /// November 2026) and the only one measured.
    static let linux: Set<String> = ["RFB 003.008\n"]
}

extension ScreenSharingConnection {
    /// What the first 12 bytes of this screen's program say about it (`ScreenGreeting`): a Linux agent's screen
    /// (`agent` set) must greet as `x11vnc` does; a Mac's own screen opens for any whole greeting of the protocol, as
    /// before.
    public func greeting(_ banner: [UInt8]) -> ScreenGreeting {
        guard banner.count == 12 else { return .none }
        guard agent != nil else {
            return banner.starts(with: Array("RFB ".utf8)) && banner.last == 10 ? .expected : .none
        }
        return ScreenGreeting.linux.contains(String(decoding: banner, as: UTF8.self)) ? .expected : .foreign
    }

    /// What the owner reads when Screen Sharing did not open this screen: the tunnel helper's own sentence, or, for a
    /// Linux agent's screen whose program is not the one that should answer there (`ScreenGreeting.foreignDetail`), the
    /// words that the owner approved.
    public func failureWords(_ detail: String) -> String {
        guard detail == ScreenGreeting.foreignDetail, agent != nil else {
            return detail.isEmpty || detail == ScreenGreeting.foreignDetail
                ? String(l10n: "Screen Sharing could not connect.") : detail
        }
        return String(l10n: "Another program answered on this agent's screen, so Screen Sharing did not open it. Do not press Take over again: stop the agent's task, and treat the logins of its browser as exposed.")
    }
}
