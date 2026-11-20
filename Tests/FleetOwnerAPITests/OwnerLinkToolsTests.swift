import Darwin
import FleetCore
import Foundation
import Testing
@testable import FleetOwnerAPI

/// A token of the form that `BotToken` takes: made up, of no bot.
let exampleToken = Data("198622483471925248".utf8).base64EncodedString() + ".Cl2FMQ." + String(repeating: "b", count: 29)
/// A Telegram bot token of BotFather's form, made up: the bot's number, a colon and its key.
let exampleTelegramToken = "7000000001:" + String(repeating: "c", count: 35)

/// A text that no refusal may hold: each test puts it where a caller could (a field's value, a field's name, the path,
/// the value) and looks for it in every refusal.
let marker = "zq-marker-7731"

/// What a test's listener was given: each request and a copy of its value part.
final class Given: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [(OwnerChannel.Request, Data?)] = []
    func add(_ request: OwnerChannel.Request, _ value: OwnerChannel.Value?) {
        let bytes = value.map { $0.withBytes { Data($0) } }
        lock.lock(); list.append((request, bytes)); lock.unlock()
    }
    var all: [(OwnerChannel.Request, Data?)] { lock.lock(); defer { lock.unlock() }; return list }
}

/// **Blocking work on a thread of its own**, off Swift's shared pool. The listener's handlers run as tasks on that pool
/// (16 threads on the test Mac), so a test that blocks a pool thread while it waits for a handler can starve the
/// handlers of every other test: with more than 16 such tests at once, each waited its whole bound (60 seconds).
func off<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { done in Thread { done.resume(returning: work()) }.start() }
}

/// **The value part of the wire**, against a real listener on a socket in a folder of the test's own, with a stand-in
/// check of the peer. Each wait for a handler runs `off` the shared pool.
final class OwnerValuePartTests: Sendable {
    let folder: URL
    let path: String

    init() {
        folder = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("fzv-\(UUID().uuidString.prefix(8))", isDirectory: true)
        path = folder.appendingPathComponent("app.sock").path
    }

    deinit { try? FileManager.default.removeItem(at: folder) }

    private func listener(_ given: Given, requestMax: Int = OwnerChannel.requestMax) -> ChannelListener {
        ChannelListener(path: path, check: StandInCheck(takes: true), requestMax: requestMax) { request, value in
            given.add(request, value)
            return .result(.object(["tool": .string(request.tool)]))
        }
    }

    private func raw() throws -> Int32 {
        let socket = OwnerChannel.newSocket()
        try #require(socket >= 0)
        try #require(OwnerChannel.connect(socket, to: path) == 0)
        return socket
    }

    private func send(_ socket: Int32, _ data: Data) {
        _ = data.withUnsafeBytes { write(socket, $0.baseAddress, $0.count) }
    }

    private func readAll(_ socket: Int32) -> String {
        var data = Data(), chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(socket, &chunk, chunk.count)
            guard count > 0 else { break }
            data.append(contentsOf: chunk[0..<count])
        }
        return String(decoding: data, as: UTF8.self)
    }

    private func open(_ listener: ChannelListener, becomes count: Int) -> Bool {
        for _ in 0..<500 {
            if listener.openCount == count { return true }
            usleep(10_000)
        }
        return listener.openCount == count
    }

    private func line(_ tool: String = "save_bot_token", count: Int?, fields: [String: JSONValue] = [:]) -> Data {
        OwnerChannel.Request(set: "owner", tool: tool, fields: fields, valueBytes: count).line
    }

    @Test func theLineSaysTheCountAndNeverTheValue() throws {
        let value = OwnerChannel.Value(copying: Array(exampleToken.utf8))
        let request = OwnerChannel.Request(set: "owner", tool: "save_bot_token", fields: ["account": .string("a")],
                                           valueBytes: value.count)
        #expect(JSONValue.parse(Data(request.line.dropLast()))?["value_bytes"] == .int(Int64(exampleToken.count)))
        #expect(JSONValue.parse(Data(request.line.dropLast()))?["fields"]?["value_bytes"] == nil)
        #expect(try OwnerChannel.Request.read(Data(request.line.dropLast())).get() == request)
        // A line with no value part says no count.
        #expect(JSONValue.parse(Data(line(count: nil).dropLast()))?["value_bytes"] == nil)
    }

    @Test func theExactCountReachesTheHandler() async {
        let given = Given()
        let link = listener(given)
        defer { link.stop() }
        #expect(link.start() == .listening)
        let value = OwnerChannel.Value(copying: Array("abc".utf8))
        let path = path
        let reach = await off {
            ChannelClient.exchange(path: path, request: .init(set: "owner", tool: "save_bot_token"), value: value,
                                   check: StandInCheck(takes: true))
        }
        #expect(reach == .answer(.result(.object(["tool": .string("save_bot_token")]))))
        #expect(given.all.count == 1)
        #expect(given.all.first?.0.valueBytes == 3 && given.all.first?.1 == Data("abc".utf8))
        // With no value: no count and no part.
        _ = await off {
            ChannelClient.exchange(path: path, request: .init(set: "owner", tool: "setup_state"),
                                   check: StandInCheck(takes: true))
        }
        #expect(given.all.count == 2 && given.all.last?.0.valueBytes == nil && given.all.last?.1 == nil)
    }

    @Test func theLineAndTheValueInOneWrite() async throws {
        let given = Given()
        let link = listener(given)
        defer { link.stop() }
        #expect(link.start() == .listening)
        let socket = try raw()
        defer { close(socket) }
        send(socket, line(count: 5) + Data("hello".utf8))
        #expect(await off { self.readAll(socket) }.contains("save_bot_token"))
        #expect(given.all.first?.1 == Data("hello".utf8))
    }

    @Test func theValueInManySmallWrites() async throws {
        let given = Given()
        let link = listener(given)
        defer { link.stop() }
        #expect(link.start() == .listening)
        let socket = try raw()
        defer { close(socket) }
        let value = Data((0..<200).map { UInt8($0 % 251) })
        send(socket, line(count: value.count))
        for byte in value {
            send(socket, Data([byte]))
            usleep(200)
        }
        #expect(await off { self.readAll(socket) }.contains("save_bot_token"))
        #expect(given.all.count == 1 && given.all.first?.1 == value)
    }

    @Test func aShortValueThenACloseDoesNothing() throws {
        let given = Given()
        let link = listener(given)
        defer { link.stop() }
        #expect(link.start() == .listening)
        let socket = try raw()
        send(socket, line(count: 10) + Data("abcd".utf8))
        #expect(open(link, becomes: 1))
        close(socket)
        #expect(open(link, becomes: 0))
        usleep(50_000)
        #expect(given.all.isEmpty)
    }

    @Test func bytesAfterTheValueAreDroppedAndBounded() async throws {
        let given = Given()
        let link = listener(given)
        defer { link.stop() }
        #expect(link.start() == .listening)
        // A few bytes after the N: the value is the N alone.
        let socket = try raw()
        defer { close(socket) }
        send(socket, line(count: 3) + Data("xyz".utf8) + Data(repeating: UInt8(ascii: "q"), count: 100))
        #expect(await off { self.readAll(socket) }.contains("save_bot_token"))
        #expect(given.all.first?.1 == Data("xyz".utf8))
    }

    /// 10 MB after the N while the work runs: the listener ends the connection once the bytes after it pass its bound,
    /// and the work with it.
    @Test func aFloodAfterTheValueEndsByTheBound() async throws {
        let cancelled = Given()
        let link = ChannelListener(path: path, check: StandInCheck(takes: true)) { request, value in
            try? await Task.sleep(for: .seconds(20))
            if Task.isCancelled { cancelled.add(request, value) }
            return .result(.object([:]))
        }
        defer { link.stop() }
        #expect(link.start() == .listening)
        let flood = try raw()
        defer { close(flood) }
        let first = line(count: 3) + Data("xyz".utf8)
        send(flood, first)
        let sender = Thread {
            let block = Data(repeating: UInt8(ascii: "a"), count: 64 * 1024)
            for _ in 0..<160 {
                let sent = block.withUnsafeBytes { write(flood, $0.baseAddress, $0.count) }
                if sent <= 0 { break }
            }
        }
        sender.start()
        #expect(await off { self.readAll(flood) }.isEmpty)       // ended, with no answer
        #expect(open(link, becomes: 0))
        #expect(link.readCount <= first.count + OwnerChannel.requestMax + 16 * 1024)
        await off { for _ in 0..<500 where cancelled.all.isEmpty { usleep(10_000) } }  // the patience of open(_:becomes:)
        #expect(cancelled.all.count == 1 && cancelled.all.first?.1 == Data("xyz".utf8))
    }

    @Test func aCountThatIsNoWholeNumberInItsBoundIsRefusedInFixedWords() throws {
        let given = Given()
        let link = listener(given)
        defer { link.stop() }
        #expect(link.start() == .listening)
        for count: JSONValue in [.int(0), .int(-1), .int(Int64(OwnerChannel.valueMax) + 1), .double(2.5),
                                 .string("3"), .string(marker)] {
            let message: JSONValue = .object(["v": .int(1), "set": .string("owner"), "tool": .string("save_bot_token"),
                                              "fields": .object(["account": .string(marker)]), "value_bytes": count])
            if case .failure(let refusal) = OwnerChannel.Request.read(Data(message.dumps().utf8)) {
                #expect(refusal.text == OwnerChannel.Request.badValueBytes)
            } else {
                Issue.record("taken: \(count)")
            }
            let socket = try raw()
            defer { close(socket) }
            send(socket, Data((message.dumps() + "\n").utf8) + Data("abc".utf8))
            let answer = readAll(socket)
            #expect(answer.contains("value_bytes must be a whole number of 1 to 65536"))
            #expect(!answer.contains(marker))
        }
        #expect(given.all.isEmpty)
    }

    /// **The board decides whether a tool takes a value part**: a value for a tool that takes none, and none for a tool
    /// that needs one, are refused before the tool runs.
    @Test func theBoardRefusesAValuePartThatTheToolDoesNotTake() async throws {
        let ran = Given()
        let board = await MainActor.run {
            let board = SetupBoard(read: { OwnerSetupBoardTests.facts() }, show: { _, _ in nil })
            board.add(set: "owner", tool: "needs_one", value: .required) { fields, value in
                ran.add(.init(set: "owner", tool: "needs_one", fields: fields), value)
                return .result(.object([:]))
            }
            // A tool of the board keeps its entry.
            #expect(!board.add(set: "owner", tool: "setup_state", value: .optional) { _, _ in .refused("no") })
            return board
        }
        let link = ChannelListener(path: path, check: StandInCheck(takes: true)) { request, value in
            await board.answer(request, value: value)
        }
        defer { link.stop() }
        #expect(link.start() == .listening)
        let value = OwnerChannel.Value(copying: Array("abc".utf8))
        let path = path
        let state = await off {
            ChannelClient.exchange(path: path, request: .init(set: "owner", tool: "setup_state"), value: value,
                                   check: StandInCheck(takes: true))
        }
        #expect(state == .answer(.refused("setup_state takes no value part after its request line, so the app did "
                                          + "nothing.")))
        let none = await off {
            ChannelClient.exchange(path: path, request: .init(set: "owner", tool: "needs_one"),
                                   check: StandInCheck(takes: true))
        }
        #expect(none == .answer(.refused("needs_one needs a value part after its request line, which founderizer-cli "
                                         + "reads on this Mac with from. The app did nothing.")))
        #expect(ran.all.isEmpty)
        let taken = await off {
            ChannelClient.exchange(path: path, request: .init(set: "owner", tool: "needs_one"), value: value,
                                   check: StandInCheck(takes: true))
        }
        #expect(taken == .answer(.result(.object([:]))))
        #expect(ran.all.count == 1 && ran.all.first?.1 == Data("abc".utf8))
    }
}

