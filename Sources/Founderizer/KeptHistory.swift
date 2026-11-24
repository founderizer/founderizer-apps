import FleetCore
import Foundation
import os

/// The blocks on disk that can contribute to a saved window, and those outside its bounds.
/// Join still decides which rows win. A task card can open from the first frame, even offline.
struct KeptHistory: Sendable {
    struct File: Sendable {
        let url: URL
        let first: Int
        let list: OlderRowsList?
    }

    struct Blocks: Sendable {
        var tasks: [OlderBlock] = []
        var rows: [OlderRowsBlock] = []
    }

    var needed: [File] = []
    var later: [File] = []

    init(window: HubState, hub: URL, folder: URL, tasks: Bool, rows: Bool) {
        if tasks, let head = window.older_tasks, head.isValid {
            add(StartAgain.olderFolder(of: hub, in: folder), before: head.before, list: nil)
        }
        if rows, let heads = window.older_rows, heads.isValid {
            for list in OlderRowsList.allCases {
                add(StartAgain.olderRowsFolder(of: hub, list: list.rawValue, in: folder),
                    before: heads[list]?.before ?? 0, list: list)
            }
        }
    }

    private mutating func add(_ folder: URL, before: Int, list: OlderRowsList?) {
        for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] {
            guard name.hasSuffix(".json"), let first = Int(name.dropLast(5)), first >= 0 else { continue }
            let file = File(url: folder.appendingPathComponent(name), first: first, list: list)
            if first < before { needed.append(file) } else { later.append(file) }
        }
    }

    static func read(_ files: [File], priority: QualityOfService = .userInitiated) -> Blocks {
        guard !files.isEmpty else { return Blocks() }
        let result = OSAllocatedUnfairLock(initialState: Blocks())
        let queue = OperationQueue()
        queue.qualityOfService = priority
        queue.maxConcurrentOperationCount = 4
        for file in files {
            queue.addOperation {
                guard let data = KeptFile.bytes(of: file.url, atMost: KeptFile.largestRecord) else { return }
                if let list = file.list {
                    guard let block = try? OlderRowsBlock.decode(data), block.kind == list,
                          block.from == file.first else { return }
                    result.withLock { $0.rows.append(block) }
                } else if let block = try? OlderBlock.decode(data), block.from == file.first {
                    result.withLock { $0.tasks.append(block) }
                }
            }
        }
        queue.waitUntilAllOperationsAreFinished()
        return result.withLock { $0 }
    }
}
