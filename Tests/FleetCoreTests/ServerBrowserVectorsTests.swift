import Foundation
import Testing
@testable import FleetCore

/// **The vectors of the agents' browser ports on a Linux server** (`app/vectors/server-browser-ports.json`): what
/// `ServerBrowser.assign` gives for a server's reading of the ports and the wanted users, and what `ServerBrowser.table`
/// gives for rows, uids, the broker and the worker user (the table's text, or null), and what `ServerBrowser.workerFits`
/// says of a reading's worker user. A port of this step to another app holds its own rule equal to this file: a
/// reading's row with a port outside 9300-9399 or 5910-5999, or with a port or a user that an earlier row has, is no
/// row, no table names a port outside those ranges, and the worker user is the server service's own (`fleet`, with a
/// uid that is not 0, not the broker's and no agent's). Some ports here
/// are no TCP port, or a 16-bit number reads them as 22, 9300 or 5910 (65558, 74836, 71446): a port kept in such a
/// number takes them for ports in range.
///
/// With `FOUNDERIZER_VECTORS_OUT` set, the test writes the file into that folder (`app/vectors/make_vectors.py` does,
/// and its `--check` compares); without it, the test holds the committed file equal to what FleetCore gives now.
struct ServerBrowserVectorsTests {
    typealias Ports = ServerBrowser.Ports
    static let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("vectors")
    static let file = "server-browser-ports.json"
    static let madeBy = "app/Tests/FleetCoreTests/ServerBrowserVectorsTests.swift"

    static func row(_ user: String, _ devtools: Int, _ screen: Int) -> Ports {
        Ports(user: user, devtools: devtools, screen: screen)
    }

    /// Each reading with the wanted users: rows that stay, a new user, and the rows that are none.
    static let assignCases: [(what: String, current: [Ports], wanted: [String])] = [
        ("a row that stays keeps its ports, the rows of the others go, and a new user takes the lowest ports that no row had",
         [row("fleet-a", 9300, 5910), row("fleet-b", 9301, 5911), row("fleet-c", 9302, 5912)],
         ["fleet-c", "fleet-d", "fleet-a"]),
        ("a DevTools port outside 9300-9399 is no row: its user takes free ports",
         [row("fleet-alpha", 22, 5910), row("fleet-beta", 9301, 5911)], ["fleet-alpha", "fleet-beta"]),
        ("a screen port outside 5910-5999 is no row, and holds no port",
         [row("fleet-alpha", 9300, 22)], ["fleet-alpha", "fleet-beta"]),
        ("a DevTools port that an earlier row holds is no row",
         [row("fleet-alpha", 9300, 5910), row("fleet-beta", 9300, 5911)], ["fleet-alpha", "fleet-beta"]),
        ("a screen port that an earlier row holds is no row",
         [row("fleet-alpha", 9300, 5910), row("fleet-beta", 9301, 5910)], ["fleet-alpha", "fleet-beta"]),
        ("a user that an earlier row names is no row",
         [row("fleet-alpha", 9300, 5910), row("fleet-alpha", 9301, 5911)], ["fleet-alpha", "fleet-beta"]),
        ("the ranges' own ends stay", [row("fleet-alpha", 9399, 5999)], ["fleet-alpha"]),
        ("the ports just past the ranges are no rows",
         [row("fleet-a", 9400, 5911), row("fleet-b", 9299, 5912), row("fleet-c", 9302, 6000), row("fleet-d", 9303, 5909)],
         ["fleet-a", "fleet-b", "fleet-c", "fleet-d"]),
        ("a port that is no TCP port, or that a 16-bit number reads as 22, 9300 or 5910, is no row",
         [row("fleet-a", 0, 5910), row("fleet-b", -1, 5911), row("fleet-c", 65558, 5912), row("fleet-d", 74836, 5913),
          row("fleet-e", 9304, 65558), row("fleet-f", 9305, 71446), row("fleet-g", 9306, 0), row("fleet-h", 9307, -1)],
         ["fleet-a", "fleet-b", "fleet-c", "fleet-d", "fleet-e", "fleet-f", "fleet-g", "fleet-h"]),
    ]

    static let uids = ["fleet-alpha": 1002, "fleet-beta": 1003]
    static let two = [row("fleet-alpha", 9311, 5911), row("fleet-beta", 9312, 5912)]

