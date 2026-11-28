import FleetCore
import SwiftUI

/// The fleet and the last answered local write when a page began its read.
@MainActor final class PageReadStart {
    fileprivate let context: String
    fileprivate let writes: Int
    fileprivate var at: ContinuousClock.Instant
    /// The read to the hub whose answer this start got (`PageReply.read`): the same for every caller that joined it.
    fileprivate var read: UUID?

    fileprivate init(context: String, writes: Int, at: ContinuousClock.Instant) {
        self.context = context
        self.writes = writes
        self.at = at
    }
}

/// Every waiter gets the original request time, including when the read fails, and the read's own mark (`read`): one
/// for each read to the hub, which every caller that joined it gets (`FleetStore.peopleReadFailed`).
private struct PageReply: Sendable {
    let started: ContinuousClock.Instant
    let result: Result<any Sendable, Error>
    let read = UUID()
}

/// **What each page read last, kept by the store, so a page that opens again draws it in its first frame** and reads
/// again at once.
///
/// The owner, 28 October 2026: "Now we have loading screens that just blink because data appears very quickly". Each
/// page kept its reading in its own `@State`, which is empty at every visit, so every visit drew "Reading the …" and a
/// spinner for the 20–370 ms its read took, then the rows (measured on his Mac at 60 frames a second: Servers 224 ms,
/// Updates 221, People 171). The pages that draw from the store's `/ui/state` — the Dashboard, Activity, Agents — were
/// whole in their first frame. Now a page's reading is kept here under the page's own name, for one hub address and one
/// hub generation, as the agents' Settings are (`FleetStore.settingsModel`): a reading of another hub or generation is
/// never drawn.
@MainActor final class PageReadings {
    /// One kept reading. Each is observed on its own, so a page draws again for its own readings and for no other.
    @MainActor @Observable fileprivate final class Slot {
        var context = ""
        var value: Any?
        /// When it was kept.
        var at: ContinuousClock.Instant?
        var started: ContinuousClock.Instant?
        var answeredWrites: Int?
        /// The same reading, which a view reads with no watch (`FleetStore.quietReading`).
        @ObservationIgnored var quiet: (context: String, value: Any?) = ("", nil)
    }

    private var slots: [String: Slot] = [:]
    private var models: [String: AnyObject] = [:]
    /// The reads of a page reading that are on their way, by the reading's name and context (`FleetStore.read`).
    fileprivate let reads: PageReads

    init(center: NotificationCenter) {
        reads = PageReads(center: center)
    }

    /// The hub generation, and the agents of it, whose readings were read before their pages opened.
    private var prefetched: Set<String> = []
    /// When the live readings were last asked for, and whether that round is on its way (`FleetStore.keepLive`).
    fileprivate var liveAsked: ContinuousClock.Instant?
    fileprivate var liveRound = false
    /// The failed reads of the People page's reading, by its context (`FleetStore.readPeopleAgain`): a refusal (4xx)
    /// stops its reads again at once, any other failure after `againMost`.
    fileprivate var peopleFailed: [String: Int] = [:]
    static let againMost = 3
    /// The reads of the People page's reading by the store that are on their way, by context: the launch's, a chat's
    /// and one again (`FleetStore.readPeopleAgain`). A count, so the first that ends keeps the mark of the others.
    fileprivate var peopleReading: [String: Int] = [:]
    /// The failed reads of the People page's reading to the hub that counted, by context (`peopleFailed`): the callers
    /// that joined one read get its mark (`PageReply.read`), so its failure counts once. Empty when a read answers.
    fileprivate var peopleCounted: [String: Set<UUID>] = [:]
    /// How many reads again of the People page's reading the store started, in all (`FleetStore.readPeopleAgain`).
    fileprivate var peopleReadsAgain = 0
    /// The task threads that are read before they open, by their reading's context and name (`FleetStore.prefetchTask`).
    fileprivate var taskReads: Set<String> = []

    fileprivate func value<Value>(_ name: String, in context: String) -> Value? {
        let slot = slot(name)
        return slot.context == context ? slot.value as? Value : nil
    }

    fileprivate func set(_ value: Any?, _ name: String, in context: String, from start: PageReadStart? = nil) {
        let slot = slot(name)
        if slot.context != context { slot.context = context }
        slot.value = value
        slot.at = .now
        slot.started = start?.at ?? slot.at
        slot.answeredWrites = start?.writes
        slot.quiet = (context, value)
    }