extension OwnerValuePartTests {
    /// **D12: a value part over the bound**: the count is refused while the client still writes, and nothing hangs.
    @Test func aValueOverTheBoundIsRefusedWhileTheClientWrites() {
        let given = Given()
        let link = ChannelListener(path: path, check: StandInCheck(takes: true)) { request, value in
            given.add(request, value)
            return .result(.object([:]))
        }
        defer { link.stop() }
        #expect(link.start() == .listening)
        let value = OwnerChannel.Value(copying: [UInt8](repeating: 0x41, count: 200 * 1024))
        let reach = ChannelClient.exchange(path: path, request: .init(set: "owner", tool: "save_bot_token"),
                                           value: value, check: StandInCheck(takes: true), quietReads: 20,
                                           readWait: timeval(tv_sec: 0, tv_usec: 100_000))
        #expect(reach == .answer(.refused(OwnerChannel.Request.badValueBytes)))
        #expect(given.all.isEmpty)
    }

    /// **D13: exactly the bound**: the handler gets every byte.
    @Test func aValueOfExactlyTheBoundArrivesWhole() async {
        let given = Given()
        let link = ChannelListener(path: path, check: StandInCheck(takes: true)) { request, value in
            given.add(request, value)
            return .result(.object([:]))
        }
        defer { link.stop() }
        #expect(link.start() == .listening)
        let bytes = (0..<OwnerChannel.valueMax).map { UInt8(($0 * 7 + 3) % 256) }
        let path = path
        let reach = await off {
            ChannelClient.exchange(path: path, request: .init(set: "owner", tool: "save_bot_token"),
                                   value: OwnerChannel.Value(copying: bytes), check: StandInCheck(takes: true))
        }
        #expect(reach == .answer(.result(.object([:]))))
        #expect(given.all.count == 1 && given.all.first?.1 == Data(bytes))
        #expect(given.all.first?.0.valueBytes == OwnerChannel.valueMax)
    }

    /// **D14: the line and the first 4 bytes in one write, the other 6 later**: the handler gets the 10.
    @Test func partOfTheValueWithTheLineAndTheRestLater() async throws {
        let given = Given()
        let link = listener(given)
        defer { link.stop() }
        #expect(link.start() == .listening)
        let socket = try raw()
        defer { close(socket) }
        send(socket, line(count: 10) + Data("0123".utf8))
        #expect(open(link, becomes: 1))
        usleep(20_000)
        #expect(given.all.isEmpty)
        send(socket, Data("456789".utf8))
        #expect(await off { self.readAll(socket) }.contains("save_bot_token"))
        #expect(given.all.count == 1 && given.all.first?.1 == Data("0123456789".utf8))
    }

    /// **D15: a value part that waits is ended by the connection that is one more than the bound**, and its handler
    /// never runs.
    @Test func aWaitingValueIsEndedByOneMoreThanTheBound() throws {
        let given = Given()
        let link = ChannelListener(path: path, check: StandInCheck(takes: true), openMax: 2) { request, value in
            given.add(request, value)
            return .result(.object([:]))
        }
        defer { link.stop() }
        #expect(link.start() == .listening)
        let waiting = try raw()
        defer { close(waiting) }
        let sent = line(count: 10).count + 4
        send(waiting, line(count: 10) + Data("0123".utf8))
        #expect(open(link, becomes: 1))
        var tries = 500
        while link.readCount < sent && tries > 0 { usleep(10_000); tries -= 1 }
        #expect(link.readCount == sent)                        // the value part waits with 4 of its 10 bytes
        let second = try raw()
        defer { close(second) }
        let third = try raw()
        defer { close(third) }
        #expect(readAll(waiting).isEmpty)                      // ended, with no answer
        #expect(open(link, becomes: 2))
        send(waiting, Data("456789".utf8))
        usleep(20_000)
        #expect(given.all.isEmpty)
    }

    /// **C10: the writes have the read's bound**: an app that took the connection, passes the check and reads nothing
    /// does not hold the program with a value of 64 KiB.
    @Test func anAppThatReadsNothingDoesNotHoldTheProgram() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let server = OwnerChannel.newSocket()
        try #require(server >= 0)
        defer { close(server) }
        var address = OwnerChannel.address(path)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(server, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        try #require(bound == 0 && listen(server, 4) == 0)
        // The connection waits in the queue, accepted by the system and read by nobody.
        let started = ContinuousClock.now
        let reach = ChannelClient.exchange(path: path, request: .init(set: "owner", tool: "save_bot_token"),
                                           value: OwnerChannel.Value(copying: [UInt8](repeating: 0x41,
                                                                                       count: OwnerChannel.valueMax)),
                                           check: StandInCheck(takes: true), quietReads: 3,
                                           readWait: timeval(tv_sec: 0, tv_usec: 50_000))
        #expect(reach == .failed(ChannelClient.noAnswer))
        #expect(ContinuousClock.now - started < .seconds(5))
    }
}

/// **The program's link, with stand-in exchanges.**
final class OwnerAppLinkValueTests {
    /// **D16: each try after a start sends the same value**, and the answer comes back.
    @Test func eachTryAfterAStartSendsTheSameValue() {
        final class Seen: @unchecked Sendable {
            let lock = NSLock()
            var values: [ObjectIdentifier?] = []
            var reaches: [ChannelClient.Reach] = [.nothingListens, .busy, .busy,
                                                  .answer(.result(.object(["set": .bool(true)])))]
        }
        let seen = Seen()
        let link = AppLink(exchange: { _, value in
            seen.lock.lock(); defer { seen.lock.unlock() }
            seen.values.append(value.map { ObjectIdentifier($0) })
            return seen.reaches.removeFirst()
        }, start: { true }, pause: {}, tries: 5)
        let value = OwnerChannel.Value(copying: Array(exampleToken.utf8))
        let (text, isError) = link.call(tool: SaveBotToken.name, fields: ["account": .string("discord-example")],
                                        value: value)
        #expect(!isError && JSONValue.parse(text) == .object(["set": .bool(true)]))
        #expect(seen.values.count == 4 && seen.values.allSatisfy { $0 == ObjectIdentifier(value) })
    }

    /// **C11: after its request went out, a link write's outcome is not known**: its three failures say so in the
    /// tool's words; the setup tools keep their own.
    @Test func aLinkWriteWithNoAnswerSaysTheOutcomeIsNotKnown() {
        for words in [ChannelClient.noAnswer, ChannelClient.closedNoAnswer, ChannelClient.unreadable] {
            let link = AppLink(exchange: { _, _ in .failed(words) }, start: { false }, pause: {}, tries: 0)
            #expect(link.call(tool: SaveBotToken.name, fields: [:]) == (SaveBotToken.notKnownHere, true))
            #expect(link.call(tool: OwnerSetupTools.state, fields: [:]) == (words, true))
        }
        #expect(SaveBotToken.notKnownHere.contains("not known") && SaveBotToken.notKnownHere.contains("no harm"))
        // A failure before anything went out keeps its words.
        let unreached = AppLink(exchange: { _, _ in .failed("This program cannot make a local socket.") },
                                start: { false }, pause: {}, tries: 0)
        #expect(unreached.call(tool: SaveBotToken.name, fields: [:]) == ("This program cannot make a local socket.", true))
    }
}

