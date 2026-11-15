#if os(macOS)
import Foundation

/// **The window that the sidebar's Update opens** (the owner, 15 November 2026, in two chats: "if I had an update
/// available I wanted to see a button above the settings one, where I can click, I see a small confirmation modal to
/// update, and be able to do it from there. I do not want to go to the settings > update page. This applies to the
/// fleet and to the app", and of how it asks: "a macOS dialog, I think we designed it! it should show everytime there is
/// a fleet update or a macOS update!").
///
/// The system's small window, as Founderizer › Check for Updates… opens it: "Update now?", one line for each update
/// with the version it leaves and the one it takes ("Your fleet: 2026.11.494 → 2026.11.495"), and **Update and Restart**
/// while this Mac's build is in it, **Update** while only the fleet's release is; Cancel takes nothing. A window whose
/// reads found nothing to take says so, with OK alone.
public struct UpdateAsk: Equatable, Sendable {
    public let title: String
    /// One line for each update, under the title.
    public let lines: [String]
    /// The release that the fleet's Update takes, or nil.
    public let fleet: ReleaseRow?
    /// The build that this Mac puts in place, or nil.
    public let app: AppManifest?

    /// The window's one press, or nil when it offers none.
    public var press: String? {
        if app != nil { return String(l10n: "Update and Restart") }
        return fleet != nil ? String(l10n: "Update") : nil
    }

    /// The window for the fleet's reading and this Mac's read of our channel, both made just before it opens.
    /// `cannotReplace` is why this Mac cannot put a build in place where it stands: the build is named with that reason,
    /// and not taken.
    public static func of(fleet state: ReleaseState?, app reading: AppUpdateReading?, running: AppVersion?,
                          cannotReplace: String?) -> UpdateAsk {
        let take = state?.waitsForPress
        let from = state?.current?.version
        let build = reading?.offered == true ? reading?.manifest : nil
        var lines: [String] = []
        if let take {
            lines.append(from.map { String(l10n: "Your fleet: \($0) → \(take.version)") }
                         ?? String(l10n: "Your fleet: \(take.version)"))
        }
        if let build {
            lines.append(running.map { String(l10n: "Founderizer for Mac: \($0.name) → \(build.version)") }
                         ?? String(l10n: "Founderizer for Mac: \(build.version)"))
            if let cannotReplace { lines.append(cannotReplace) }
        }
        let app = cannotReplace == nil ? build : nil
        if take != nil || app != nil {
            return UpdateAsk(title: String(l10n: "Update now?"), lines: lines, fleet: take, app: app)
        }
        // Only a build that this Mac cannot put in place: Check for Updates…'s own words for it, with OK alone.
        if let reading, build != nil {
            let check = AppUpdateWords.check(reading, running: running, cannotReplace: cannotReplace)
            return UpdateAsk(title: check.title, lines: [check.line], fleet: nil, app: nil)
        }
        // Nothing to take: what each one runs, so that the press that opened the window is answered.
        var runs: [String] = []
        if let from { runs.append(String(l10n: "Your fleet: \(from)")) }
        runs.append(String(l10n: "Founderizer for Mac: \(AppUpdateWords.version(running))"))
        if let reading, !reading.current, !reading.says.isEmpty { runs.append(reading.says) }
        return UpdateAsk(title: String(l10n: "Nothing to update now"), lines: runs, fleet: nil, app: nil)
    }

    public init(title: String, lines: [String], fleet: ReleaseRow?, app: AppManifest?) {
        self.title = title
        self.lines = lines
        self.fleet = fleet
        self.app = app
    }

    /// **The words of the sidebar's Update** over Settings: no version (the owner, 14 November 2026: "no need to show
    /// the version to update too"). Update at rest, which opens the window; while this Mac's build goes in, the download
    /// and then Restarting…, because the app starts again a few seconds later; Updating… while the fleet's run that he
    /// started goes on; what that run waits for while it waits for running work; Try again after a press that stopped.
    public static func banner(app step: AppUpdateInstaller.Step?, fleet: String? = nil, failed: Bool = false) -> String {
        switch step {
        case .downloading: return step?.says ?? ""
        case .checking, .installing, .installed: return String(l10n: "Restarting…")
        case nil: break
        }
        if let fleet { return fleet }
        return failed ? String(l10n: "Try again") : String(l10n: "Update")
    }
}

extension ReleaseState {
    /// **The release that waits for his press**: the one the Update button takes, unless it waits only for running work
    /// while updates are automatic, because the hub then takes it at the first moment no turn runs (fix round 3, item
    /// 20). The sidebar's Update stands for it, and the window that it opens names it.
    public var waitsForPress: ReleaseRow? {
        let stand = stand
        guard let take = stand.take, !(stand.waiting && automatic) else { return nil }
        return take
    }
}
#endif