    fileprivate func accepts(_ start: PageReadStart, for name: String, in context: String) -> Bool {
        guard start.context == context, start.writes == reads.answeredWrites else { return false }
        guard let slot = slots[name], slot.context == context, let previous = slot.started else { return true }
        return previous <= start.at
    }

    fileprivate func quietValue<Value>(_ name: String, in context: String) -> Value? {
        guard let quiet = slots[name]?.quiet, quiet.context == context else { return nil }
        return quiet.value as? Value
    }

    fileprivate func age(_ name: String, in context: String) -> Duration? {
        kept(name, in: context).map { ContinuousClock.now - $0 }
    }

    fileprivate func kept(_ name: String, in context: String) -> ContinuousClock.Instant? {
        let slot = slot(name)
        return slot.context == context && slot.value != nil ? slot.at : nil
    }

    /// A first visit to a chat may reuse a fleet answer as recent as a normal page refresh.
    fileprivate func canReuse(_ name: String, in context: String, at now: ContinuousClock.Instant) -> Bool {
        guard let slot = slots[name], slot.context == context, slot.value != nil, let at = slot.at,
              slot.answeredWrites == reads.answeredWrites else { return false }
        return now - at < .seconds(LiveReadings.every)
    }

    /// True the first time it is asked for this hub generation (or this agent of it), so its readings are read once.
    fileprivate func firstPrefetch(_ key: String) -> Bool { prefetched.insert(key).inserted }

    /// The model of a page that keeps its readings in a model of its own. The models of another hub or generation go
    /// when the first one of this generation is made.
    fileprivate func model<Model: AnyObject>(_ name: String, in context: String, make: () -> Model) -> Model {
        let key = context + "\n" + name
        if let model = models[key] as? Model { return model }
        models = models.filter { $0.key.hasPrefix(context + "\n") }
        let model = make()
        models[key] = model
        return model
    }

    private func slot(_ name: String) -> Slot {
        if let slot = slots[name] { return slot }
        let slot = Slot()
        slots[name] = slot
        return slot
    }
}

extension FleetStore {
    /// The hub address and hub generation that a kept reading belongs to.
    private var readingContext: String { hub.absoluteString + "\n" + (state?.db ?? "") }

    /// What the page reading `name` read last on this hub generation, or nil before its first answer. A page draws
    /// this in its first frame and reads again at once: it never empties it when it opens.
    func reading<Value>(_ name: String) -> Value? { readings.value(name, in: readingContext) }

    /// **The same reading, with no watch**: a view that reads it is not drawn again when the reading comes again. A
    /// chat's badges read the Servers page's reading so, which the live round writes every 15 seconds
    /// (`FleetStore.chatNames`).
    func quietReading<Value>(_ name: String) -> Value? { readings.quietValue(name, in: readingContext) }

    /// Keeps a page's reading under its name, for this hub generation. A reading of the servers first moves what this
    /// Mac keeps under the name of a server that it lists under a new name (`followRenames`). The health and the
    /// releases also go to disk with the fleet's (`keepForNextLaunch`).
    func keep(_ value: Any?, as name: String) {
        if let list = value as? ServerList { followRenames(from: reading(name), to: list) }
        readings.set(value, name, in: readingContext)
        if let health = value as? FleetHealth { keepForNextLaunch(health, as: "health") }
        if let releases = value as? ReleaseState { keepForNextLaunch(releases, as: "releases") }
    }

    func pageReadStart() -> PageReadStart {
        PageReadStart(context: readingContext, writes: readings.reads.answeredWrites, at: .now)
    }

    func canReuseFleetReading(_ name: String, at now: ContinuousClock.Instant = .now) -> Bool {
        readings.canReuse(name, in: readingContext, at: now)
    }

    func acceptsPageRead(_ start: PageReadStart, for name: String) -> Bool {
        !Task.isCancelled && readings.accepts(start, for: name, in: readingContext)
    }

    /// A reply to a fleet read cannot replace a newer reply or the result of a save.
    @discardableResult func keep(_ value: any Sendable, as name: String, from start: PageReadStart) -> Bool {
        guard acceptsPageRead(start, for: name) else { return false }
        readings.set(value, name, in: readingContext, from: start)
        return true
    }

    func readingDate(_ name: String) -> Date? {
        readings.age(name, in: readingContext).map { Date().addingTimeInterval(-Self.seconds($0)) }
    }