// ------------------------------------------------------------ the value's type

struct OwnerValueTypeTests {
    /// Each way that Swift prints a value, held against a plain type that holds the same text: the plain one shows it
    /// in each way (so each check below can fail), and the value in none.
    @Test func aValuePrintsNothingOfItsBytes() {
        struct Plain { let text: String }
        func printed(_ thing: Any) -> [String] {
            var dumped = ""
            dump(thing, to: &dumped)
            return [String(describing: thing), String(reflecting: thing), "\(thing)", dumped, "\([thing])"]
        }
        for shown in printed(Plain(text: marker)) { #expect(shown.contains(marker), "\(shown)") }
        let value = OwnerChannel.Value(copying: Array(marker.utf8))
        for shown in printed(value) + [value.description, value.debugDescription] {
            #expect(!shown.contains(marker), "\(shown)")
        }
        #expect(Mirror(reflecting: value).children.isEmpty)
        #expect(value.count == marker.utf8.count)
        #expect(value.withBytes { Data($0) } == Data(marker.utf8))
    }

    @Test func itsTextIsStrictUTF8() {
        #expect(OwnerChannel.Value(copying: Array("caf\u{E9} ok".utf8)).text == "caf\u{E9} ok")
        for bad: [UInt8] in [[0xC0, 0x80], [0xED, 0xA0, 0x80], [0xE2, 0x82], [0xFF, 0xFE], [0x61, 0x80]] {
            #expect(OwnerChannel.Value(copying: bad).text == nil, "\(bad)")
        }
    }

    @Test func theWipeLeavesZeros() {
        var bytes: [UInt8] = Array(marker.utf8)
        OwnerChannel.wipe(&bytes)
        #expect(bytes.allSatisfy { $0 == 0 } && bytes.count == marker.utf8.count)
        var data = Data(marker.utf8)
        OwnerChannel.wipe(&data)
        #expect(data.allSatisfy { $0 == 0 })
    }
}

// ------------------------------------------------------------ the sources

/// A standard input that a test gives: its bytes, in reads of at most `step`.
final class FakeInput: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: [UInt8]
    let step: Int
    init(_ bytes: [UInt8], step: Int = 4096) {
        self.bytes = bytes
        self.step = step
    }

    func input(terminal: Bool = false) -> StandardInput {
        StandardInput(isTerminal: { terminal }, read: { [self] buffer in
            lock.lock(); defer { lock.unlock() }
            let count = min(buffer.count, step, bytes.count)
            buffer.copyBytes(from: bytes.prefix(count))
            bytes.removeFirst(count)
            return count
        })
    }
}

final class OwnerValueSourceTests {
    let folder: URL

    init() {
        folder = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("fzf-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: folder) }

    private func file(_ name: String, _ data: Data) -> String {
        let place = folder.appendingPathComponent(name).path
        FileManager.default.createFile(atPath: place, contents: data)
        return place
    }

    private func refusal(_ result: Result<OwnerChannel.Value, OwnerChannel.Refusal>) -> String? {
        if case .failure(let refusal) = result { return refusal.text }
        return nil
    }

    @Test func aRegularFileIsReadWhole() throws {
        let value = try ValueSource.file(file("token", Data(exampleToken.utf8))).get()
        #expect(value.withBytes { Data($0) } == Data(exampleToken.utf8))
    }

    @Test func theFileBounds() {
        #expect(refusal(ValueSource.file(file("empty", Data()))) == ValueSource.emptyFile)
        let atBound = file("bound", Data(repeating: 0x41, count: OwnerChannel.valueMax))
        #expect((try? ValueSource.file(atBound).get())?.count == OwnerChannel.valueMax)
        let over = file("over", Data(repeating: 0x41, count: OwnerChannel.valueMax + 1))
        #expect(refusal(ValueSource.file(over)) == ValueSource.largeFile)
    }

    @Test func whatIsNoRegularFileIsRefused() throws {
        let target = file("target", Data("abc".utf8))
        let link = folder.appendingPathComponent("link").path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)
        #expect(refusal(ValueSource.file(link)) == ValueSource.isLink)
        #expect(refusal(ValueSource.file(folder.path)) == ValueSource.notRegular)
        // A FIFO with no writer: refused at once, never a wait.
        let fifo = folder.appendingPathComponent("fifo").path
        try #require(mkfifo(fifo, 0o600) == 0)
        #expect(refusal(ValueSource.file(fifo)) == ValueSource.notRegular)
        #expect(refusal(ValueSource.file("/dev/zero")) == ValueSource.notRegular)
        #expect(refusal(ValueSource.file(folder.appendingPathComponent("none").path)) == ValueSource.missing)
        #expect(refusal(ValueSource.file(folder.appendingPathComponent("a\u{0}b").path)) == ValueSource.missing)
        // A socket.
        let socketPath = folder.appendingPathComponent("s").path
        let socket = OwnerChannel.newSocket()
        defer { close(socket) }
        var address = OwnerChannel.address(socketPath)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(socket, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        try #require(bound == 0)
        #expect(refusal(ValueSource.file(socketPath)) != nil)
    }

    @Test func standardInputFromAPipe() throws {
        var ends: [Int32] = [0, 0]
        try #require(pipe(&ends) == 0)
        let reader = ends[0]
        defer { close(reader) }
        _ = Data(exampleToken.utf8).withUnsafeBytes { write(ends[1], $0.baseAddress, $0.count) }
        close(ends[1])
        let input = StandardInput(isTerminal: { isatty(reader) == 1 }, read: { Darwin.read(reader, $0.baseAddress, $0.count) })
        let value = try ValueSource.standardInput(input).get()
        #expect(value.withBytes { Data($0) } == Data(exampleToken.utf8))
    }

    @Test func standardInputBounds() {
        #expect(refusal(ValueSource.standardInput(FakeInput(Array("abc".utf8)).input(terminal: true)))
                == ValueSource.terminal)
        #expect(refusal(ValueSource.standardInput(FakeInput([]).input())) == ValueSource.emptyInput)
        let most = FakeInput([UInt8](repeating: 0x41, count: OwnerChannel.valueMax), step: 1000).input()
        #expect((try? ValueSource.standardInput(most).get())?.count == OwnerChannel.valueMax)
        let over = FakeInput([UInt8](repeating: 0x41, count: OwnerChannel.valueMax + 1)).input()
        #expect(refusal(ValueSource.standardInput(over)) == ValueSource.largeInput)
        let failing = StandardInput(isTerminal: { false }, read: { _ in -1 })
        #expect(refusal(ValueSource.standardInput(failing)) == ValueSource.unreadInput)
        #expect(refusal(ValueSource.standardInput(.none)) == ValueSource.emptyInput)
    }
}

// ------------------------------------------------------------ the program

/// A stand-in link that keeps each request and a copy of its value part, and gives one answer.
final class ValueLink: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [(OwnerChannel.Request, Data?)] = []
    let reach: ChannelClient.Reach
    init(_ reach: ChannelClient.Reach = .answer(.result(.object(["account": .string("discord-example"),
                                                                 "set": .bool(true), "replaced": .bool(false)])))) {
        self.reach = reach
    }

    var all: [(OwnerChannel.Request, Data?)] { lock.lock(); defer { lock.unlock() }; return list }

    func appLink() -> AppLink {
        AppLink(exchange: { [self] request, value in
            let bytes = value.map { $0.withBytes { Data($0) } }
            lock.lock(); list.append((request, bytes)); lock.unlock()
            return reach
        }, start: { false }, pause: {}, tries: 0)
    }
}

final class OwnerLinkProgramTests {
    let home = Fixture.home()
    deinit { try? FileManager.default.removeItem(at: home) }

    private func context(_ link: ValueLink, input: StandardInput = .none) -> OwnerContext {
        OwnerContext(hubSetting: { nil }, transport: Fixture.transport(), home: home, userAgent: "founderizer-cli/test",
                     ownBuild: nil, startedBuild: { nil }, clientLabel: { "founderizer-cli/1/test" },
                     appLink: link.appLink(), standardInput: input)
    }

