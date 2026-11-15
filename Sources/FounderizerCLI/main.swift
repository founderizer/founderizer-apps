import CoreFoundation
import FleetOwnerAPI
import Foundation

// founderizer-cli: the Founderizer app's own program for the owner's AI agent (OWNER-MCP.md, "The program inside the
// app"). It is `Contents/MacOS/founderizer-cli` of the app's bundle, and the app keeps the link `~/.founderizer/cli` to
// it. Not `founderizer`: a Mac's disk takes that name and the app's own `Founderizer` as one file.

let executable = ProgramPlace.executable()
let bundle = ProgramPlace.bundle(of: executable)
let environment = ProcessInfo.processInfo.environment
let home = URL(fileURLWithPath: environment["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory(),
               isDirectory: true)
let version = bundle.flatMap { ProgramPlace.info("CFBundleShortVersionString", of: $0) } ?? "dev"
// Read once, at the start: an update swaps the bundle under a program that still runs.
let ownBuild = bundle.flatMap(ProgramPlace.build(of:))
// The path that this program was started by, not resolved: at each call the build behind it says whether the app was
// updated (`OwnerTools.call`).
let started = ProgramPlace.startPath(argument: CommandLine.arguments.first ?? "",
                                     directory: FileManager.default.currentDirectoryPath, path: environment["PATH"])

/// The hub's address: read only, from the app's own setting (`hubAddress` of `com.founderizer.app`), at each call, so a
/// fleet that the app sets up during a session counts at once. The program keeps no file with the address.
/// `FOUNDERIZER_HUB` is for tests only, and only a debug build reads it: it points the program at a stand-in hub.
@Sendable func hubSetting() -> String? {
    #if DEBUG
    if let given = ProcessInfo.processInfo.environment["FOUNDERIZER_HUB"], !given.isEmpty { return given }
    #endif
    CFPreferencesAppSynchronize("com.founderizer.app" as CFString)
    return CFPreferencesCopyAppValue("hubAddress" as CFString, "com.founderizer.app" as CFString) as? String
}

let out = FileHandle.standardOutput
let status = OwnerCLI.run(
    arguments: Array(CommandLine.arguments.dropFirst()), executable: executable,
    context: OwnerContext(hubSetting: hubSetting, transport: SessionTransport(), home: home,
                          userAgent: "founderizer-cli/\(version)", ownBuild: ownBuild,
                          startedBuild: { ProgramPlace.build(behind: started) },
                          clientLabel: { ClientLabel.read(home: home) },
                          // The link to the running app of this program's own bundle, for the setup tools.
                          appLink: AppLink.mac(bundle: bundle),
                          // Read only by `write` with from stdin: in the MCP form it is the protocol.
                          standardInput: .process),
    version: version,
    input: { readLine(strippingNewline: true) },
    output: { line in out.write(Data((line + "\n").utf8)) },
    errors: { line in FileHandle.standardError.write(Data((line + "\n").utf8)) },
    announce: { OwnerGuide.announce() },
    front: { AppLink.mac(bundle: bundle).front() })
exit(status)
