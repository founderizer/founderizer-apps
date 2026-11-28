import Foundation
import Testing
@testable import FleetCore
@testable import FleetOwnerAPI

/// **The app's own form check of a hub's copy gives the owner tools' verdict on each copy of the parity cases** (one
/// rule in three copies: owner_mcp.py's `copy_fault`, FleetOwnerAPI's `CopyShape` and FleetCore's `HubCopyForm`; the
/// Setup and Door areas, 26 November 2026). `owner-parity.json` holds each copy that the stand-in hub served to
/// take_backup and what owner_mcp.py made of it, and `OwnerParityTests` holds `CopyShape` to that. The bug that this
/// catches: a change of the rule in owner_mcp.py and CopyShape that `HubCopyForm` does not take, or the other way
/// round, so that the app's own Save copy keeps a copy that take_backup refuses, or refuses one that it keeps.
struct CopyFormParityTests {
    @Test func theAppsFormCheckGivesTheOwnerToolsVerdictOnEachServedCopy() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("copy-form-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        var judged = 0, kept = 0, withKey = 0
        for one in OwnerParityTests.cases where one.tool == "take_backup" {
            let refusal = one.outcome["refusal"]?.string
            let formsVerdict = one.outcome["result"] != nil || refusal == HubCopyForm.withKey
                || refusal == HubCopyForm.notHubs
            // the copy is the answer that the stand-in hub served as a zip
            guard let served = one.answers.first(where: { $0.1["Content-Type"] == "application/zip" }) else {
                if formsVerdict { Issue.record("\(one.name): owner_mcp.py judged a copy, and the case holds none") }
                continue
            }
            let copy = folder.appendingPathComponent("case-\(judged).zip")
            try served.2.write(to: copy)
            judged += 1
            let shape = CopyShape.fault(copy.path), form = HubCopyForm.fault(copy.path)
            #expect(form == shape, "\(one.name): CopyShape gave \(shape ?? "no refusal")")
            if shape == nil { kept += 1 } else if shape == HubCopyForm.withKey { withKey += 1 }
            if formsVerdict {   // owner_mcp.py's own verdict: kept, or refused by the form's words
                #expect(form == (one.outcome["result"] != nil ? nil : refusal), "\(one.name): owner_mcp.py's verdict")
            }
        }
        #expect(kept > 0 && withKey > 0 && judged - kept - withKey > 0,
                "judged \(judged), kept \(kept), refused with the key's words \(withKey)")
    }
}
