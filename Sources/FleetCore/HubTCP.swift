import Foundation

/// **The hub's TCP window, kept by this Mac by itself** (the owner, 10 November 2026: "Yes, every hub").
///
/// The Mac app reads the hub's state every 3 seconds on one kept connection. With `net.ipv4.tcp_slow_start_after_idle`
/// at its default, the hub's Linux kernel starts each answer after the pause from a window of 10 packets again, and the
/// state took 6 round trips. With the value 0 it takes one: on the owner's hub a whole read of the state took 0.60 s
/// before and 0.375 s after (10 November 2026). A hub installed from release 2026.11.293 gets the value from its
/// installer (`hub.sh` step 15, `hubsetup.py tcp`). A release does not run code as root, so a hub installed before that
/// release gets the value only from a root run. This Mac makes that run once on the hub's own machine, over the owner's
/// own SSH connection, from root's own clone at the hub's signed release, as the central vault's install does
/// (`CentralVaultRemote`). Nothing of it is on a page.
public enum HubTCP {
    /// What the run prints when root's clone, at the hub's release, has no `tcp` step that it can call.
    public static let noStep = "founderizer-hub-tcp-no-step"

    /// **The run, as root on the hub's machine.** First the bridge across the key change of 4 November 2026 and
    /// `kit-clone`, as in the central vault's install (`CentralVaultRemote.install`): when one of them fails, the run
    /// stops there. A release before 2026.11.293 has no `tcp` step: `tcp --help` refuses there, as it refuses each step
    /// that a release does not know (and as a `hubsetup.py` that cannot start refuses it), and the run calls no step.
    /// Else it calls `hubsetup.py tcp`, which reads the value first and writes nothing when it holds or when a file of
    /// the server's own sets it (fleet-pilot `hub_tcp_step`, and its test `test_a_second_run_writes_nothing`): so a hub
    /// that has the value gets that check and nothing more. What the run prints decides its outcome (`outcome`).
    ///
    /// The text has no "$". A user who is not root runs it through `sudo -n -i`, and `sudo -i` puts a backslash before
    /// each character except letters, digits, "_", "-" and "$" (sudo's manual), so root's login shell would expand a
    /// "$" before `/bin/sh` reads the text.
    public static func program(in kit: String = CentralVaultRemote.rootKit) -> String {
        let step = "python3 \(kit)/hubsetup.py"
        return CentralVaultRemote.bridge(in: kit) + "; \(step) kit-clone || exit 1; "
            + "\(step) tcp --help >/dev/null 2>&1 || { echo \(noStep); exit 0; }; \(step) tcp"
    }

    /// The start of the step's line when the value holds: "... over an idle time already", or "... over an idle time
    /// (net.ipv4.tcp_slow_start_after_idle = 0)" after the step set it (fleet-pilot `hubsetup.py`, `hub_tcp_step`).
    static let holds = "Founderizer: a kept connection keeps its TCP window over an idle time"
    /// The start of the step's line when a file of the server's own sets the value: that file decides, and the step
    /// writes nothing.
    static let own = "Founderizer: TCP keeps this server's own setting"

    /// What one run came to.
    public enum Outcome: Equatable, Sendable {
        /// Nothing is left to do on that hub: the value holds, or a file of the server's own decides it.
        case done
        /// The hub's release has no `tcp` step yet. A later release has it.
        case noStep
        /// The run stopped, with the last line that it printed.
        case failed(String)
    }

    /// The outcome in what the run printed. The marker says that the release has no step. Else the run is done when the
    /// step's own line says so: the step prints one line, the last one that starts with "Founderizer: ", and a line of
    /// `kit-clone` is never a done step. Any other run failed, and its own last line says why.
    public static func outcome(_ output: String) -> Outcome {
        let lines = output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if lines.contains(noStep) { return .noStep }
        if let said = lines.last(where: { $0.hasPrefix("Founderizer: ") }), said.hasPrefix(holds) || said.hasPrefix(own) {
            return .done
        }
        return .failed(lines.last.map { String($0.prefix(300)) } ?? "The run printed no line.")
    }

    // MARK: the hub's release

    /// The first release whose `hubsetup.py` has the `tcp` step.
    static let firstRelease = (2026, 11, 293)