    private func program() throws -> URL {
        let folder = home.appendingPathComponent("build", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let source = Bundle.module.url(forResource: "owner-tools", withExtension: "json", subdirectory: "Fixtures")!
        try? FileManager.default.copyItem(at: source, to: folder.appendingPathComponent("owner-tools.json"))
        return folder.appendingPathComponent("founderizer-cli")
    }

    private func run(_ arguments: [String], _ link: ValueLink,
                     input: StandardInput = .none) throws -> (Int32, [String], [String]) {
        let out = Lines()
        var errors: [String] = []
        let status = OwnerCLI.run(arguments: arguments, executable: try program(), context: context(link, input: input),
                                  version: "0.1.0", input: { nil }, output: { out.add($0) },
                                  errors: { errors.append($0) })
        return (status, out.all, errors)
    }

    private func tokenFile() -> String {
        let place = home.appendingPathComponent("bot-token.txt").path
        FileManager.default.createFile(atPath: place, contents: Data((exampleToken + "\n").utf8))
        return place
    }

    @Test func theToolIsAWriteOfTheProgramAlone() throws {
        let tools = OwnerTools(table: Fixture.table, context: context(ValueLink()))
        let tool = try #require(tools.listed.first { $0.name == SaveBotToken.name })
        #expect(tool.annotations == .object(["readOnlyHint": .bool(false)]))
        #expect(tool.inputSchema["additionalProperties"] == .bool(false))
        #expect(tool.inputSchema["required"] == .array([.string("account")]))
        #expect(OwnerTools.verb(of: tool) == .write)
        #expect(OwnerCLI.setupTools == ["setup_state", "setup_show", "setup_diagnosis"])
        #expect(OwnerLinkTools.names == ["save_bot_token", "prepare_problem_report", "save_secret", "grant_secret",
                                         "share_secret", "answer_secret_request"])
        #expect(OwnerLinkTools.tools.map(\.name) == OwnerLinkTools.names)
        #expect(Fixture.table.tool(SaveBotToken.name) == nil)
        let (status, out, _) = try run(["tools"], ValueLink())
        #expect(status == 0 && out.contains { $0.hasPrefix("write save_bot_token: Saves the token of a Discord or Telegram bot") })
    }

    @Test func writeTakesItAndSendsNoPath() throws {
        let link = ValueLink()
        let place = tokenFile()
        let (status, out, said) = try run(["write", "save_bot_token",
                                           JSONValue.object(["account": .string("discord-example"),
                                                             "from": .string("file"),
                                                             "path": .string(place)]).dumps()], link)
        #expect(status == 0 && said.isEmpty)
        #expect(JSONValue.parse(out.joined())?["set"] == .bool(true))
        let sent = try #require(link.all.first)
        #expect(sent.0 == OwnerChannel.Request(set: "owner", tool: "save_bot_token",
                                               fields: ["account": .string("discord-example"), "from": .string("file")]))
        #expect(sent.1 == Data((exampleToken + "\n").utf8))
        #expect(!String(decoding: sent.0.line, as: UTF8.self).contains(place))
        // "~" is this program's home, as the file tools take it.
        _ = try run(["write", "save_bot_token", #"{"account": "discord-example", "from": "file", "path": "~/bot-token.txt"}"#],
                    link)
        #expect(link.all.count == 2 && link.all.last?.1 == Data((exampleToken + "\n").utf8))
    }

    @Test func callRefusesIt() throws {
        let link = ValueLink()
        let (status, _, said) = try run(["call", "save_bot_token", #"{"account": "discord-example", "delete": true}"#],
                                        link)
        #expect(status == 1 && said == ["save_bot_token writes, so founderizer-cli call does not take it: run "
                                        + "founderizer-cli write save_bot_token '<json object>'. The owner's client "
                                        + "asks before each write."])
        #expect(link.all.isEmpty)
    }

    @Test func writeReadsAPipe() throws {
        let link = ValueLink()
        let (status, _, _) = try run(["write", "save_bot_token", #"{"account": "discord-example", "from": "stdin"}"#],
                                     link, input: FakeInput(Array(exampleToken.utf8)).input())
        #expect(status == 0)
        #expect(link.all.first?.1 == Data(exampleToken.utf8))
        #expect(link.all.first?.0.fields == ["account": .string("discord-example"), "from": .string("stdin")])
        let (terminal, _, said) = try run(["write", "save_bot_token", #"{"account": "discord-example", "from": "stdin"}"#],
                                          link, input: FakeInput(Array(exampleToken.utf8)).input(terminal: true))
        #expect(terminal == 1 && said == [ValueSource.terminal] && link.all.count == 1)
    }

    @Test func aDeleteSendsNoValue() throws {
        let link = ValueLink()
        let (status, _, _) = try run(["write", "save_bot_token", #"{"account": "discord-example", "delete": true}"#], link)
        #expect(status == 0)
        #expect(link.all.first?.0.fields == ["account": .string("discord-example"), "delete": .bool(true)])
        #expect(link.all.first?.1 == nil)
    }

    @Test func theMCPFormListsItAndRefusesStdin() throws {
        let link = ValueLink()
        let lines = Lines()
        let place = tokenFile()
        let mcp = OwnerMCP(tools: OwnerTools(table: Fixture.table, context: context(link, input: FakeInput(Array(
            exampleToken.utf8)).input())), version: "0.1.0", sink: { lines.add($0) })
        mcp.take(line: #"{"jsonrpc": "2.0", "id": 1, "method": "tools/list"}"#)
        mcp.take(line: #"{"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {"name": "save_bot_token", "#
                 + #""arguments": {"account": "discord-example", "from": "stdin"}}}"#)
        mcp.take(line: JSONValue.object([
            "jsonrpc": .string("2.0"), "id": .int(3), "method": .string("tools/call"),
            "params": .object(["name": .string("save_bot_token"),
                               "arguments": .object(["account": .string("discord-example"), "from": .string("file"),
                                                     "path": .string(place)])]),
        ]).dumps())
        mcp.finish()
        let said = lines.wait(for: 3)
        let listed = try #require(said.first { $0["id"] == .int(1) }?["result"]?["tools"]?.array)
        let tool = try #require(listed.first { $0["name"] == .string("save_bot_token") })
        #expect(tool["annotations"]?["readOnlyHint"] == .bool(false))
        let stdin = try #require(said.first { $0["id"] == .int(2) }?["result"])
        #expect(stdin["isError"] == .bool(true))
        #expect(stdin["content"]?.array?.first?["text"] == .string(SaveBotToken.stdinInMCP))
        #expect(stdin["content"]?.array?.first?["text"]?.string?.contains("founderizer-cli write") == true)
        let file = try #require(said.first { $0["id"] == .int(3) }?["result"])
        #expect(file["isError"] == .bool(false))
        #expect(link.all.count == 1 && link.all.first?.0.fields["from"] == .string("file"))
    }

    /// **`from` clipboard in the program**: the plan sends `from` and no path, and the program reads nothing: no value
    /// part, and not one look at its standard input, with `write` and in the MCP form.
    @Test func theClipboardIsReadByTheAppAndTheProgramReadsNothing() throws {
        final class Looked: @unchecked Sendable {
            let lock = NSLock()
            var count = 0
            func add() { lock.lock(); count += 1; lock.unlock() }
        }
        let looked = Looked()
        let input = StandardInput(isTerminal: { looked.add(); return false }, read: { _ in looked.add(); return 0 })
        let fields: [String: JSONValue] = ["account": .string("discord-example"), "from": .string("clipboard")]
        guard case .success(let plan) = SaveBotToken.plan(fields) else { Issue.record("refused"); return }
        #expect(plan.source == .clipboard && plan.send == fields)
        guard case .success(let replace) = SaveBotToken.plan(fields.merging(["replace": .bool(true)]) { $1 }) else {
            Issue.record("refused"); return
        }
        #expect(replace.send["replace"] == .bool(true) && replace.send["path"] == nil)
        let link = ValueLink()
        let (status, _, said) = try run(["write", "save_bot_token", JSONValue.object(fields).dumps()], link,
                                        input: input)
        #expect(status == 0 && said.isEmpty)
        #expect(link.all.count == 1 && link.all.first?.0.fields == fields && link.all.first?.1 == nil)
        #expect(link.all.first?.0.valueBytes == nil)
        // The MCP form takes it too.
        let lines = Lines()
        let mcp = OwnerMCP(tools: OwnerTools(table: Fixture.table, context: context(link, input: input)),
                           version: "0.1.0", sink: { lines.add($0) })
        mcp.take(line: JSONValue.object([
            "jsonrpc": .string("2.0"), "id": .int(1), "method": .string("tools/call"),
            "params": .object(["name": .string("save_bot_token"), "arguments": .object(fields)]),
        ]).dumps())
        mcp.finish()
        let answer = try #require(lines.wait(for: 1).first { $0["id"] == .int(1) }?["result"])
        #expect(answer["isError"] == .bool(false))
        #expect(link.all.count == 2 && link.all.last?.0.fields == fields && link.all.last?.1 == nil)
        #expect(looked.count == 0)
        // With a path: refused in the program, and nothing sent.
        let (refused, _, words) = try run(["write", "save_bot_token",
                                           JSONValue.object(fields.merging(["path": .string("/tmp/example")]) { $1 })
                                               .dumps()], link)
        #expect(refused == 1 && words == [SaveBotToken.pathOnlyWithFile] && link.all.count == 2)
    }

    @Test func theProgramsRefusalsQuoteNothing() throws {
        let link = ValueLink(.answer(.refused("never asked")))
        let tools = OwnerTools(table: Fixture.table, context: context(link))
        tools.standardInputFree = true
        let markerFolder = home.appendingPathComponent(marker, isDirectory: true)
        try FileManager.default.createDirectory(at: markerFolder, withIntermediateDirectories: true)
        let markerFile = home.appendingPathComponent(marker + ".txt").path
        FileManager.default.createFile(atPath: markerFile, contents: Data())
        let cases: [[String: JSONValue]] = [
            ["account": .string(marker), "from": .string(marker)],
            ["account": .string(marker), "delete": .string(marker)],
            ["account": .string(marker), "from": .string("file"), "path": .string(marker)],
            ["account": .string(marker), "from": .string("file"), "path": .string(markerFolder.path)],
            ["account": .string(marker), "from": .string("file"), "path": .string(markerFile)],
            ["account": .string(marker), "from": .string("file"), "path": .string(marker + "\u{0}")],
            ["account": .string(marker), "from": .string("stdin"), "path": .string(marker)],
            ["account": .string(marker), "from": .string("stdin")],
            ["account": .string(marker), "delete": .bool(true), "path": .string(marker)],
            ["account": .string("discord-example"), marker: .int(1)],
            ["account": .string("discord-example"), "token": .string(marker)],
            ["account": .string("discord-example"), "Bot_Secret": .string(marker)],
            ["account": .int(7), "from": .string("file"), "path": .string(marker)],
        ]
        for fields in cases {
            let (text, isError) = tools.call("save_bot_token", .object(fields))
            #expect(isError, "\(fields)")
            #expect(!text.contains(marker), "\(text)")
            #expect(!text.contains("zq"), "\(text)")
        }
        #expect(link.all.isEmpty)
        let (other, _) = tools.call("save_bot_token", .array([.string(marker)]))
        #expect(!other.contains(marker))
        #expect(tools.call("save_bot_token", .object(["account": .string("a"), "value": .string(marker)])).text
                == OwnerLinkTools.neverAField)
    }
}

// ------------------------------------------------------------ the tool's logic in the app

/// The app's engine as stand-ins: the fleet's accounts, whether the reading is current, and the hub's answer.
@MainActor
final class StandInDesk {
    var accounts = [SaveBotToken.Account(id: "discord-example", app: "discord", state: "missing_token"),
                    SaveBotToken.Account(id: "discord-live", app: "discord", state: "connected"),
                    SaveBotToken.Account(id: "whatsapp-example", app: "whatsapp")]
    var accountsFail = false
    var ready = true
    var receipt = SaveBotToken.Receipt(set: true, replaced: false)
    var failure: SaveBotToken.HubFailure?
    var reads = 0
    var saved: [(String, BotToken?)] = []
    /// The clipboard: what a read gives, how often it was read, its count now (another writer moves it), and the
    /// counts that each clear was given, with whether it cleared.
    var clipboard: SaveBotToken.Clipboard = .text(exampleToken, count: 41)
    var clipboardReads = 0
    var clipboardCount = 41
    var clears: [(Int, Bool)] = []
    /// The read cancels the call's task, as a caller that went away does.
    var cancelOnRead = false
    /// The send cancels the call's task: the caller went away while the hub took the token.
    var cancelOnSave = false
    /// The app's reading of the fleet stops being current while the read waits (macOS's question has no limit).
    var staleOnRead = false
    /// The call's task is cancelled before the clipboard's read: its caller went away while the call waited in line.
    var cancelOnAccounts = false

    var desk: SaveBotToken.Desk<BotToken, String> {
        SaveBotToken.Desk(token: { BotToken(pasted: $0) }, telegramToken: { BotToken(telegram: $0) },
                          isAccountID: { ChatApps.isAccountID($0) },
                          ready: { [self] in ready ? "hub-and-database" : nil },
                          accounts: { [self] place in
                              #expect(place == "hub-and-database")
                              reads += 1
                              if accountsFail { throw SaveBotToken.HubFailure.noAnswer }
                              if cancelOnAccounts { withUnsafeCurrentTask { $0?.cancel() } }
                              return accounts
                          },
                          save: { [self] _, account, token in
                              saved.append((account, token))
                              if cancelOnSave { withUnsafeCurrentTask { $0?.cancel() } }
                              if let failure { throw failure }
                              return receipt
                          },
                          readClipboard: { [self] in
                              clipboardReads += 1
                              // As the connection's end does while macOS's question waits for the owner.
                              if cancelOnRead { withUnsafeCurrentTask { $0?.cancel() } }
                              if staleOnRead { ready = false }
                              return clipboard
                          },
                          clearClipboard: { [self] count in
                              let cleared = count == clipboardCount
                              clears.append((count, cleared))
                              return cleared
                          })
    }

    func answer(_ fields: [String: JSONValue], _ value: String?) async -> OwnerChannel.Answer {
        await SaveBotToken.answer(fields: fields, value: value.map { OwnerChannel.Value(copying: Array($0.utf8)) },
                                  desk: desk)
    }
}

@MainActor
struct OwnerSaveBotTokenTests {
    let save: [String: JSONValue] = ["account": .string("discord-example"), "from": .string("file")]

    @Test func aSaveSendsTheTokenAndAnswersTheReceipt() async {
        let app = StandInDesk()
        #expect(await app.answer(save, "  " + exampleToken + "\n")
                == .result(.object(["account": .string("discord-example"), "set": .bool(true), "replaced": .bool(false)])))
        #expect(app.saved.count == 1 && app.saved.first?.0 == "discord-example")
        #expect(app.saved.first?.1 == BotToken(pasted: exampleToken))
        app.receipt = .init(set: true, replaced: true)
        #expect(await app.answer(save, exampleToken)
                == .result(.object(["account": .string("discord-example"), "set": .bool(true), "replaced": .bool(true)])))
    }

    /// A Telegram bot takes a token of Telegram's form, from a file and from the clipboard, and each app's token goes
    /// only to a bot of that app, as the hub's own check says (CHAT-APPS.md 19.1).
    @Test func aTelegramBotTakesATelegramTokenAndNoOther() async {
        let app = StandInDesk()
        app.accounts.append(.init(id: "telegram-example", app: "telegram", state: "missing_token"))
        let telegram: [String: JSONValue] = ["account": .string("telegram-example"), "from": .string("file")]
        #expect(await app.answer(telegram, exampleTelegramToken + "\n")
                == .result(.object(["account": .string("telegram-example"), "set": .bool(true), "replaced": .bool(false)])))
        #expect(app.saved.count == 1 && app.saved.first?.1 == BotToken(telegram: exampleTelegramToken))
        #expect(await app.answer(telegram, exampleToken) == .refused(SaveBotToken.notToken))
        #expect(await app.answer(save, exampleTelegramToken) == .refused(SaveBotToken.notToken))
        #expect(await app.answer(telegram, "7000000001:short") == .refused(SaveBotToken.notToken))
        #expect(app.saved.count == 1)
        #expect(SaveBotToken.hasTelegramParts(exampleTelegramToken) && !SaveBotToken.hasTelegramParts(exampleToken))
        #expect(!SaveBotToken.hasTelegramParts("bot" + exampleTelegramToken))
        #expect(!SaveBotToken.hasTelegramParts(exampleTelegramToken + ":c") && !SaveBotToken.hasTokenParts(exampleTelegramToken))
        // From the clipboard, read after the account: its sentence is of the account's app.
        let clip: [String: JSONValue] = ["account": .string("telegram-example"), "from": .string("clipboard")]
        app.clipboard = .text(exampleToken, count: 41)
        #expect(await app.answer(clip, nil) == .refused(SaveBotToken.notOnClipboardTelegram))
        app.clipboard = .text(exampleTelegramToken, count: 41)
        #expect(await app.answer(clip, nil) == .result(.object(["account": .string("telegram-example"), "set": .bool(true),
                                                                 "replaced": .bool(false), "clipboard": .string("cleared")])))
        #expect(app.saved.count == 2 && app.saved.last?.1 == BotToken(telegram: exampleTelegramToken))
    }

    @Test func aDeleteSendsNil() async {
        let app = StandInDesk()
        app.receipt = .init(set: false, replaced: true)
        #expect(await app.answer(["account": .string("discord-example"), "delete": .bool(true)], nil)
                == .result(.object(["account": .string("discord-example"), "set": .bool(false), "replaced": .bool(true)])))
        #expect(app.saved.count == 1 && app.saved.first?.1 == nil)
        #expect(await app.answer(["account": .string("discord-example"), "delete": .bool(true)], exampleToken)
                == .refused(SaveBotToken.deleteTakesNone))
        #expect(app.saved.count == 1)
    }

    @Test func eachRefusalBeforeTheSend() async {
        let app = StandInDesk()
        #expect(await app.answer(["account": .string("discord-other"), "from": .string("file")], exampleToken)
                == .refused(SaveBotToken.noAccount))
        #expect(await app.answer(["account": .string("Not An Id"), "from": .string("file")], exampleToken)
                == .refused(SaveBotToken.noAccount))
        #expect(await app.answer(["account": .string("whatsapp-example"), "from": .string("file")], exampleToken)
                == .refused(SaveBotToken.notBotApp))
        #expect(await app.answer(save, "not a token") == .refused(SaveBotToken.notToken))
        // Bytes that are not UTF-8 get the same sentence as a text that is no token.
        let notUTF8 = await SaveBotToken.answer(fields: save, value: OwnerChannel.Value(copying: [0xFF, 0x41]),
                                                desk: app.desk)
        #expect(notUTF8 == .refused(SaveBotToken.notToken))
        #expect(await app.answer(save, nil) == .refused(SaveBotToken.noValue))
        #expect(await app.answer(["account": .string("discord-example")], exampleToken)
                == .refused(SaveBotToken.needsFrom))
        #expect(await app.answer(save.merging(["path": .string("/tmp/x")]) { $1 }, exampleToken)
                == .refused(SaveBotToken.appTakesNoPath))
        #expect(await app.answer(save.merging(["token": .string("x")]) { $1 }, exampleToken)
                == .refused(OwnerLinkTools.neverAField))
        #expect(await app.answer(save.merging(["force": .bool(true)]) { $1 }, exampleToken)
                == .refused(SaveBotToken.only))
        #expect(await app.answer(save.merging(["replace": .string("yes")]) { $1 }, exampleToken)
                == .refused(SaveBotToken.replaceWord))
        // The token as the account: no id has a token's form, and the value is compared with nothing that was sent.
        #expect(await app.answer(["account": .string(exampleToken), "from": .string("file")], exampleToken)
                == .refused(SaveBotToken.noAccount))
        #expect(await app.answer(["account": .string(String(exampleToken.prefix(20))), "from": .string("file")],
                                 exampleToken) == .refused(SaveBotToken.noAccount))
        // An id of the wrong form is refused before the value is read: even with no value part.
        #expect(await app.answer(["account": .string("Not An Id"), "from": .string("file")], nil)
                == .refused(SaveBotToken.noAccount))
        #expect(app.saved.isEmpty && app.reads == 2)
    }

    /// **The value is compared with nothing that the caller sent**: an account whose id is a part of the token is an
    /// account like any other, and its save goes.
    @Test func anAccountWhoseIdIsAPartOfTheTokenIsSaved() async {
        let app = StandInDesk()
        let part = String(repeating: "b", count: 20)
        #expect(exampleToken.contains(part) && ChatApps.isAccountID(part))
        app.accounts.append(.init(id: part, app: "discord", state: nil))
        #expect(await app.answer(["account": .string(part), "from": .string("file")], exampleToken)
                == .result(.object(["account": .string(part), "set": .bool(true), "replaced": .bool(false)])))
        #expect(app.saved.count == 1)
    }

    /// **Only a text with the parts of a Discord bot token is one**: three parts with two dots, the first a number of
    /// 15 to 22 digits in base64. A key of another service, which the hub's own form would take, is refused with the
    /// token's one sentence, and nothing is sent.
    @Test func onlyATextWithABotTokensPartsIsAToken() async {
        #expect(SaveBotToken.hasTokenParts(exampleToken))
        let id = Data("198622483471925248".utf8).base64EncodedString()
        let rest = String(repeating: "b", count: 29)
        let others = [
            String(repeating: "a", count: 64),                                  // a 64-character key
            "tskey-auth-" + String(repeating: "k", count: 50),                 // a key with a name in front
            String(repeating: "A", count: 30) + "." + rest,                    // one dot
            id + ".Cl2FMQ." + rest + ".more",                                  // four parts
            id + ".." + rest,                                                  // an empty part
            Data("not-a-number-here.".utf8).base64EncodedString() + ".Cl2FMQ." + rest,
            Data("1234567890".utf8).base64EncodedString().replacingOccurrences(of: "=", with: "") + ".Cl2FMQ." + rest,
            Data(String(repeating: "7", count: 30).utf8).base64EncodedString() + ".Cl2FMQ." + rest,
        ]
        let app = StandInDesk()
        for other in others {
            #expect(!SaveBotToken.hasTokenParts(other), "\(other.prefix(14))")
            #expect(await app.answer(save, other) == .refused(SaveBotToken.notToken))
        }
        #expect(app.saved.isEmpty && app.reads == 0)
    }

    /// **The program passes `replace` on to the app** when it is given, and never the path.
    @Test func theProgramPassesReplaceOnAndNeverThePath() {
        let fields: [String: JSONValue] = ["account": .string("discord-example"), "from": .string("file"),
                                           "path": .string("/tmp/example"), "replace": .bool(true)]
        guard case .success(let plan) = SaveBotToken.plan(fields) else { Issue.record("refused"); return }
        #expect(plan.send["replace"] == .bool(true) && plan.send["path"] == nil)
        guard case .success(let plain) = SaveBotToken.plan(fields.filter { $0.key != "replace" }) else {
            Issue.record("refused"); return
        }
        #expect(plain.send["replace"] == nil && plain.send["path"] == nil)
    }

    @Test func aStaleReadingSendsNothing() async {
        let app = StandInDesk()
        app.ready = false
        #expect(await app.answer(save, exampleToken) == .refused(SaveBotToken.notReady))
        #expect(app.reads == 0 && app.saved.isEmpty)
    }

    @Test func theHubsFailures() async {
        let app = StandInDesk()
        app.failure = .refused(404, "no such chat app account")
        #expect(await app.answer(save, exampleToken)
                == .refused("The hub refused this call: no such chat app account. Nothing was saved."))
        app.failure = .refused(400, "the token " + exampleToken + " is bad")
        #expect(await app.answer(save, exampleToken) == .refused(SaveBotToken.hubRefusedPlain))
        app.failure = .refused(409, "discord-example is bad")
        #expect(await app.answer(save, exampleToken) == .refused(SaveBotToken.hubRefusedPlain))
        app.failure = .refused(409, String(repeating: "x", count: 201))
        #expect(await app.answer(save, exampleToken) == .refused(SaveBotToken.hubRefusedPlain))
        // A fault of the hub, no answer and an unreadable answer: the outcome is not known.
        for failure: SaveBotToken.HubFailure in [.refused(500, "internal error"), .refused(502, "bad gateway"),
                                                 .noAnswer, .unreadable] {
            app.failure = failure
            #expect(await app.answer(save, exampleToken) == .refused(SaveBotToken.notKnown), "\(failure)")
        }
        #expect(SaveBotToken.notKnown.contains("not known") && !SaveBotToken.notKnown.contains("chat_apps"))
        #expect(app.saved.count == 8)
    }

    /// The read of the accounts failed: nothing was sent, and the words say so.
    @Test func anUnreadAccountListSendsNothing() async {
        let app = StandInDesk()
        app.accountsFail = true
        #expect(await app.answer(save, exampleToken) == .refused(SaveBotToken.accountsUnread))
        #expect(SaveBotToken.accountsUnread.hasSuffix("Nothing was sent."))
        #expect(app.saved.isEmpty)
    }

    /// An older hub that does not say whether it replaced a token: `replaced` is null, never false.
    @Test func aReceiptWithNoReplacedIsNull() async {
        let app = StandInDesk()
        app.receipt = .init(set: true, replaced: nil)
        #expect(await app.answer(save, exampleToken)
                == .result(.object(["account": .string("discord-example"), "set": .bool(true), "replaced": .null])))
    }

    /// **`replace`**: a save for a bot that is connected now needs it; every other state does not; a delete takes
    /// none.
    @Test func replaceIsNeededOnlyForAConnectedBot() async {
        let app = StandInDesk()
        let live: [String: JSONValue] = ["account": .string("discord-live"), "from": .string("file")]
        #expect(await app.answer(live, exampleToken) == .refused(SaveBotToken.connected))
        #expect(app.saved.isEmpty)
        app.receipt = .init(set: true, replaced: true)
        #expect(await app.answer(live.merging(["replace": .bool(true)]) { $1 }, exampleToken)
                == .result(.object(["account": .string("discord-live"), "set": .bool(true), "replaced": .bool(true)])))
        #expect(app.saved.count == 1 && app.saved.last?.0 == "discord-live")
        // Not connected: no replace needed, and replace true is allowed too.
        #expect(await app.answer(save, exampleToken) != .refused(SaveBotToken.connected))
        #expect(await app.answer(save.merging(["replace": .bool(true)]) { $1 }, exampleToken)
                != .refused(SaveBotToken.connected))
        #expect(app.saved.count == 3)
        // A delete takes no replace; a delete of a connected bot needs none.
        #expect(await app.answer(["account": .string("discord-live"), "delete": .bool(true), "replace": .bool(true)],
                                 nil) == .refused(SaveBotToken.deleteTakesNone))
        #expect(app.saved.count == 3)
        app.receipt = .init(set: false, replaced: true)
        #expect(await app.answer(["account": .string("discord-live"), "delete": .bool(true)], nil)
                == .result(.object(["account": .string("discord-live"), "set": .bool(false), "replaced": .bool(true)])))
    }

    /// **The board's refusals quote nothing**: the marker as each field's value, as an unknown field's name, as a path,
    /// as the value and in the hub's words.
    @Test func theBoardsRefusalsQuoteNothing() async {
        let app = StandInDesk()
        let board = SetupBoard(read: { OwnerSetupBoardTests.facts() }, show: { _, _ in nil })
        let desk = app.desk
        board.add(set: "owner", tool: SaveBotToken.name, value: .optional) { fields, value in
            await SaveBotToken.answer(fields: fields, value: value, desk: desk)
        }
        let cases: [([String: JSONValue], String?)] = [
            (["account": .string(marker), "from": .string("file")], exampleToken),
            (["account": .string(marker), "from": .string(marker)], exampleToken),
            (["account": .string(marker), "delete": .string(marker)], nil),
            (["account": .string(marker), "delete": .bool(true)], nil),
            (["account": .string("discord-example"), "from": .string("file"), "path": .string(marker)], exampleToken),
            (["account": .string("discord-example"), "from": .string("file"), marker: .int(1)], exampleToken),
            (["account": .string("discord-example"), "secret": .string(marker)], exampleToken),
            (["account": .string("discord-example"), "from": .string("file")], marker),
            (["account": .string("discord-example"), "from": .string("stdin")], marker + " " + exampleToken),
            (["account": .string(marker), "from": .string("file")], marker),
        ]
        app.failure = .refused(400, "never reached")
        for (fields, value) in cases {
            let answer = await board.answer(.init(set: "owner", tool: SaveBotToken.name, fields: fields),
                                            value: value.map { OwnerChannel.Value(copying: Array($0.utf8)) })
            guard case .refused(let words) = answer else { Issue.record("taken: \(fields)"); continue }
            #expect(!words.contains(marker) && !words.contains("zq"), "\(words)")
        }
        #expect(app.saved.isEmpty)
        // The hub's words that hold the account are not passed on.
        app.failure = .refused(400, "refused " + marker)
        let hub = await board.answer(.init(set: "owner", tool: SaveBotToken.name,
                                           fields: ["account": .string(marker), "from": .string("file")]),
                                     value: OwnerChannel.Value(copying: Array(exampleToken.utf8)))
        #expect(hub == .refused(SaveBotToken.noAccount))
        app.accounts.append(.init(id: marker, app: "discord"))
        let said = await board.answer(.init(set: "owner", tool: SaveBotToken.name,
                                            fields: ["account": .string(marker), "from": .string("file")]),
                                      value: OwnerChannel.Value(copying: Array(exampleToken.utf8)))
        #expect(said == .refused(SaveBotToken.hubRefusedPlain))
    }

    /// **No input schema of a link tool has a field of a value's kind.**
    @Test func noLinkToolHasAFieldNamedLikeAValue() {
        func names(_ schema: JSONValue) -> [String] {
            var found: [String] = []
            if let properties = schema["properties"]?.object {
                for (key, inner) in properties {
                    found.append(key)
                    found += names(inner)
                }
            }
            if let items = schema["items"] { found += names(items) }
            return found
        }
        let tools = OwnerSetupTools.tools + OwnerLinkTools.tools
        #expect(tools.count == 9)
        for tool in tools {
            for name in names(tool.inputSchema) {
                #expect(!OwnerLinkTools.namedLikeAValue(name), "\(tool.name): \(name)")
            }
        }
        #expect(OwnerLinkTools.namedLikeAValue("Bot_TOKEN") && OwnerLinkTools.namedLikeAValue("apiKey")
                && OwnerLinkTools.namedLikeAValue("PassWord") && OwnerLinkTools.namedLikeAValue("value"))
    }
}

