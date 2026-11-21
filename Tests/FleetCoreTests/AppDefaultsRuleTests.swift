#if os(macOS)
import Foundation
import Testing

/// **The apps' defaults and their folder come from one place** (`AppDefaults.store`, `AppFolders.support`; the tests of
/// the Mac app's views of 21 November 2026): a test of its views gives them a folder of its own (`TestDefaults`), and
/// no test reads or writes the owner's real settings or files. In "Sources/Founderizer" and "Sources/FleetCore" no code
/// names the standard defaults past them (also bare, or as a default argument), makes a defaults domain of its own,
/// finds Application Support by itself, or makes an `@AppStorage(` without `store: AppDefaults.store`. Two other words
/// stay: the start's own arguments (`UserDefaults.argumentDomain`), and a time's standard style. The words that this
/// test looks for are joined from parts, so that this file itself names no domain (`TestDefaultsTests`).
struct AppDefaultsRuleTests {
    @Test func theAppsDefaultsAndFolderComeFromOnePlace() throws {
        let standard = "stan" + "dard"
        let allowed = ["UserDefaults." + standard + ".volatileDomain(forName: UserDefaults.argumentDomain)",
                       "time: ." + standard]
        let refused = try Regex(["\\." + standard + "\\b", "UserDefaults\\(\\)", "UserDefaults\\(suite" + "Name",
                                 "UserDefaults\\.init\\(", "applicationSupportDirectory"].joined(separator: "|"))
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        var read = 0, found: [String] = []
        for place in ["Sources/Founderizer", "Sources/FleetCore"] {
            let folder = app.appendingPathComponent(place)
            // also the files of a folder inside it
            let names = (FileManager.default.enumerator(atPath: folder.path)?.allObjects as? [String] ?? [])
                .filter { $0.hasSuffix(".swift") }
            for name in names.sorted() where (name as NSString).lastPathComponent != "AppDefaults.swift" {
                read += 1
                let lines = try String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)
                    .components(separatedBy: "\n")
                for (index, line) in lines.enumerated() {
                    // a comment may name them; code may not
                    if line.trimmingCharacters(in: .whitespaces).hasPrefix("//") { continue }
                    let code = allowed.reduce(line) { $0.replacingOccurrences(of: $1, with: "") }
                    // its store on its own line, or on the next one where the attribute goes on there
                    let open = [",", "("].contains { code.trimmingCharacters(in: .whitespaces).hasSuffix($0) }
                    let next = open && index + 1 < lines.count ? lines[index + 1] : ""
                    if code.contains(refused)
                        || (code.contains("@AppStorage(") && !(code + next).contains("store: AppDefaults.store")) {
                        found.append("\(place)/\(name):\(index + 1)")
                    }
                }
            }
        }
        #expect(read > 300, "the sources of the app and of FleetCore were read")
        #expect(found == [], "the standard defaults or Application Support, reached past AppDefaults and AppFolders")
    }
}
#endif