    /// Whether the hub's release has the step, by its version (`ReleaseState.current`): false before 2026.11.293, true
    /// from it, and nil for a version that this build cannot read, where the run's own `tcp --help` decides.
    public static func hasStep(release version: String?) -> Bool? {
        guard let parts = version?.split(separator: ".", omittingEmptySubsequences: false), parts.count == 3,
              let year = Int(parts[0]), let month = Int(parts[1]), let number = Int(parts[2]) else { return nil }
        return (year, month, number) >= firstRelease
    }

    /// The tries for the hub's release now, and the release they are for: they start again when the hub runs another
    /// release than the one they were for, because that release can bring the step. A release that is not known keeps
    /// them, so a reading that is missing for a moment starts nothing again.
    public static func tries(_ tries: VaultTries?, for release: String?, after earlier: String?)
        -> (tries: VaultTries?, release: String?) {
        guard let release, release != earlier else { return (tries, earlier) }
        return (nil, release)
    }

    // MARK: once for each hub

    /// **One round's part of the step**: the run when it is due (`isDue`), and what came of it (`keep`). A hub whose
    /// release is known to have no step gets no run at all. `run` makes the run on the hub's machine with the program
    /// that it gets, and gives back what the run printed, or throws when it could not make the run; a throw is one more
    /// try, as each outcome that is not done. Gives back the tries after the round. A try counts from the end of its
    /// run, as the vault's own tries do, so a run that waited for its time-out still waits 10 minutes before the next.
    public static func round(_ reading: VaultReading?, hub: URL, release: String?, tries: VaultTries?,
                             now: @Sendable () -> Double = { Date().timeIntervalSince1970 },
                             in defaults: UserDefaults = .standard,
                             run: @Sendable (String) async throws -> String) async -> VaultTries? {
        guard let reading, hasStep(release: release) != false,
              isDue(hub: hub, fleet: reading.fleetID, db: reading.db, tries: tries, now: now(), in: defaults),
              let fleet = reading.fleetID else { return tries }
        let came: Outcome
        do {
            came = outcome(try await run(program()))
        } catch {
            came = .failed(String(((error as? LocalizedError)?.errorDescription ?? String(describing: error)).prefix(300)))
        }
        return keep(came, hub: hub, fleet: fleet, db: reading.db, after: tries, at: now(), in: defaults)
    }

    /// The hubs where this Mac finished the step, by the hub's address, its fleet and its generation, with the time: in
    /// this Mac's defaults, because it is no secret.
    static let doneKey = "hubTCPDone"

    /// This Mac finished the step on this hub of this fleet, in this generation of the hub.
    public static func isDone(hub: URL, fleet: String, db: String, in defaults: UserDefaults = .standard) -> Bool {
        (defaults.dictionary(forKey: doneKey) as? [String: Double])?[name(hub, fleet, db)] != nil
    }

    /// **Whether this Mac makes the run now**: the hub's reading names its fleet, this Mac has not finished the step
    /// there in this generation of the hub, and the wait after the last try is over (`VaultTries`: 10 minutes, and after
    /// 6 tries in a row nothing until the app starts again or the hub takes another release). A finished step never runs
    /// again on that hub, also when its owner later takes the value off by hand. A new generation of the hub (a
    /// restore, or a new install at the same address) gets one more run, which costs the check alone.
    public static func isDue(hub: URL, fleet: String?, db: String, tries: VaultTries?, now: Double,
                             in defaults: UserDefaults = .standard) -> Bool {
        guard let fleet, CentralVault.isFleet(fleet), !db.isEmpty else { return false }
        return !isDone(hub: hub, fleet: fleet, db: db, in: defaults) && (tries?.isDue(at: now) ?? true)
    }

    /// What one run leaves: a done step is kept for the hub, and every other outcome is one more try. A run that finds no
    /// step is a try too, so such a hub gets at most 6 runs until the app starts again or the hub takes another release.
    public static func keep(_ outcome: Outcome, hub: URL, fleet: String, db: String, after tries: VaultTries?,
                            at now: Double, in defaults: UserDefaults = .standard) -> VaultTries? {
        switch outcome {
        case .done:
            var all = defaults.dictionary(forKey: doneKey) as? [String: Double] ?? [:]
            all[name(hub, fleet, db)] = now
            defaults.set(all, forKey: doneKey)
            return nil
        case .noStep: return VaultTries.failed(after: tries, at: now, reason: "The hub's release has no TCP step yet.")
        case .failed(let said): return VaultTries.failed(after: tries, at: now, reason: said)
        }
    }

    private static func name(_ hub: URL, _ fleet: String, _ db: String) -> String { "\(hub.absoluteString)|\(fleet)|\(db)" }
}