/// **`from` clipboard in the app** (the secrets plan, step C), with the stand-in desk's clipboard: no test reads or
/// writes the real one.
@MainActor
struct OwnerSaveBotTokenClipboardTests {
    let clip: [String: JSONValue] = ["account": .string("discord-example"), "from": .string("clipboard")]

    private func saved(_ cleared: String, replaced: Bool = false) -> OwnerChannel.Answer {
        .result(.object(["account": .string("discord-example"), "set": .bool(true), "replaced": .bool(replaced),
                         "clipboard": .string(cleared)]))
    }

    @Test func aClipboardSaveSendsAndClearsIt() async {
        let app = StandInDesk()
        app.clipboard = .text("  " + exampleToken + "\n", count: 41)
        #expect(await app.answer(clip, nil) == saved("cleared"))
        #expect(app.saved.count == 1 && app.saved.first?.1 == BotToken(pasted: exampleToken))
        #expect(app.clipboardReads == 1)
        #expect(app.clears.map(\.0) == [41] && app.clears.map(\.1) == [true])
    }

    /// Something else wrote the clipboard between the read and the clear: the clear leaves it, and the answer says so.
    @Test func aClipboardThatMovedSinceTheReadIsKept() async {
        let app = StandInDesk()
        app.clipboardCount = 42
        #expect(await app.answer(clip, nil) == saved("kept"))
        #expect(app.saved.count == 1)
        #expect(app.clears.map(\.0) == [41] && app.clears.map(\.1) == [false])
    }

