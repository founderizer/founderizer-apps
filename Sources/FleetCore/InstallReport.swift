import Foundation

/// **The report of an install that stopped**: the text that the stop row's Report a problem puts into the report form's
/// box (the owner, 16 November 2026, of a customer's join that stopped at the fetch of the fleet's code: "here we
/// should have a button to Report... as we did in another thread, so it is easier to report issues!"). It goes in as the
/// app's own words (`ReportAsk`, `byAgent: false`), as the manager band's problem does (`ManagerSession.reportText`):
/// the owner reads it in the box, can change it, and sends it.
///
/// It says what the page says (the step that stopped and the stop's line) and **the last lines that the server printed
/// in this install** (`InstallProgress.lines` of the failed step: that step's own when it ran a program on the server,
/// else those of the step before it, which the heading's words allow). The page keeps them out of sight, and they carry
/// the words of the program that failed (git's "unable to connect … Connection timed out", apt's error), which tell
/// one cause from another where the stop's one line names only the likeliest. A Mac's link has no such lines.
///
/// **Nothing in it may be a secret.** The lines are the installer's own, with the plan's redactions already taken out
/// (`MachineInstaller`), but the plan does not know the one-time link code that a new hub's installer prints for its
/// claim (`ClaimCode`), and a step after the claim's wait can still hold that line. So every part of the text, the
/// stop's line included, goes through `clean`: the link code goes, and so does anything that looks like a key
/// (`KeyInText`), so the app's own words never hold one and never keep Send waiting (`ProblemReport.holdsKey`).
public enum InstallReport {
    /// The machine's last lines that go, at most: as many as the installer keeps of a step that failed.
    public static let maxLines = 12
    /// One line's most characters: a program's line can be a page long. The step's title too.
    public static let maxLineLength = 240
    /// The lines' most characters together, so that the box keeps room for the owner's own words under the
    /// website's limit (`ProblemReport.maxText`).
    public static let maxLinesLength = 2000
    /// The stop's line at most: the page's line, which can be a machine's whole line.
    public static let maxStopLength = 600

    /// The box's text. `step`: the title of the step that failed, nil when none had begun. `stop`: the stop's line as the
    /// page shows it. `lines`: what the server printed last, oldest first.
    public static func text(step: String?, stop: String, lines: [String]) -> String {
        let said = clean(String(stop.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxStopLength)))
        var head: String
        if let step, !step.isEmpty {
            head = String(l10n: "The install stopped at “\(clean(String(step.prefix(maxLineLength))))”.")
            // The page's own line for a stop whose reason it cannot read says only the step, which the head says.
            if stop != String(l10n: "It stopped at “\(step)”.") { head += "\n" + said }
        } else {
            head = String(l10n: "The install stopped.") + "\n" + said
        }
        let shown = kept(lines)
        guard !shown.isEmpty else { return head }
        return head + "\n\n" + String(l10n: "The server's last lines:") + "\n" + shown.joined(separator: "\n")
    }

    /// The lines that go: each one cut to `maxLineLength` and `clean`, empty ones left out, and the last ones that fit
    /// in `maxLinesLength`, oldest first.
    static func kept(_ lines: [String]) -> [String] {
        var kept: [String] = [], total = 0
        for line in lines.suffix(maxLines).reversed() {
            let shown = clean(String(line.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxLineLength)))
            guard !shown.isEmpty else { continue }
            total += shown.count + 1
            if total > maxLinesLength { break }
            kept.append(shown)
        }
        return kept.reversed()
    }

    /// The text with no link code and nothing that looks like a key: each one put as "…".
    static func clean(_ text: String) -> String { withoutKeys(withoutCodes(text)) }

    /// **The one-time link code of a new hub**, put as "…": whatever follows its mark in the installer's line
    /// (`FLEET_CLAIM=ABCD-EFGH-JKLM sh -c …`), and a code in its three groups anywhere else.
    static func withoutCodes(_ text: String) -> String {
        let letter = "[" + ClaimCode.alphabet + "]"
        return text
            .replacingOccurrences(of: NSRegularExpression.escapedPattern(for: ClaimCode.logMark) + "[^\\s]+",
                                  with: ClaimCode.logMark + "…", options: .regularExpression)
            .replacingOccurrences(of: "(?<![A-Za-z0-9])\(letter){4}-\(letter){4}-\(letter){4}(?![A-Za-z0-9])",
                                  with: "…", options: .regularExpression)
    }

    /// The text with each part that looks like a key (`KeyInText`) put as "…".
    static func withoutKeys(_ text: String) -> String {
        var text = text
        // Each pass takes one part out and shortens the text, so the passes end; the bound is only a guard.
        for _ in 0..<16 {
            guard let found = KeyInText.first(in: text) else { break }
            text.replaceSubrange(found, with: "…")
        }
        return text
    }
}
