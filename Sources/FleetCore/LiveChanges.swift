import Foundation

/// **The hub says when something the owner sees changed, and the app reads at that moment** (owner feature
/// `live_changes`). The owner wants every result on his screen at once, and every screen used to read the hub on a
/// clock of its own, from 2 to 120 seconds, with nothing to wake a loop that slept after he acted. The hub now counts
/// its changes, and `GET /ui/wait?db=&since=&wait=` answers as soon as the count moves past the token the app holds,
/// or after `wait` seconds with the same token. The app keeps one watcher on it (`FleetStore`), and a wake asks for
/// the fleet's own state and wakes the pages that read the hub. Without the feature the app reads on its clocks, as
/// before.
///
/// The pure parts live here, so that a test can hold them: the token and what makes a wake (`LiveToken`), the cap
/// on wakes (`WakeCap`), the backoff after a failed wait (`WakeBackoff`, `LiveWatch`), the nap of a page loop
/// (`PageWakes`), the read that runs once more when it is asked for during a read (`RunAgain`), and the signal that
/// a write got its answer (`HubWrites`).
public enum LiveChanges {
    public static let feature = "live_changes"
    /// The longest wait the hub takes, and the one the watcher asks for.
    public static let wait = 20
    /// At most one wake-driven read of the state, and one wake of the pages, in this many seconds.
    public static let cap: TimeInterval = 2
    /// The fleet's own read of `/ui/state`.
    public static let poll: TimeInterval = 3

    /// How long the fleet's own read of `/ui/state` waits now. **Its interval counts from the last read, whoever ran
    /// it**, so a read that a wake asked for takes the place of the next one on the clock instead of adding one.
    /// `last` and `now` are seconds of one clock that only goes forward.
    public static func untilRead(after last: TimeInterval?, now: TimeInterval, every: TimeInterval = poll) -> TimeInterval {
        guard let last else { return 0 }
        return min(every, max(0, every - (now - last)))
    }
}

/// One token of the hub's change count, `<boot>.<state>.<activity>`: the hub's start, the changes that the owner
/// sees, and the changes nobody shows (log rows, thread records, usage readings).
public struct LiveToken: Equatable, Sendable {
    /// The token as the hub wrote it: what the next wait asks from.
    public let text: String
    public let boot: String
    public let state: UInt64
    public let activity: UInt64

    /// nil for anything that is not a token. The two counts are the last two parts, so a boot with a dot in it still
    /// reads; the boot is kept to characters that travel in a query as they are.
    public init?(_ text: String?) {
        guard let text, text.utf8.count <= 200 else { return nil }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 3, let state = Self.count(parts[parts.count - 2]),
              let activity = Self.count(parts[parts.count - 1]) else { return nil }
        let boot = parts.dropLast(2).joined(separator: ".")
        guard !boot.isEmpty, boot.unicodeScalars.allSatisfy({ Self.bootCharacters.contains($0) }) else { return nil }
        self.text = text
        self.boot = boot
        self.state = state
        self.activity = activity
    }

    /// **The wake**: another boot, or another state count. The activity count never wakes anything.
    public func wakes(since: LiveToken) -> Bool { boot != since.boot || state != since.state }

    /// A read of `/ui/state` with this token already shows what `other` says changed: the same boot, and a state count
    /// at least as high.
    public func covers(_ other: LiveToken) -> Bool { boot == other.boot && state >= other.state }

    private static let bootCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._:-")

    private static func count(_ part: Substring) -> UInt64? {
        guard !part.isEmpty, part.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        return UInt64(part)
    }
}

/// **At most one wake in `interval`, and the wakes inside it fold into one at its end.** A burst of changes — a task
/// that runs writes many — reads the state once and wakes the pages once, and the last change of the burst is still
/// read. Times are seconds of one clock that only goes forward.
public struct WakeCap: Sendable {
    public enum Answer: Equatable, Sendable {
        /// Wake now.
        case now
        /// Wake at this time, for this wake and every one that comes before it.
        case at(TimeInterval)
        /// A wake is already held for later, and it carries this one.
        case folded
    }