    /// No text, and a text that is no token (another service's key of 64 characters among them), get one sentence.
    @Test func noTextAndNoTokenGetOneSentence() async {
        let app = StandInDesk()
        let over = exampleToken + String(repeating: " ", count: OwnerChannel.valueMax)
        for copied: SaveBotToken.Clipboard in [.nothing, .text("not a token", count: 1),
                                               .text(String(repeating: "a", count: 64), count: 1),
                                               .text("tskey-auth-" + String(repeating: "k", count: 50), count: 1),
                                               .text(over, count: 1)] {
            app.clipboard = copied
            #expect(await app.answer(clip, nil) == .refused(SaveBotToken.notOnClipboard))
        }
        #expect(app.clipboardReads == 5 && app.saved.isEmpty && app.clears.isEmpty)
        #expect(SaveBotToken.notOnClipboard.contains("Developer Portal")
                && SaveBotToken.notOnClipboard.hasSuffix("Nothing was sent."))
    }

    @Test func aClipboardThatMacOSDoesNotLetTheAppReadSendsNothing() async {
        let app = StandInDesk()
        app.clipboard = .notAllowed
        #expect(await app.answer(clip, nil) == .refused(SaveBotToken.clipboardDenied))
        #expect(SaveBotToken.clipboardDenied.contains("Privacy & Security"))
        #expect(app.saved.isEmpty && app.clears.isEmpty)
    }

    /// **A call that ended while the read waited** (macOS's question has no limit; the program waits about a minute)
    /// sends nothing and clears nothing, though the clipboard held a token.
    @Test func aCallThatEndedDuringTheReadSendsNothing() async {
        let app = StandInDesk()
        app.cancelOnRead = true
        let clip = clip
        let answer = await Task { await app.answer(clip, nil) }.value
        #expect(answer == .refused(SaveBotToken.endedDuringRead))
        #expect(app.clipboardReads == 1 && app.saved.isEmpty && app.clears.isEmpty)
        // The same call, not cancelled, goes.
        app.cancelOnRead = false
        #expect(await Task { await app.answer(clip, nil) }.value == saved("cleared"))
    }

    /// **A call whose caller went away before the read reads no clipboard**: while macOS's question of an earlier call
    /// is up, later calls wait in line, and one that nobody waits for any more must bring no further question.
    @Test func aCallThatEndedBeforeTheReadReadsNoClipboard() async {
        let app = StandInDesk()
        app.cancelOnAccounts = true
        let clip = clip
        #expect(await Task { await app.answer(clip, nil) }.value == .refused(SaveBotToken.endedDuringRead))
        #expect(app.clipboardReads == 0 && app.saved.isEmpty && app.clears.isEmpty)
    }

    /// **One read of the clipboard at a time**: a read that comes while another is in flight (macOS's question is up)
    /// gets `busy` and reads nothing, and the next one after it reads again.
    @Test func theGateGivesOneReadAtATime() {
        let gate = SaveBotToken.ClipboardGate()
        var reads = 0
        var inner: SaveBotToken.Clipboard?
        let outer = gate.read {
            reads += 1
            inner = gate.read { reads += 1; return .nothing }
            return .text(exampleToken, count: 7)
        }
        #expect(outer == .text(exampleToken, count: 7) && inner == .busy && reads == 1)
        #expect(gate.read { reads += 1; return .nothing } == .nothing && reads == 2)
    }

    /// A call that finds another read in flight gets its own fixed sentence, and nothing is sent or cleared.
    @Test func aCallDuringAnotherReadIsToldToWait() async {
        let app = StandInDesk()
        app.clipboard = .busy
        #expect(await app.answer(clip, nil) == .refused(SaveBotToken.clipboardBusy))
        #expect(app.clipboardReads == 1 && app.saved.isEmpty && app.clears.isEmpty)
        #expect(SaveBotToken.clipboardBusy.contains("Allow Paste") && SaveBotToken.clipboardBusy.hasSuffix("Nothing was sent."))
    }

    /// **The reading of before the read is the one that sends**: while macOS's question is up the app's reading cannot
    /// renew, so a reading that is not current after the read does not stop a save that the owner just allowed.
    @Test func aReadingThatWentStaleDuringTheReadStillSends() async {
        let app = StandInDesk()
        app.staleOnRead = true
        #expect(await app.answer(clip, nil) == saved("cleared"))
        #expect(app.clipboardReads == 1 && app.saved.count == 1 && app.clears.count == 1)
    }

    /// **The fixed sentences of the clipboard say what the documents say**: where the owner's setting is, what an
    /// agent does when the outcome is not known, and that the agent never reads the clipboard itself.
    @Test func theClipboardsSentencesHoldTheirClauses() {
        #expect(SaveBotToken.clipboardDenied.contains("System Settings, Privacy & Security, Paste from Other Apps"))
        #expect(SaveBotToken.notKnown.contains("with from clipboard the token is then still in the clipboard"))
        for clause in ["macOS may be asking the owner now", "press Allow Paste there",
                       "with from clipboard the token can still be in the clipboard",
                       "this one may have saved it and cleared the clipboard"] {
            #expect(SaveBotToken.notKnownHere.contains(clause), "\(clause)")
        }
        let description = SaveBotToken.tool.description
        #expect(description.contains("never read the clipboard yourself"))
        #expect(description.contains("which the app reads itself") && description.contains("the owner presses Allow Paste"))
        // **The part about the token and its three sources, held word for word**, between the sentence before it
        // and the one after it. Two rules in it hold for every source: the token never goes through a chat, and a
        // pipe is never a read of the clipboard (`pbpaste` would put the token on a pipe with no gate).
        let part = "The token is never a field of this tool and never a word of a command line. You never see it, type "
            + "it or repeat it, and you never ask the owner to paste it into a chat. It comes from this Mac, from a "
            + "file or a pipe that founderizer-cli reads and sends to the Founderizer app as a part after the request, "
            + "or from the clipboard, which the app reads itself. from file, with path: a regular file of this Mac "
            + "that holds only the token (at most 64 KiB). from stdin: only with founderizer-cli write, the standard "
            + "input from a program's pipe (never pbpaste or another read of the clipboard: for the clipboard, use "
            + "from clipboard), never an echo or a here-string of the token; the MCP form refuses it. from clipboard: "
            + "the app reads the clipboard itself, after every other check passed, once the owner copied the bot's "
            + "token (in Discord's Developer Portal, or from Telegram's BotFather) and said so; never read the "
            + "clipboard yourself."
        #expect(description.contains("this tool does not make the account. " + part + " When macOS asks whether "
                                     + "Founderizer may access the pasteboard, the owner presses Allow Paste."))
        // Each rule is said one time.
        for rule in ["into a chat", "paste it", "never read the clipboard yourself", "pbpaste",
                     "never a field of this tool", "the MCP form refuses it"] {
            #expect(description.components(separatedBy: rule).count == 2, "\(rule)")
        }
        #expect(!description.contains("paste the token"))
        #expect(!description.contains("\n") && !description.contains("  "))
    }

    /// **A read of the clipboard prints as hidden** in every way that Swift prints a value: its text is a secret, or
    /// something else that the owner copied. A plain enum with the same text shows that each check can fail.
    @Test func aReadOfTheClipboardPrintsAsHidden() {
        enum Plain { case text(String, count: Int) }
        func printed<T>(_ value: T) -> [String] {
            var dumped = ""
            dump(value, to: &dumped)
            return [String(describing: value), String(reflecting: value), "\(value)", dumped]
        }
        for text in printed(SaveBotToken.Clipboard.text(marker, count: 3)) { #expect(!text.contains(marker), "\(text)") }
        for text in printed(Plain.text(marker, count: 3)) { #expect(text.contains(marker)) }
    }

    /// **A call that ended while the hub took the token** leaves the clipboard as it is: its caller got no answer and
    /// calls again in the same way, and that call must still find the token.
    @Test func aCallThatEndedDuringTheSendClearsNothing() async {
        let app = StandInDesk()
        app.cancelOnSave = true
        let clip = clip
        #expect(await Task { await app.answer(clip, nil) }.value == saved("kept"))
        #expect(app.saved.count == 1 && app.clears.isEmpty)
        app.cancelOnSave = false
        app.receipt = .init(set: true, replaced: true)
        #expect(await Task { await app.answer(clip, nil) }.value == saved("cleared", replaced: true))
        #expect(app.saved.count == 2 && app.clears.count == 1)
    }

    @Test func aValuePartWithTheClipboardIsRefusedUnread() async {
        let app = StandInDesk()
        #expect(await app.answer(clip, exampleToken) == .refused(SaveBotToken.clipboardTakesNoPart))
        #expect(await app.answer(clip.merging(["path": .string("/tmp/example")]) { $1 }, nil)
                == .refused(SaveBotToken.appTakesNoPath))
        #expect(app.clipboardReads == 0 && app.saved.isEmpty)
    }

    /// **The clipboard is read last**: every call that another check refuses, and every delete, reads none of it.
    @Test func aCallThatAnotherCheckRefusesReadsNoClipboard() async {
        let app = StandInDesk()
        let cases: [([String: JSONValue], OwnerChannel.Answer)] = [
            (["account": .string("discord-other"), "from": .string("clipboard")], .refused(SaveBotToken.noAccount)),
            (["account": .string("Not An Id"), "from": .string("clipboard")], .refused(SaveBotToken.noAccount)),
            (["account": .string("whatsapp-example"), "from": .string("clipboard")],
             .refused(SaveBotToken.notBotApp)),
            (["account": .string("discord-live"), "from": .string("clipboard")], .refused(SaveBotToken.connected)),
            (clip.merging(["force": .bool(true)]) { $1 }, .refused(SaveBotToken.only)),
            (clip.merging(["replace": .string("yes")]) { $1 }, .refused(SaveBotToken.replaceWord)),
            (clip.merging(["delete": .bool(true)]) { $1 }, .refused(SaveBotToken.deleteTakesNone)),
        ]
        for (fields, refusal) in cases {
            #expect(await app.answer(fields, nil) == refusal, "\(fields)")
        }
        app.receipt = .init(set: false, replaced: true)
        #expect(await app.answer(["account": .string("discord-example"), "delete": .bool(true)], nil)
                == .result(.object(["account": .string("discord-example"), "set": .bool(false),
                                    "replaced": .bool(true)])))
        app.ready = false
        #expect(await app.answer(clip, nil) == .refused(SaveBotToken.notReady))
        app.ready = true
        app.accountsFail = true
        #expect(await app.answer(clip, nil) == .refused(SaveBotToken.accountsUnread))
        #expect(app.clipboardReads == 0 && app.clears.isEmpty && app.saved.count == 1)
    }

    /// After a refusal of the hub, or an outcome that is not known, the clipboard stays: the same call must still work.
    /// A receipt that says no token is set clears nothing either.
    @Test func aSaveThatTheHubDidNotConfirmClearsNothing() async {
        let app = StandInDesk()
        for failure: SaveBotToken.HubFailure in [.refused(404, "no such chat app account"), .refused(500, "fault"),
                                                 .refused(502, "bad gateway"), .noAnswer, .unreadable] {
            app.failure = failure
            guard case .refused = await app.answer(clip, nil) else { Issue.record("taken: \(failure)"); continue }
        }
        #expect(app.saved.count == 5 && app.clipboardReads == 5 && app.clears.isEmpty)
        app.failure = nil
        app.receipt = .init(set: false, replaced: false)
        #expect(await app.answer(clip, nil)
                == .result(.object(["account": .string("discord-example"), "set": .bool(false),
                                    "replaced": .bool(false), "clipboard": .string("kept")])))
        #expect(app.clears.isEmpty)
    }

    /// **The clipboard's text is in no refusal**: a marker as the text, and the hub's words that hold the token.
    @Test func theClipboardsTextIsInNoRefusal() async {
        let app = StandInDesk()
        for copied in [marker, marker + " " + exampleToken, exampleToken + "." + marker] {
            app.clipboard = .text(copied, count: 1)
            guard case .refused(let words) = await app.answer(clip, nil) else { Issue.record("taken"); continue }
            #expect(!words.contains(marker) && !words.contains("zq"), "\(words)")
        }
        app.clipboard = .text(exampleToken, count: 1)
        app.failure = .refused(400, "the token " + exampleToken + " is bad")
        #expect(await app.answer(clip, nil) == .refused(SaveBotToken.hubRefusedPlain))
        #expect(app.clears.isEmpty)
    }
}

