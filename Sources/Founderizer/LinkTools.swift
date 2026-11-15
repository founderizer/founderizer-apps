import AppKit
import FleetCore
import FleetOwnerAPI
import Foundation

/// **The app's side of the link's write tools** (`OwnerLinkTools` in FleetOwnerAPI; the secrets plan, step B): a thin
/// adapter from the tool's logic (`SaveBotToken.answer`, tested there with stand-ins) to the app's own engine, on the
/// board of `SetupChannel`. Nothing of it shows on the screen, and nothing of a request (its line, its fields, its
/// value part) is written to the app's log.
///
/// **`save_bot_token`** sends the token as the Discord page's Save does (`DiscordBotPage.save()`): only while the
/// store's reading is current and has a database, with the store's hub, database and installation, through
/// `ChatAppsClient.saveToken`. Unlike the page, it makes no account: the account must be a Discord account that the
/// fleet's chat apps page lists (`ChatAppsClient.read`), whose bridge state also decides `replace`. It takes no command
/// lock: the app does the write, as its form does. With `from` clipboard the app reads `NSPasteboard.general` itself,
/// last, and clears it after a save that the hub confirmed (step C).
/// **A text that the owner's own agent wrote for the report form** (`prepare_problem_report`): the form takes it, and
/// says whether it shows it or keeps the owner's own text.
struct ReportAsk: Equatable {
    enum Outcome: Equatable {
        case shown
        case ownText
    }

    let id = UUID()
    let text: String
    var outcome: Outcome?
}

@MainActor
enum LinkTools {
    /// The hub, the database and the installation that one call reads and sends with.
    struct Place: Sendable {
        let hub: URL
        let database: String
        let client: String
    }

    static func add(to board: SetupBoard, store: @escaping @MainActor () -> FleetStore?) {
        let client = ChatAppsClient()
        let desk = SaveBotToken.Desk<BotToken, Place>(
            token: { BotToken(pasted: $0) },
            isAccountID: { ChatApps.isAccountID($0) },
            ready: {
                guard let store = store(), store.isFresh, let database = store.state?.db else { return nil }
                return Place(hub: store.hub, database: database, client: store.installation)
            },
            accounts: { place in
                do {
                    return try await client.read(hub: place.hub, database: place.database).accounts
                        .map { SaveBotToken.Account(id: $0.id, app: $0.app, state: $0.state) }
                } catch {
                    throw failure(error)
                }
            },
            save: { place, account, token in
                do {
                    let receipt = try await client.saveToken(hub: place.hub, database: place.database,
                                                             client: place.client, account: account, token: token)
                    // An older hub that gives no `replaced` is said as null, never as "not replaced".
                    return SaveBotToken.Receipt(set: receipt.set ?? (token != nil), replaced: receipt.replaced)
                } catch {
                    throw failure(error)
                }
            },
            readClipboard: { gate.read { readPasteboard() } },
            clearClipboard: { count in clearPasteboard(ifStill: count) })
        board.add(set: OwnerSetupTools.set, tool: SaveBotToken.name, value: .optional) { fields, value in
            await SaveBotToken.answer(fields: fields, value: value, desk: desk)
        }
        // `prepare_problem_report`: the agent's text goes into the app's own report form, and the owner sends it.
        let reports = PrepareReport.Desk(holdsKey: { KeyInText.contains($0) },
                                         show: { text in await showReport(text, store: store()) })
        board.add(set: OwnerSetupTools.set, tool: PrepareReport.name, value: .none) { fields, value in
            await PrepareReport.answer(fields: fields, value: value, desk: reports)
        }
    }

    // ------------------------------------------------------------ the report form (`prepare_problem_report`)

    /// **Puts the agent's text into the report form** (`ReportProblemView`): the ask goes into the store, the app's
    /// report window opens and comes to the front (`AppFront.come`, so the window takes no key press until the
    /// owner's click), and the form takes the ask and says how (`ReportAsk.outcome`). The wait has no clock: it ends
    /// on the form's outcome, on another ask in its place, or on the end of the call.
    static func showReport(_ text: String, store: FleetStore?) async -> PrepareReport.Outcome {
        guard let store, let open = store.openReportWindow else { return .noWindow }
        let ask = ReportAsk(text: text)
        store.reportAsk = ask
        AppFront.come { open() }
        let once = ReportOnce()
        let outcome = await withTaskCancellationHandler {
            await withCheckedContinuation { resume in
                once.resume = resume
                watch(report: ask.id, in: store, once: once)
            }
        } onCancel: {
            Task { @MainActor in once.finish(nil) }
        }
        if store.reportAsk?.id == ask.id { store.reportAsk = nil }
        switch outcome {
        case .shown?: return .shown
        case .ownText?: return .ownText
        case nil: return .ended
        }
    }