    /// **The page shows a kept reading that this visit has not read again yet.** A page that opened at `opened`
    /// marks such a reading as its last one once a second has gone by (`Held`): until then its read is on its way and
    /// the reading is not old yet, so no warning shows for the 200 ms that read takes.
    func readingWaits(_ name: String, since opened: ContinuousClock.Instant) -> Bool {
        readings.kept(name, in: readingContext).map { $0 < opened } ?? false
    }

    /// When the page reading `name` was kept on this hub generation, or nil without one.
    func readingKept(_ name: String) -> ContinuousClock.Instant? { readings.kept(name, in: readingContext) }

    /// **A page's own reading shows as its last one** (`StateReading.pageReadingIsOld`): while the fleet's state is
    /// old, or once the page's own reads have failed for one whole break since `failedSince`, the first of them in a
    /// row. The clock of the held lines draws the page again at the moment that break ends (`QuietClock`). Reads that
    /// failed before the Mac last slept count from its wake (`wokeAt`): a Mac that wakes starts no break.
    func pageReadingIsOld(failedSince: ContinuousClock.Instant?) -> Bool {
        if let start = StateReading.failingStart(since: failedSince, wokeAt: wokeAt) {
            // Asked, so that the page draws again when the break ends.
            _ = QuietClock.shared.passed(start + .seconds(StateReading.limit))
        }
        let failingFor = StateReading.failingFor(since: failedSince, wokeAt: wokeAt, now: .now)
        return StateReading.pageReadingIsOld(stateIsCurrent: isFresh, failingFor: failingFor)
    }

    /// **A page's own reads have failed one whole break** since `failedSince`, whatever the fleet's state: a page that
    /// reads again only for one break stops then, and says that it could not read (an agent's Memory, the reporting
    /// lines). On the fleet's state too it would stop at the third failed state read of a release restart, and say
    /// the failure for good after the hub came back.
    func pageReadsFailedABreak(failedSince: ContinuousClock.Instant?) -> Bool {
        (StateReading.failingFor(since: failedSince, wokeAt: wokeAt, now: .now) ?? 0) >= StateReading.limit
    }

    /// **One read of a page reading at a time** (the fix round of 29 October 2026): every list that draws the reading
    /// `name` reads it through here, and a read that is asked for while one is on its way gets that one's answer.
    /// Settings › Apps draws one reading of the resources in four lists, and each list read it for itself: eight reads
    /// of `/ui/resources` in 0.6 s as the page opened. Nothing is kept here; the caller keeps what it read.
    func read<Value: Sendable>(_ name: String, from start: PageReadStart? = nil, _ read: @escaping @Sendable () async throws -> Value) async throws -> Value {
        // Never one that began before a write of this Mac was answered (`PageReads`, review A7).
        let origin = start?.at ?? .now
        let reply = try await readings.reads.read(readingContext + "\n" + name) {
            do { return PageReply(started: origin, result: .success(try await read())) }
            catch { return PageReply(started: origin, result: .failure(error)) }
        }
        if let start { start.at = min(start.at, reply.started); start.read = reply.read }
        guard let value = try reply.result.get() as? Value else { throw HubError.invalidResponse }
        return value
    }

    /// The model of a page that reads through a model of its own (`UpdatesModel`), kept as its readings are.
    func pageModel<Model: AnyObject>(_ name: String, make: () -> Model) -> Model {
        readings.model(name, in: readingContext, make: make)
    }

    /// **A first reading that comes just after the loading line showed waits until the line has stood half a
    /// second**, so the line never blinks: shown at one second, it stays until one and a half. A reading that comes
    /// inside the first second, when no line showed, goes at once. **The half second counts from the frame the line
    /// first drew** (fix round 3, item 14): it counted from the read's start, and a line that drew a few frames after the
    /// second stood 476 and 491 ms.
    func settle(since start: ContinuousClock.Instant) async {
        guard ContinuousClock.now - start > LoadingLine.quiet else { return }
        var until = start + LoadingLine.quiet + LoadingLine.stands
        while true {
            if let shown = LoadingLine.shownAt, shown >= start { until = max(until, shown + LoadingLine.stands) }
            guard ContinuousClock.now < until else { return }
            do { try await Task.sleep(until: until, clock: .continuous) } catch { return }
        }
    }
}