/// **The whole way**: the program's tool, its file read, the real exchange on a socket of the test's own, the board
/// and the tool's logic with a stand-in engine.
final class OwnerSaveBotTokenLinkTests {
    let home = Fixture.home()
    deinit { try? FileManager.default.removeItem(at: home) }

    @Test func aSaveGoesTheWholeWay() async throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("fzw-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("app.sock").path
        let (board, app) = await MainActor.run {
            let app = StandInDesk()
            let board = SetupBoard(read: { OwnerSetupBoardTests.facts() }, show: { _, _ in nil })
            let desk = app.desk
            board.add(set: "owner", tool: SaveBotToken.name, value: .optional) { fields, value in
                await SaveBotToken.answer(fields: fields, value: value, desk: desk)
            }
            return (board, app)
        }
        let listener = ChannelListener(path: path, check: StandInCheck(takes: true)) { request, value in
            await board.answer(request, value: value)
        }
        defer { listener.stop() }
        #expect(listener.start() == .listening)
        let appLink = AppLink(exchange: { request, value in
            ChannelClient.exchange(path: path, request: request, value: value, check: StandInCheck(takes: true))
        }, start: { false }, pause: {}, tries: 0)
        let context = OwnerContext(hubSetting: { nil }, transport: Fixture.transport(), home: home,
                                   userAgent: "founderizer-cli/test", ownBuild: nil, startedBuild: { nil },
                                   clientLabel: { "founderizer-cli/1/test" }, appLink: appLink)
        let tools = OwnerTools(table: Fixture.table, context: context)
        let file = home.appendingPathComponent("bot-token.txt").path
        FileManager.default.createFile(atPath: file, contents: Data(exampleToken.utf8))
        let (text, isError) = await off {
            tools.call("save_bot_token", .object(["account": .string("discord-example"), "from": .string("file"),
                                                  "path": .string(file)]))
        }
        #expect(!isError, "\(text)")
        #expect(JSONValue.parse(text) == .object(["account": .string("discord-example"), "set": .bool(true),
                                                  "replaced": .bool(false)]))
        #expect(!text.contains(exampleToken))
        let saved = await MainActor.run { app.saved.map { ($0.0, $0.1 == BotToken(pasted: exampleToken)) } }
        #expect(saved.count == 1 && saved.first?.0 == "discord-example" && saved.first?.1 == true)
        // A value that is no token, the whole way: refused by the app, with nothing of it in the words.
        FileManager.default.createFile(atPath: file, contents: Data(marker.utf8))
        let (refused, failed) = await off {
            tools.call("save_bot_token", .object(["account": .string("discord-example"), "from": .string("file"),
                                                  "path": .string(file)]))
        }
        #expect(failed && refused == SaveBotToken.notToken && !refused.contains(marker))
        // replace goes on to the app when it is given.
        FileManager.default.createFile(atPath: file, contents: Data(exampleToken.utf8))
        let (again, _) = await off {
            tools.call("save_bot_token", .object(["account": .string("discord-example"), "from": .string("file"),
                                                  "path": .string(file), "replace": .bool(true)]))
        }
        #expect(JSONValue.parse(again)?["set"] == .bool(true))
    }
}
