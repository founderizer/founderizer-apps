#if os(macOS)
import Foundation

/// **The Python that runs the app's bundled installer on this Mac, and never Apple's placeholder.**
///
/// On a Mac with no developer tools, `/usr/bin/python3` is not Python. It is a placeholder of macOS: a run of it
/// ends at once and opens the dialog "The python3 command requires the command line developer tools. Would you like
/// to install the tools now?". The setup service took it, because the file is there and can be executed, so the AI
/// provider form opened that dialog on the Mac of each person who is not a developer (the onboarding test of 13
/// November 2026, on a clean Mac with the released app).
///
/// So the system's Python counts only when the developer tools that hold the real one are on the Mac. A Python of the
/// owner's own (Homebrew's) comes first, as before. No Python is a plain "not available", with no dialog.
public enum SetupPython {
    /// A Python that the owner installed, in the order the service has always looked.
    static let own = ["/opt/homebrew/bin/python3", "/usr/local/bin/python3"]
    /// The system's, which is a real Python only with the developer tools.
    static let system = "/usr/bin/python3"

    /// **The choice, with no reads of its own.**
    ///
    /// - `isExecutable`: whether a file is there and can be executed.
    /// - `developerDirectory`: the folder of the active developer tools, as `xcode-select -p` gives it, or nil when
    ///   the Mac has none. It is asked only when no Python of the owner's own is there.
    public static func choose(isExecutable: (String) -> Bool, developerDirectory: () -> String?) -> String? {
        if let found = own.first(where: isExecutable) { return found }
        guard isExecutable(system), let tools = developerDirectory(), !tools.isEmpty,
              isExecutable(tools + "/usr/bin/python3") else { return nil }
        return system
    }

    /// The Python of this Mac for the installer, or nil.
    public static func find() -> String? {
        choose(isExecutable: { FileManager.default.isExecutableFile(atPath: $0) }, developerDirectory: developerDirectory)
    }

    /// What `xcode-select -p` prints. It opens no dialog on a Mac with no developer tools: it says so and ends with an
    /// error, which is nil here.
    static func developerDirectory() -> String? {
        let tool = Process(), output = Pipe()
        tool.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        tool.arguments = ["-p"]
        tool.standardInput = FileHandle.nullDevice
        tool.standardError = FileHandle.nullDevice
        tool.standardOutput = output
        do { try tool.run() } catch { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        tool.waitUntilExit()
        guard tool.terminationStatus == 0 else { return nil }
        let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }
}
#endif