/// **What a page says about a reading that is being read again, only once that read has had a second** — its
/// old-reading line, its warning. A read that answers inside the second takes the reason for it away, and nothing
/// came and went (the loading contract, C4.4: the orange "No current machine reading" stood 222 ms on the owner's Mac
/// while the read that cleared it was on its way).
///
/// Until its second is over it is nothing at all, and a modifier on it applies to nothing: a line that must keep its
/// room meanwhile keeps it outside (Updates' "Checking…").
struct Held<Content: View>: View {
    /// When the wait began: the visit's start for a kept reading, nil for a wait that began as this showed (a check
    /// that runs, a save on its way).
    let since: ContinuousClock.Instant?
    let content: Content
    /// When this came, for a wait that began as it showed.
    @State private var came = ContinuousClock.now

    init(since: ContinuousClock.Instant? = nil, @ViewBuilder content: () -> Content) {
        self.since = since; self.content = content()
    }

    var body: some View {
        if QuietClock.shared.passed((since ?? came) + LoadingLine.quiet) { content }
    }
}

/// **The clock of the held lines** (`Held`): it moves at each moment that a held line waits for, so the line draws in
/// the frame its second ends. A held line cannot wait in a task of its own: while it shows nothing it is no view, and
/// a task on no view never runs. Every held line stayed away for good (fix round 2, item 97: the manager's setup
/// stood empty for 1.7 s after "Checking your fleet", and its "Setting up Manager" never came).
@MainActor @Observable final class QuietClock {
    static let shared = QuietClock()
    /// The moment of the last wake.
    private var now = ContinuousClock.now
    /// The moments a wake is set for.
    @ObservationIgnored private var wakes: Set<ContinuousClock.Instant> = []

    /// True once `moment` has passed. Until then the clock wakes at `moment`, once for every line that waits for it,
    /// and a view that asked draws again.
    func passed(_ moment: ContinuousClock.Instant) -> Bool {
        if ContinuousClock.now >= moment { return true }
        if wakes.insert(moment).inserted {
            Task {
                try? await Task.sleep(until: moment, clock: .continuous)
                wakes.remove(moment)
                now = .now
            }
        }
        // Read, so that the view that asked draws again at the wake.
        return now >= moment
    }
}

/// **A reading that the store reads before its page opens** (the loading contract, C1.3), so a page's first visit
/// draws whole in its first frame, as a later one does. After the first state of a launch or of a new hub generation
/// the store reads every page that a sidebar row opens, once; an agent's sections are read once, when its chat first
/// opens. Nothing of it is on the screen: a read that fails keeps nothing, and the page reads for itself as before.
struct PagePrefetch: Sendable {
    /// The name the page keeps the reading under; for an agent's reading, of that agent.
    let name: @Sendable (_ agent: String) -> String
    /// The owner feature the page needs, or nil.
    let feature: String?
    /// **Read on its own, beside the others** (review A12, fix round 2): a reading of more than the hub — our update
    /// channel, with its 20-second limit — that would hold back every page read after it in the one-at-a-time queue.
    let apart: Bool
    let sharedAcrossAgents: Bool
    let read: @Sendable (_ hub: URL, _ database: String, _ agent: String) async throws -> any Sendable

    /// A reading of the whole fleet.
    init(_ name: String, feature: String? = nil, apart: Bool = false, sharedAcrossAgents: Bool = false,
         read: @escaping @Sendable (URL, String) async throws -> any Sendable) {
        self.name = { _ in name }
        self.feature = feature
        self.apart = apart
        self.sharedAcrossAgents = sharedAcrossAgents
        self.read = { hub, database, _ in try await read(hub, database) }
    }

    /// A reading of one agent.
    init(agent name: @escaping @Sendable (String) -> String, feature: String? = nil,
         read: @escaping @Sendable (URL, String, String) async throws -> any Sendable) {
        self.name = name
        self.feature = feature
        self.apart = false
        self.sharedAcrossAgents = false
        self.read = read
    }
}

extension PagePrefetch {
    /// The readings of the pages that a sidebar row opens, in the order they are read. The machines' readings come
    /// second: every agent's chat panel and setup draws from them.
    @MainActor static let fleet: [PagePrefetch] = [
        ServersPage.prefetch, AgentStatusPanel.prefetch, HealthView.prefetch, DevicesSection.prefetch, UpdatesSection.prefetch,
        AgentPage.prefetch, TeamEditor.prefetch, TriggersView.prefetch, PeoplePage.prefetch,
        PeoplePage.rolesPrefetch, KnowledgePage.prefetch, AccessSettings.prefetch, AppsSettings.prefetch,
        SecretsPage.prefetch, SettingsPage.defaultsPrefetch, RepositoryPicking.prefetch, ErrorReportsSection.prefetch,
        StatsPage.prefetch,
    ]
    /// **The readings that a page judges against the hub's clock**: whether a server answers, whether a machine's
    /// reading is current, which helpers report. The store reads them again every 15 seconds while the app runs
    /// (`FleetStore.keepLive`), so a page that opens draws them as the read that it starts will give them.
    @MainActor static let live: [PagePrefetch] = [
        ServersPage.prefetch, AgentStatusPanel.prefetch, HealthView.prefetch, DevicesSection.prefetch,
    ]
    /// The readings of an agent's sections, read when its chat first opens.
    @MainActor static let agent: [PagePrefetch] = AgentMemorySection.prefetch + [
        PeoplePage.prefetch, ConversationsPage.prefetch, AgentMessagesReading.prefetch,
        KnowledgePage.prefetch, AccessSettings.prefetch, AgentPage.prefetch, SecretsPage.prefetch, KPIsTab.prefetch,
    ]
}