    public let interval: TimeInterval
    public private(set) var last: TimeInterval?
    public private(set) var held = false

    public init(interval: TimeInterval = LiveChanges.cap) { self.interval = interval }

    public mutating func wake(at now: TimeInterval) -> Answer {
        if held { return .folded }
        if let last, now - last < interval {
            held = true
            return .at(last + interval)
        }
        last = now
        return .now
    }

    /// The held wake went out.
    public mutating func fired(at now: TimeInterval) {
        held = false
        last = now
    }

    /// Another hub or another generation: nothing is held, and the next wake goes at once.
    public mutating func reset() {
        last = nil
        held = false
    }
}

/// How long the watcher waits after a wait that failed: 1, 2, 4, 8, 16 and then 30 seconds, each within a fifth of
/// its value either way so that two Macs of one owner do not ask together, and never under 1 or over 30.
public enum WakeBackoff {
    /// `jitter` is a draw between 0 and 1.
    public static func delay(failures: Int, jitter: Double) -> TimeInterval {
        guard failures > 0 else { return 0 }
        let base = min(30, pow(2, Double(min(failures, 6) - 1)))
        let spread = base * (0.8 + 0.4 * min(max(jitter, 0), 1))
        return min(30, max(1, spread))
    }
}

/// What the watcher holds between two waits: the token the next wait asks from, and the failures in a row.
public struct LiveWatch: Sendable {
    public private(set) var since: LiveToken
    public private(set) var failures = 0

    public init(from token: LiveToken) { since = token }

    /// What comes after one answer.
    public enum Step: Equatable, Sendable {
        /// Something changed: wake, and wait again at once.
        case wake
        /// Nothing changed in the whole wait: wait again at once.
        case wait
        /// Nothing changed, and the answer came back at once: wait this long before the next wait.
        case pause(TimeInterval)
    }

    /// One answer of `/ui/wait`, which took `seconds`. The next wait asks from this newest token whatever it says. A
    /// wake or a wait that was held ends the backoff. **An answer with nothing new that came back at once is no wait
    /// at all** — a hub that does not hold the wait — so it counts as a failure, and the watcher never asks such a hub
    /// in a tight loop.
    public mutating func answered(_ token: LiveToken, took seconds: TimeInterval, jitter: Double) -> Step {
        let wakes = token.wakes(since: since)
        since = token
        if wakes {
            failures = 0
            return .wake
        }
        guard seconds >= 1 else { return .pause(failed(jitter: jitter)) }
        failures = 0
        return .wait
    }

    /// One wait that failed: how long to wait before the next one.
    public mutating func failed(jitter: Double) -> TimeInterval {
        failures += 1
        return WakeBackoff.delay(failures: failures, jitter: jitter)
    }
}

/// What one wait said.
public enum LiveAnswer: Equatable, Sendable {
    /// The hub's token now: past the one asked from, or the same one after the wait.
    case token(LiveToken)
    /// The hub has another generation now, which only a read of the state learns.
    case generationChanged
}

/// `GET /ui/wait` (owner feature `live_changes`), on a session of its own: a wait is held open by the hub for up to 20
/// seconds, longer than the shared session lets any request take.
public final class LiveChangesClient: Sendable {
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 40
        return URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }()

    public init() {}

    /// One wait: it comes back when the hub's boot or state count is past `since`, or after `seconds`. A generation that
    /// changed answers as every other `/ui/*?db=` read does, with 409, and so does an answer for another generation.
    /// `key` is an owner device's own key, which the phone sends on every call; the Mac is known by its address and
    /// sends none.
    public func wait(hub: URL, database: String, since: LiveToken,
                     seconds: Int = LiveChanges.wait, key: String? = nil) async throws -> LiveAnswer {
        var parts = URLComponents(url: hub.appendingPathComponent("ui/wait"), resolvingAgainstBaseURL: false)!
        parts.queryItems = [.init(name: "db", value: database), .init(name: "since", value: since.text),
                            .init(name: "wait", value: String(min(max(seconds, 0), LiveChanges.wait)))]
        var request = URLRequest(url: parts.url!)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let key, !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await Self.session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw HubError.invalidResponse }
        if response.statusCode == 409 { return .generationChanged }
        guard response.statusCode == 200 else { throw HubError.refusal(response.statusCode, HubClient.words(in: data)) }
        guard data.count <= 4096, let answer = try? JSONDecoder().decode(Answer.self, from: data) else {
            throw HubError.invalidResponse
        }
        guard answer.db == database else { return .generationChanged }
        guard let token = LiveToken(answer.token) else { throw HubError.invalidResponse }
        return .token(token)
    }

    private struct Answer: Decodable {
        let db: String
        let token: String
    }
}

