import Foundation

/// **A model by the name that its provider gives it** (the Task page's Runs on; the owner's yes of 17 November 2026 to
/// its picture, "Claude Code · Opus 5.5"). The server's list of models names each by its alias ("opus" is "Opus"), and a
/// session reports the whole id ("claude-opus-5-5"), so the panel showed the id. The name of the alias that the id
/// holds as one of its parts, with the id's short numbers as its version, else the id itself.
public enum ModelWords {
    public static func shown(_ model: String, options: [RuntimeModels.Option]) -> String {
        if let exact = options.first(where: { $0.model == model }) { return exact.display_name }
        // A suffix of the id is no part of its version: "claude-opus-5-5[1m]", "claude-sonnet-4-5@20250929".
        let parts = model.lowercased().split { "-_./[]@".contains($0) }.map(String.init)
        guard let option = options.first(where: { parts.contains($0.model.lowercased()) }) else { return model }
        // A date at the end ("20250805") is no version; a name that says its version keeps it alone.
        let version = parts.filter { $0.count <= 2 && $0.allSatisfy(\.isNumber) }.joined(separator: ".")
        return version.isEmpty || option.display_name.contains(where: \.isNumber) ? option.display_name
            : "\(option.display_name) \(version)"
    }
}