extension FleetStore {
    /// How many readings are read before their pages at one time. The hub's own session takes six requests at a time:
    /// three leave room for the fleet's state, the hub's change signal and the read of the page that shows.
    private static let prefetchLanes = 3

    /// Reads, once for this hub generation, every reading of `fleet` that has none yet; and once for the agent whose
    /// chat shows, every reading of `agent`. In the order of the lists, and none twice; a reading `apart` goes beside
    /// them, on its own.
    ///
    /// **Three at a time** (10 November 2026): one at a time, the 15 readings of the fleet took 3 seconds on the owner's
    /// hub, where one read takes 0.12 to 0.37 s, and an agent's 9 came after them. A page that he opened in those
    /// seconds drew its heading alone and then its groups one after the other (Servers: the list at 441 ms, the
    /// devices at 617 ms).
    func prefetch(fleet: [PagePrefetch], agent: [PagePrefetch], changedAgent: Bool = false) {
        // Only on a hub that answered this launch: never on the reading kept from the last launch alone, which is
        // current while the launch's first read is on its way (`isFresh`).
        guard let state, isFresh, lastSuccess != nil else { return }
        let context = readingContext, hub = hub, database = state.db
        var due: [(PagePrefetch, String)] = []
        if readings.firstPrefetch(context) {
            due += fleet.map { ($0, "") }
        }
        if let name = destination.agentName {
            let first = readings.firstPrefetch(context + "\n" + name)
            if first || changedAgent {
                let items = first ? agent : agent.filter(\.sharedAcrossAgents)
                due = items.map { ($0, name) } + due
            }
        }
        let features = state.ui_features ?? []
        var scheduled: Set<String> = []
        due = due.filter { item, agent in
            (item.feature.map(features.contains) ?? true) && scheduled.insert(item.name(agent)).inserted
        }
        guard !due.isEmpty else { return }
        for (item, agent) in due where item.apart {
            Task { [weak self] in _ = await self?.prefetch(item, agent: agent, hub: hub, database: database) }
        }
        let queue = due.filter { !$0.0.apart }
        for lane in 0..<min(Self.prefetchLanes, queue.count) {
            Task { [weak self] in
                for index in stride(from: lane, to: queue.count, by: Self.prefetchLanes) {
                    let (item, agent) = queue[index]
                    guard let self, await self.prefetch(item, agent: agent, hub: hub, database: database) else { return }
                }
            }
        }
    }

    /// **The live readings stay as current as the fleet's own state** (`PagePrefetch.live`; the owner, 10 November
    /// 2026: "loading certain screens like Servers flicker before they are fully loaded").
    ///
    /// A page read them only while it showed, and drew what it kept against the hub's clock of now when it opened
    /// again. So a list of the servers that was more than ten minutes old said "Not answering" in orange for every
    /// server, with its columns 178 points to the left, for the half second that the page's own read took: measured
    /// on the owner's fleet, the first frame at 109 ms and the true one at 570 ms. Agents drew its CPU and Memory
    /// grey, and a server's page a warning mark where its tick stands, for the same moment. The store now asks for
    /// them in rounds on its own clock, whatever page shows (`LiveReadings`); a read that a page has on its way is
    /// shared (`HubReads`). Nothing of it is on the screen: a read that fails keeps the last reading, as a page's
    /// does.
    func keepLive(_ items: [PagePrefetch]) {
        // Only on a hub that answered this launch and has no notice: never on the reading kept from the last launch
        // alone. It does not wait for the state to be current, so after a sleep its reads go out beside the state's
        // own and are in when the state comes.
        guard let state, lastSuccess != nil, connectionError == nil else { return }
        let sinceAsked = readings.liveAsked.map { Self.seconds(ContinuousClock.now - $0) }
        guard LiveReadings.roundDue(sinceAsked: sinceAsked, running: readings.liveRound) else { return }
        let features = state.ui_features ?? []
        let due = items.filter { $0.feature.map(features.contains) ?? true }
        readings.liveAsked = .now
        // the People page's reading where it has no answer, beside the round and on its own (`readPeopleAgain`)
        defer { readPeopleAgain(besides: items) }
        guard !due.isEmpty else { return }
        readings.liveRound = true
        let hub = hub, database = state.db
        Task { [weak self] in
            // Two at a time: four of the session's six requests stay free for the state, the hub's change signal and
            // the page that shows, and the round is in before a state read that goes out beside it.
            await withTaskGroup(of: Void.self) { group in
                for lane in 0..<min(2, due.count) {
                    group.addTask { [weak self] in
                        for index in stride(from: lane, to: due.count, by: 2) {
                            let item = due[index]
                            let value = try? await item.read(hub, database, "")
                            await self?.keepLive(value, as: item.name(""), hub: hub, database: database)
                        }
                    }
                }
            }
            self?.readings.liveRound = false
        }
    }