    /// The wait for the form's outcome: it ends once.
    @MainActor private final class ReportOnce: Sendable {
        nonisolated(unsafe) var resume: CheckedContinuation<ReportAsk.Outcome?, Never>?

        func finish(_ outcome: ReportAsk.Outcome?) {
            guard let resume else { return }
            self.resume = nil
            resume.resume(returning: outcome)
        }
    }

    private static func watch(report id: UUID, in store: FleetStore, once: ReportOnce) {
        guard store.reportAsk?.id == id else { return once.finish(nil) }
        if let outcome = store.reportAsk?.outcome { return once.finish(outcome) }
        withObservationTracking { _ = store.reportAsk } onChange: {
            Task { @MainActor in watch(report: id, in: store, once: once) }
        }
    }

    // ------------------------------------------------------------ the clipboard (`from` clipboard)

    /// One read at a time: a call that comes while macOS's question of an earlier one is up gets `busy`.
    private static let gate = SaveBotToken.ClipboardGate()

    /// **One read of the clipboard**, for `save_bot_token` with `from` clipboard, which reads it only after every other
    /// check passed. On macOS 15.4 and later the owner's setting can deny the app the clipboard (`accessBehavior`):
    /// then nothing is read. Else the change count, the text, and the change count again; when the two counts differ,
    /// something wrote the clipboard during the read, and the read gives nothing. **It reads one time and never
    /// again**: when macOS asks, each read of new content is one more question, and one call brings one question at
    /// most. Nothing of the clipboard goes to a log.
    ///
    /// **It runs on the main thread, and it must.** Measured in this app on a test Mac (macOS 26.6.2, 14 November
    /// 2026): as macOS is today (`alwaysAllow`) a read gives the text at once. With macOS's `ask` behaviour switched on
    /// (the default of a later macOS), a read with no paste of the owner shows macOS's own alert ("Allow Paste",
    /// "Don't Allow Paste") and waits for the owner's answer with no limit; AppKit runs that wait on the calling
    /// thread, and on a thread that is not the main one it ends the app with an exception (`-[HIRunLoopSemaphore
    /// wait:] has been invoked on a secondary thread`). So this read is never moved to another thread. While the alert
    /// is up, the main thread is held in it. "Don't Allow Paste" gives nil, which is `nothing` here. A call whose
    /// caller went away before or during the wait sends nothing (`SaveBotToken.answer` checks for a cancel before and
    /// after the read).
    static func readPasteboard() -> SaveBotToken.Clipboard {
        let board = NSPasteboard.general
        if #available(macOS 15.4, *), board.accessBehavior == .alwaysDeny { return .notAllowed }
        let before = board.changeCount
        let text = board.string(forType: .string)
        guard board.changeCount == before else { return .nothing }
        // A text above a value part's bound is no token: it never goes on to the tool's checks. Its length here is
        // the text's own stored count (UTF-16 units), with no pass over a clipboard of any size; the tool's logic
        // then holds it to the bound in bytes.
        guard let text, !text.isEmpty, (text as NSString).length <= OwnerChannel.valueMax else { return .nothing }
        return .text(text, count: before)
    }

    /// **Clears the clipboard after a confirmed save**, only when its change count is still the read's, and says
    /// whether it cleared. The limit that stays: a process that writes the clipboard between the compare and the clear
    /// loses its text, and a clipboard manager's history keeps its own copy of the token.
    static func clearPasteboard(ifStill count: Int) -> Bool {
        let board = NSPasteboard.general
        guard board.changeCount == count else { return false }
        return board.clearContents() > count                  // the new count: the clear took place
    }

    /// The client's error as the tool's logic reads it: the hub's status and its own words (its route refuses in fixed
    /// sentences; a status of 500 or more is an outcome that is not known), no answer, or an answer that could not be
    /// read.
    nonisolated static func failure(_ error: Error) -> SaveBotToken.HubFailure {
        switch error {
        case HubError.refusal(let status, let words): return .refused(status, words)
        case is URLError, HubError.unavailable: return .noAnswer
        default: return .unreadable
        }
    }
}
