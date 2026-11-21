import Foundation

/// **The run of a change of several secrets, and the save of a secret's note**, on the fleet's Secrets page
/// (`SecretsList` makes their plans). What each call does is given to them, so that a test reaches every rule: the order
/// of a give's or a take-back's signature, the stop at the first refusal, a removal that goes again after team.json
/// moved, and the words that a note's field shows after its save. They run on their caller's actor (the page's is the
/// main actor's), so the calls stay there.
public enum SecretsRun {
    /// Whether the hub refused because team.json changed since the page read it (409, `team_changed`).
    static func teamChanged(_ error: Error) -> Bool {
        guard case HubError.refusal(let refusal) = error else { return false }
        return refusal.status == 409 && refusal.means(.teamChanged)
    }

    // MARK: Give access and Take access

    /// What a run of Give access or Take access did.
    public struct Grants {
        /// The calls that went through, in their order.
        public var done: [SecretsList.Pair] = []
        /// The call that failed and its error; no call after it was made.
        public var failed: (pair: SecretsList.Pair, error: any Error)?
        /// The first warning of a call that went through: an agent that has the secret and cannot use it yet.
        public var warning: String?

        public init() {}
    }

    /// **Give or Take, one pair at a time in the plan's order** (`SecretsList.pairs`). A give is signed for the central
    /// vault (`sign`) before its hub step (`call`), and a take-back after it, as one click of a secret's detail does: the
    /// vault seals a secret only for what the owner signed, and an end only narrows. The first step that fails stops
    /// the run. `call` gives the warning of a grant that went through, or nil. `progress` gets, before each call, the
    /// calls done and the secrets that the run still changes.
    public static func grants(_ change: SecretsList.Change, pairs: [SecretsList.Pair],
                              isolation: isolated (any Actor)? = #isolation,
                              sign: (SecretsList.Pair, SecretGrant?) async throws -> Void,
                              call: (SecretsList.Pair, SecretGrant?) async throws -> String?,
                              progress: (_ done: Int, _ open: Set<String>) async -> Void) async -> Grants {
        let grant: SecretGrant? = change == .give ? .use : nil
        var run = Grants()
        for (index, pair) in pairs.enumerated() {
            await progress(index, Set(pairs[index...].map(\.reference)))
            do {
                if grant != nil { try await sign(pair, grant) }
                let warning = try await call(pair, grant)
                if grant == nil { try await sign(pair, nil) }
                if run.warning == nil { run.warning = warning }
                run.done.append(pair)
            } catch {
                run.failed = (pair, error)
                break
            }
        }
        return run
    }

    // MARK: Delete

    /// What a run of Delete did.
    public struct Removals {
        /// The secrets that left the list, in their order.
        public var gone: [String] = []
        /// The secret whose removal failed and its error; no removal after it was made.
        public var failed: (reference: String, error: any Error)?

        public init() {}
    }

    /// **Delete, one secret at a time** (`SecretsList.removal`), each against the version of team.json that the one
    /// before left (`remove` gives the new version, or nil when its receipt had none). When team.json moved meanwhile
    /// (409 `team_changed`), `reread` reads it again and says its version and whether somebody holds the secret now: the
    /// removal goes once more only while nobody does. The first removal that fails stops the run.
    public static func removals(_ references: [String], sha256: String,
                                isolation: isolated (any Actor)? = #isolation,
                                remove: (_ reference: String, _ sha256: String) async throws -> String?,
                                reread: (_ reference: String) async -> (sha256: String, held: Bool)?,
                                progress: (_ done: Int, _ open: Set<String>) async -> Void) async -> Removals {
        var run = Removals(), version = sha256
        for (index, reference) in references.enumerated() {
            await progress(index, Set(references[index...]))
            do {
                do {
                    version = try await remove(reference, version) ?? version
                } catch where teamChanged(error) {
                    guard let fresh = await reread(reference), !fresh.held else { throw error }
                    version = try await remove(reference, fresh.sha256) ?? fresh.sha256
                }
                run.gone.append(reference)
            } catch {
                run.failed = (reference, error)
                break
            }
        }
        return run
    }

    // MARK: a secret's note

    /// What the save of a secret's note came to, with the words that its field shows then.
    public enum NoteSave: Equatable, Sendable {
        /// The hub took it: the field shows the note of the new reading, which the hub made plain (quotes, brackets,
        /// blanks), so the next time he leaves the field nothing goes again.
        case saved(String)
        /// The note changed at the hub while his words were on their way: the field shows that note, and his words do
        /// not go.
        case changedElsewhere(String)
        /// The secret is no longer in the list.
        case gone
        /// Not saved, with the reason.
        case failed(String)
    }

    /// What a read of the catalog says of one secret's note.
    public enum NoteReading: Equatable, Sendable {
        /// The note there, `""` for none.
        case note(String)
        /// The secret is no longer in the list.
        case gone
        /// The read failed: it says nothing of the note.
        case unread
    }

    /// **His words for a secret's note**: `send` sends them against the version that the page read last. On 409
    /// `team_changed`, `reread` reads the catalog again: when its note is not `base`, the note that the field started
    /// from, it changed elsewhere and his words do not go; else they go once more; a read that failed decides nothing,
    /// and the save stops with the hub's reason. After a save, the field takes the note of the new reading (`reread`),
    /// and his words when that read failed: never the note of an older reading, which a later blur would send as his.
    public static func note(_ words: String, base: String, isolation: isolated (any Actor)? = #isolation,
                            send: () async throws -> Void, reread: () async -> NoteReading,
                            reason: (any Error) -> String) async -> NoteSave {
        do {
            do {
                try await send()
            } catch where teamChanged(error) {
                switch await reread() {
                case .gone: return .gone
                case .unread: throw error
                case .note(let now):
                    if now != base { return .changedElsewhere(now) }
                }
                try await send()
            }
            if case .note(let now) = await reread() { return .saved(now) }
            return .saved(words)
        } catch {
            return .failed(reason(error))
        }
    }
}