    /// **The People page's reading is read again, beside each live round and in a task of its own, while it has no
    /// answer** (the People page keeps a failed read of its own on the page, never here): a chat's book takes the
    /// people's names from it (`chatNames`), and with none it gives a person's name an agent's role. It goes through the
    /// launch's read of a reading that all agents share (`prefetch`), but whatever the page kept: its reads of the name
    /// join the others, the People page's own read among them (`read`), and it keeps its answer only where the reading
    /// still has none and no newer answer or save came after it began (`keep(_:as:from:)`); a read that hangs holds no
    /// round. Not while a read of it by the store is on its way in this hub generation (`peopleReading`), not after a
    /// refusal (a 4xx: no access, or a hub with no such route) or three failed reads (`peopleFailed`), and not where the
    /// round's own readings (`items`) hold it.
    func readPeopleAgain(besides items: [PagePrefetch] = []) {
        let item = PeoplePage.prefetch, name = item.name(""), context = readingContext
        guard let state, lastSuccess != nil, item.feature.map((state.ui_features ?? []).contains) ?? true,
              !items.contains(where: { $0.name("") == name }),
              (reading(name) as PeopleReading<PeopleSnapshot>?)?.value == nil, readings.peopleReading[context] == nil,
              readings.peopleFailed[context, default: 0] < PageReadings.againMost else { return }
        peopleReadBegins(context)
        readings.peopleReadsAgain += 1
        let hub = hub, database = state.db
        Task { [weak self] in
            defer { self?.peopleReadEnds(context) }
            _ = await self?.prefetch(item, agent: "", hub: hub, database: database, again: true)
        }
    }

    /// A read of the People page's reading by the store is on its way in this hub generation (`readPeopleAgain`), and
    /// how many reads again the store started: what a test waits for and counts.
    var readsPeople: Bool { readings.peopleReading[readingContext] != nil }
    var peopleReadsAgain: Int { readings.peopleReadsAgain }

    private func peopleReadBegins(_ context: String) { readings.peopleReading[context, default: 0] += 1 }

    private func peopleReadEnds(_ context: String) {
        let left = readings.peopleReading[context, default: 1] - 1
        readings.peopleReading[context] = left > 0 ? left : nil
    }

    /// A read of the People page's reading to the hub (`read`, its mark: nil for a caller that left before its answer)
    /// failed, for `context`: a refusal (4xx) from any caller stops its reads again at once, but a 408 and a 429, which
    /// ask for a later read, are failures. **A failure counts once for each read to the hub**, not once for each caller
    /// that joined it (each chat that opens reads People), and two reads that fail together count one each. Else a hub
    /// that restarts while the app opens two chats ends the reads again with its first 503, and the chat keeps a
    /// person's name with an agent's role.
    private func peopleReadFailed(_ error: any Error, context: String, read: UUID?) {
        if case .refusal(let refusal)? = error as? HubError, (400..<500).contains(refusal.status),
           ![408, 429].contains(refusal.status) {
            readings.peopleFailed[context] = PageReadings.againMost
        } else if let read, readings.peopleFailed[context, default: 0] < PageReadings.againMost,
                  readings.peopleCounted[context, default: []].insert(read).inserted {
            readings.peopleFailed[context, default: 0] += 1
        }
    }