/// **The page loops' one alarm clock.** A loop that reads the hub naps between two reads instead of sleeping: the nap
/// ends at its time, or at the first wake that comes after it began. A wake ends every nap that is on at that moment,
/// each one once; a nap that begins later waits for the next wake.
@MainActor
public final class PageWakes {
    private var naps: [Int: CheckedContinuation<Bool, Never>] = [:]
    private var timers: [Int: Task<Void, Never>] = [:]
    private var last = 0
    /// The wakes so far.
    public private(set) var wakes = 0

    public init() {}

    /// The naps that are on now.
    public var napping: Int { naps.count }

    /// Returns after `seconds`, or as soon as a wake comes after this call: true for a wake. It throws when its task
    /// is cancelled, as `Task.sleep` does, so a loop that slept keeps its shape.
    @discardableResult
    public func nap(_ seconds: Double) async throws -> Bool {
        try Task.checkCancellation()
        last += 1
        let id = last
        let woken = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                naps[id] = continuation
                timers[id] = Task {
                    try? await Task.sleep(for: .seconds(max(0, seconds)))
                    guard !Task.isCancelled else { return }
                    self.end(id)
                }
            }
        } onCancel: {
            Task { @MainActor in self.end(id) }
        }
        try Task.checkCancellation()
        return woken
    }

    /// Ends every nap that is on now.
    public func wake() {
        wakes += 1
        let ending = naps
        naps = [:]
        for (id, continuation) in ending {
            timers.removeValue(forKey: id)?.cancel()
            continuation.resume(returning: true)
        }
    }

    private func end(_ id: Int) {
        timers.removeValue(forKey: id)?.cancel()
        naps.removeValue(forKey: id)?.resume(returning: false)
    }
}

/// **A read that is asked for while it runs runs once more, and is never dropped.** The fleet's state used to be read
/// only when no read was on its way: a read asked for after a write, while the clock's read of the moment before was
/// still out, came back at once with nothing, and the write's result waited for the next clock. Now a call during a
/// run marks that the run goes once more when it ends, and waits for that one; the calls during one run share the one
/// more. Every caller passes the same work.
@MainActor
public final class RunAgain {
    private var running = false
    private var again = false
    private var started = 0
    private var waiting: [(run: Int, continuation: CheckedContinuation<Void, Never>)] = []

    public init() {}

    public var isRunning: Bool { running }

    /// Runs `body`, or, while a run is on its way, waits for a run that begins after this call.
    public func run(_ body: @MainActor () async -> Void) async {
        guard !running else {
            again = true
            let run = started + 1
            await withCheckedContinuation { waiting.append((run, $0)) }
            return
        }
        running = true
        repeat {
            again = false
            started += 1
            await body()
            let ended = started
            let done = waiting.filter { $0.run <= ended }
            waiting.removeAll { $0.run <= ended }
            for waiter in done { waiter.continuation.resume() }
        } while again
        running = false
    }
}

/// **A write of this app got its answer.** Every client of the hub notes it when a POST comes back with an answer of
/// any kind, so the screens read at once what the owner's own action did — one place for every write, and not a line
/// in each view. It is the owner's own action, so nothing holds it back.
public enum HubWrites {
    public static let answered = Notification.Name("FleetCore.HubWrites.answered")

    static func note(_ request: URLRequest, center: NotificationCenter = .default) {
        guard request.httpMethod == "POST" else { return }
        center.post(name: answered, object: nil)
    }
}