    /// Each table: devops's contract table, one with no broker, no row, and the rows that make no table.
    static let tableCases: [(what: String, rows: [Ports], uids: [String: Int], broker: Int?)] = [
        ("the contract's table of two rows", two, uids, 1001),
        ("no broker", two, uids, nil),
        ("no row: every port of both ranges closed", [], uids, 1001),
        ("a row whose user has no uid", two, ["fleet-alpha": 1002], 1001),
        ("a DevTools port outside 9300-9399", [two[0], row("fleet-beta", 22, 5912)], uids, 1001),
        ("a screen port outside 5910-5999", [two[0], row("fleet-beta", 9312, 22)], uids, 1001),
        ("a DevTools port just past its range", [row("fleet-alpha", 9400, 5911)], uids, 1001),
        ("a screen port just past its range", [row("fleet-alpha", 9311, 5909)], uids, 1001),
        ("a DevTools port 0", [row("fleet-alpha", 0, 5911)], uids, 1001),
        ("a DevTools port -1", [row("fleet-alpha", -1, 5911)], uids, 1001),
        ("a DevTools port that a 16-bit number reads as 22", [row("fleet-alpha", 65558, 5911)], uids, 1001),
        ("a DevTools port that a 16-bit number reads as 9300", [row("fleet-alpha", 74836, 5911)], uids, 1001),
        ("a screen port 0", [row("fleet-alpha", 9311, 0)], uids, 1001),
        ("a screen port -1", [row("fleet-alpha", 9311, -1)], uids, 1001),
        ("a screen port that a 16-bit number reads as 22", [row("fleet-alpha", 9311, 65558)], uids, 1001),
        ("a screen port that a 16-bit number reads as 5910", [row("fleet-alpha", 9311, 71446)], uids, 1001),
    ]

    /// Each worker user of a reading, with the uids of the reading's users and the broker's uid.
    static let workerCases: [(what: String, user: String, uid: Int, uids: [String: Int], broker: Int?)] = [
        ("the server service's own user", "fleet", 1000, uids, 1001),
        ("the service's own user, as which an agent runs too", "fleet", 1000, uids.merging(["fleet": 1000]) { a, _ in a },
         1001),
        ("the service's own user with a system uid, there before the join", "fleet", 999, uids, 1001),
        ("the service's own user with a uid that a 16-bit number reads as 0, and no broker", "fleet", 65536, uids, nil),
        ("a cloud image's login user", "ubuntu", 1000, uids, 1001),
        ("another account", "admin", 1500, uids, 1001),
        ("an agent's user", "fleet-beta", 1003, uids, 1001),
        ("the broker's user", "fleet-vault", 1001, uids, 1001),
        ("a name of an agent's form with a uid of its own", "fleet-other", 1500, uids, 1001),
        ("the service's name in capitals", "Fleet", 1000, uids, 1001),
        ("a system user", "daemon", 1, uids, 1001),
        ("root", "root", 0, uids, 1001),
        ("the service's own user with uid 0", "fleet", 0, uids, 1001),
        ("the service's own user with the broker's uid", "fleet", 1001, uids, 1001),
        ("the service's own user with an agent's uid", "fleet", 1002, uids, 1001),
    ]

    static func rows(_ rows: [Ports]) -> [[String: Any]] {
        rows.map { ["user": $0.user, "devtools": $0.devtools, "screen": $0.screen] }
    }

    static func document() throws -> Data {
        let assign = assignCases.map { what, current, wanted -> [String: Any] in
            ["what": what, "current": rows(current), "wanted": wanted,
             "rows": rows(ServerBrowser.assign(current, wanted: wanted))]
        }
        let table = tableCases.map { what, given, uids, broker -> [String: Any] in
            ["what": what, "rows": rows(given), "uids": uids, "broker": broker.map { $0 as Any } ?? NSNull(),
             "worker": 1000,
             "table": ServerBrowser.table(given, uids: uids, broker: broker, worker: 1000).map { $0 as Any } ?? NSNull()]
        }
        let worker = workerCases.map { what, user, uid, uids, broker -> [String: Any] in
            ["what": what, "user": user, "uid": uid, "uids": uids, "broker": broker.map { $0 as Any } ?? NSNull(),
             "fits": ServerBrowser.workerFits(user, uid: uid, uids: uids, broker: broker)]
        }
        let document: [String: Any] = [
            "about": "FleetCore's ServerBrowser: the rows that assign gives for a server's reading (current) and the "
                + "wanted users, and the table's text that table gives for rows, uids, the broker's uid and the worker "
                + "user's uid (null: no table), and whether workerFits takes a reading's worker user (its name and uid, "
                + "with the uids of the reading's users and the broker's uid). A DevTools port is of 9300 to 9399 and a "
                + "screen port of 5910 to 5999.",
            "made_by": madeBy,
            "assign": assign,
            "table": table,
            "worker": worker,
        ]
        return try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            + Data("\n".utf8)
    }

    @Test("The vectors of the browser ports are what FleetCore gives now")
    func theBrowserPortVectorsAreTheCommittedFile() throws {
        let made = try Self.document()
        if let out = ProcessInfo.processInfo.environment["FOUNDERIZER_VECTORS_OUT"] {
            try made.write(to: URL(fileURLWithPath: out).appendingPathComponent(Self.file))
            return
        }
        let committed = try Data(contentsOf: Self.folder.appendingPathComponent(Self.file))
        #expect(committed == made, "app/vectors/\(Self.file) is not what FleetCore gives: run app/vectors/make_vectors.py")
    }
}