    /// The callers that wait for the store's read of the reading `name` on its way now, for the tests: a read that
    /// joined it is one of them (`PageReads.waiters`).
    func readers(of name: String) -> Int { readings.reads.waiters(readingContext + "\n" + name) }

    private static func seconds(_ time: Duration) -> TimeInterval {
        TimeInterval(time.components.seconds) + TimeInterval(time.components.attoseconds) / 1e18
    }

    /// Keeps one answer of a round of `keepLive`, for the hub and the generation that it was asked of. A read that
    /// failed takes the reading kept from the last launch with it, as a page's failed read does (`keptReadingFailed`).
    private func keepLive(_ value: (any Sendable)?, as name: String, hub: URL, database: String) {
        guard self.hub == hub, state?.db == database else { return }
        if let value { keep(value, as: name) } else { keptReadingFailed(name) }
    }

    /// Reads one reading of `item` before its page opens, and keeps it unless the page has one by then. False once
    /// the hub or its generation changed. `again`: the People page's reading again where it has no answer
    /// (`readPeopleAgain`), whatever the page kept, through the store's one read of a name (`read`). A failed read of the
    /// People page's reading counts for its reads again (`peopleReadFailed`).
    func prefetch(_ item: PagePrefetch, agent: String, hub: URL, database: String,
                  again: Bool = false) async -> Bool {
        guard self.hub == hub, state?.db == database else { return false }
        let name = item.name(agent)
        // the launch's or a chat's read of the People page's reading: no read again while it is on its way
        let people = name == PeoplePage.prefetch.name(""), launchPeople = !again && people, context = readingContext
        if launchPeople { peopleReadBegins(context) }
        defer { if launchPeople { peopleReadEnds(context) } }
        if item.sharedAcrossAgents {
            // a read again reuses no reading: it starts only where the People reading has no people (`readPeopleAgain`)
            if !again, canReuseFleetReading(name) { return true }
            let start = pageReadStart()
            // Two chats opened in quick succession can ask while the first read is still on its way.
            let value: any Sendable
            do {
                value = try await read(name, from: start) { try await item.read(hub, database, agent) }
            } catch {
                if people, self.hub == hub, state?.db == database {
                    peopleReadFailed(error, context: readingContext, read: start.read)
                }
                return true
            }
            // a read of People that answered: the failed reads that counted are over
            if people { readings.peopleCounted[context] = nil }
            guard self.hub == hub, state?.db == database else { return false }
            // An answer that predates a save, or a newer reading from a visible page, is obsolete. A read again keeps
            // its answer only where the People page's reading still has none: a second guard beside keep(_:as:from:),
            // which refuses an answer older than the page's
            if again, (reading(name) as PeopleReading<PeopleSnapshot>?)?.value != nil { return true }
            keep(value, as: name, from: start)
            return true
        }
        if readingKept(name) != nil { return true }
        guard let value = try? await item.read(hub, database, agent) else {
            if self.hub == hub, state?.db == database { keptReadingFailed(name) }
            return true
        }
        if self.hub == hub, state?.db == database, reading(name) as Any? == nil { keep(value, as: name) }
        return true
    }
}

extension FleetStore {
    /// **A task's thread is read while the pointer is on the row that opens it** (`opensTask`; 10 November 2026). A
    /// thread that opened for the first time drew its column empty for the 250 ms of its read, and then whole
    /// (`TaskView.shows`); a task opened again was whole in its first frame. The pointer is on a row some tenths of a
    /// second before the click, which is the time that the read takes, so most first visits now draw whole too. A click
    /// that comes first shares the read that is on its way (`HubReads`). Nothing is read for a thread that the store
    /// keeps, and a read that fails keeps nothing: the thread reads for itself as before.
    func prefetchTask(_ id: Int) {
        guard let state, isFresh, state.ui_features?.contains("thread_events") == true,
              state.tasks.contains(where: { $0.id == id }) else { return }
        let name = TaskActivity.name(id), key = readingContext + "\n" + name
        guard reading(name) as TaskActivity? == nil, readings.taskReads.insert(key).inserted else { return }
        let hub = hub, database = state.db
        Task { [weak self] in
            var activity = TaskActivity()
            var whole = false
            // Every page of it, as the thread's own first read (`TaskView.readActivity`).
            while let page = try? await HubClient().events(hub: hub, database: database, task: id, after: activity.cursor,
                                                           limit: RuntimePage.most) {
                activity.append(page)
                if !page.more { whole = true; break }
            }
            guard let self else { return }
            self.readings.taskReads.remove(key)
            guard whole, self.hub == hub, self.state?.db == database, self.reading(name) as TaskActivity? == nil else { return }
            self.keep(activity, as: name)
        }
    }
}

/// A row or a link that opens a task's thread: the thread is read once the pointer has been on it for a moment, not
/// for a pointer that only passes over a board of cards (`FleetStore.prefetchTask`).
private struct OpensTask: ViewModifier {
    let store: FleetStore
    let task: Int
    @State private var dwell: Task<Void, Never>?

    func body(content: Content) -> some View {
        content.onHover { inside in
            dwell?.cancel(); dwell = nil
            guard inside else { return }
            dwell = Task {
                do { try await Task.sleep(for: .milliseconds(80)) } catch { return }
                store.prefetchTask(task)
            }
        }
    }
}

extension View {
    /// This view opens the thread of `task`: its thread is read while the pointer is on it (`OpensTask`).
    func opensTask(_ task: Int, store: FleetStore) -> some View { modifier(OpensTask(store: store, task: task)) }
}

/// **The one loading element of a page**: nothing for the first second, then the page's own words ("Reading the
/// servers…"), moving as the chat's waiting line moves, faded in over 150 ms. No spinner, no row, no card.
///
/// Most reads answer well inside that second (171–311 ms on the owner's Mac), and what they read then comes in one
/// frame, with nothing before it that blinks away. The reference apps wait as long before they say they wait: Grok Bot
/// at about 0.8 s, dots at 1.2–1.9 s. The words move because the owner chose moving words over a circle for every wait
/// ("remove that circle, I liked the Thinking text animation"); under Reduce Motion they stand still.
struct LoadingLine: View {
    /// How long a read goes without a word about it, and how long the words stand once they show.
    static let quiet: Duration = .seconds(1)
    static let stands: Duration = .milliseconds(500)
    /// When a loading line last drew its words, a frame after their state changed: `settle` counts its half second
    /// from there.
    @MainActor static var shownAt: ContinuousClock.Instant?

    let words: String
    @State private var shows: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// **One line per page** (fix round 3, item 13): the page's lines in the order they came, and only the first one
    /// draws its words. Can use drew three at once, Servers two.
    @Environment(\.loadingSlots) private var slots
    @State private var slot = UUID()

    /// `waits` false: the words at once, for a line that a `Held` has already kept back for its second.
    init(_ words: String, waits: Bool = true) { self.words = words; _shows = State(initialValue: !waits) }

    /// Its words are on the screen: its second is over, and no line came before it on the page.
    private var drawn: Bool { shows && slots?.first(slot) != false }

    var body: some View {
        HStack(spacing: 0) {
            if drawn {
                Group {
                    if reduceMotion {
                        Text(words).font(FormMetrics.detail).foregroundStyle(FleetStyle.muted)
                    } else {
                        ShimmeringWords(text: words)
                    }
                }.transition(.opacity)
                .onAppear { LoadingLine.shownAt = ContinuousClock.now + .milliseconds(17) }
            }
            Spacer(minLength: 0)
        }
        .frame(height: 20)
        .padding(.horizontal, FormMetrics.rowInset)
        .onAppear { slots?.enter(slot) }
        .onDisappear { slots?.leave(slot) }
        .task {
            guard !shows else { return }
            do { try await Task.sleep(for: Self.quiet) } catch { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { shows = true }
        }
        // VoiceOver hears the wait once, when it shows, as the eye sees it.
        .onChange(of: drawn, initial: true) { _, now in if now { AccessibilityNotification.Announcement(words).post() } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(words)
        .accessibilityAddTraits(.updatesFrequently)
        // Nothing for VoiceOver while nothing is on the screen: it read the words in the quiet second.
        .accessibilityHidden(!drawn)
    }
}

/// **The loading lines of one page, in the order they came** (`LoadingLine`, fix round 3, item 13): only the first one
/// draws its words; when its reading comes, the next one that still waits draws them in its own slot.
@MainActor @Observable final class LoadingSlots {
    private var lines: [UUID] = []
    func enter(_ line: UUID) { if !lines.contains(line) { lines.append(line) } }
    func leave(_ line: UUID) { lines.removeAll { $0 == line } }
    func first(_ line: UUID) -> Bool { lines.first == line }
}

extension EnvironmentValues {
    /// The page's loading lines (`LoadingSlots`); nil outside a page, where every line draws its words.
    @Entry var loadingSlots: LoadingSlots? = nil
}
