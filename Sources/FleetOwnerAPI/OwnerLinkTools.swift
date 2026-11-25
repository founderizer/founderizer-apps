import Darwin
import Foundation

/// **The tools of the link that write** (the secrets plan, `agent-install-secrets-plan.md`, section 2): tools of the
/// program only, like the setup tools, and not in `owner_mcp.py`'s table. Their own list, not `OwnerSetupTools.names`,
/// because `OwnerCLI.setupTools` (the reads that `call` takes) reads that one: each tool here is a write
/// (`readOnlyHint` false), so only `founderizer-cli write` and the MCP form take it.
///
/// **A secret's value is never a field of a tool and never a word of a command line** (the owner, 14 November 2026:
/// "No, local only"). It comes from a file or a pipe on this Mac, which the program reads itself (`ValueSource`), and
/// goes to the app as the value part after the request line (`OwnerChannel.Value`); or from the clipboard, which the
/// app reads itself, in its own process (the secrets plan, step C). No tool gives a value back.
///
/// **The six tools.** `save_bot_token` (below): a Discord or Telegram bot's token to the hub. `prepare_problem_report`
/// (`OwnerProblemReport.swift`): the agent's own text into the app's report form, with no value. `save_secret`
/// (`OwnerSaveSecret.swift`, `OwnerSaveSecretApp.swift`): a new login or API key into the fleet's central vault,
/// with work that outlives its call (`LinkWork`). `grant_secret` (`OwnerGrantSecret.swift`): one secret to one
/// agent with the owner's signature, or its end, with no value; the app signs for it. `share_secret`
/// (`OwnerShareSecret.swift`): who may give one secret, with the owner's signature into the grantable pool, or its
/// end, with no value; the app signs for it. `answer_secret_request` (`OwnerAnswerSecret.swift`): the answer to an
/// agent's request for a secret with a secret of the list, after the signed gives of the call, with no value; the
/// app signs for it, in the line of writes that it shares with `grant_secret`.
///
/// **One more request writes on the link, and it is no tool of this list**: `answer_needs_you`, a tool of the table,
/// sends a door card's Run it once or Full access to the app, which signs that press with the owner key and sends it
/// (`OwnerAnswerDoor.swift`); every other answer of it goes to the hub. `writes` names it with the six.
public enum OwnerLinkTools {
    public static let names = [SaveBotToken.name, PrepareReport.name, SaveSecret.name, GrantSecret.name,
                               ShareSecret.name, AnswerSecret.name]
    public static let tools: [OwnerTable.Tool] = [SaveBotToken.tool, PrepareReport.tool, SaveSecret.tool,
                                                  GrantSecret.tool, ShareSecret.tool, AnswerSecret.tool]
    /// **Every request of the link that writes**: the six tools of `names`, and `answer_needs_you` (`AnswerDoor`), a
    /// tool of the table whose one press, a door card's signed Run it once or Full access, the program sends on the
    /// link (`OwnerTools.call`). A request of these that went out and got no answer has its tool's own words
    /// (`AppLink.call`, `notKnownHere(_:)`).
    public static let writes = names + [AnswerDoor.name]

    /// **The program's words for a link write whose request went out and got no answer**: each tool's own, because
    /// what may have happened is its own (a token saved, a report shown, a save of a secret begun, a grant signed
    /// or written, a pool statement signed or a standing written, grants signed and written and a request
    /// answered, a door card's press signed and answered).
    ///
    /// **A case for each tool, by its name, and no tool's words for another one.** A name with no case gets
    /// `notKnownOther`, which says only that the outcome is not known: it names no tool and no effect. Only a tool
    /// that `writes` gains with no case here can get it, and a test holds that each name has words of its own.
    /// `save_secret`'s words here are those of a save whose caller gave the id. The program gives two other forms
    /// itself (`AppLink.call`, `notKnown`): the one with the id, for a save whose id it made, and the words of a
    /// read of a save's state (`SaveSecret.notKnownState`).
    public static func notKnownHere(_ tool: String) -> String {
        switch tool {
        case SaveBotToken.name: return SaveBotToken.notKnownHere
        case PrepareReport.name: return PrepareReport.notKnownHere
        case SaveSecret.name: return SaveSecret.notKnownHere
        case GrantSecret.name: return GrantSecret.notKnownHere
        case ShareSecret.name: return ShareSecret.notKnownHere
        case AnswerSecret.name: return AnswerSecret.notKnownHere
        case AnswerDoor.name: return AnswerDoor.notKnownHere
        default: return notKnownOther
        }
    }

    /// The words for a lost answer of a link write that has no words of its own (`notKnownHere(_:)`): what the call
    /// asked for may be done or not, and nothing here says which, so the caller reads before it calls again.
    static let notKnownOther = "The Founderizer app did not answer in time, or the link ended, so the outcome of this "
        + "call is not known: the app may have done what the call asked. Read what the call changes before you call "
        + "again."

    /// **Whether a field's name is one of a value's kind**: it holds value, password, key, token or secret, in any
    /// letter case. Such a field is refused whatever it holds, with `neverAField`.
    public static func namedLikeAValue(_ name: String) -> Bool {
        let lower = name.lowercased()
        return ["value", "password", "key", "token", "secret"].contains { lower.contains($0) }
    }

    public static let neverAField = "A value is never a field of a tool: it comes from this Mac with from (file with "
        + "path, stdin, or clipboard). Nothing was sent."
}

// ------------------------------------------------------------ the sources, in the program

/// **The standard input of the program**, as a seam of its context (`OwnerContext.standardInput`): `main` gives this
/// process's own (`process`), and a test gives its own, so that no test reads the real standard input.
public struct StandardInput: Sendable {
    /// Whether the standard input is a terminal (`isatty`).
    public var isTerminal: @Sendable () -> Bool
    /// One read into the buffer: the bytes read, 0 at the end, below 0 for a failure.
    public var read: @Sendable (UnsafeMutableRawBufferPointer) -> Int

    public init(isTerminal: @escaping @Sendable () -> Bool,
                read: @escaping @Sendable (UnsafeMutableRawBufferPointer) -> Int) {
        self.isTerminal = isTerminal
        self.read = read
    }

    /// This process's standard input.
    public static let process = StandardInput(isTerminal: { isatty(0) == 1 }, read: { buffer in
        while true {
            let count = Darwin.read(0, buffer.baseAddress, buffer.count)
            if count < 0 && errno == EINTR { continue }
            return count
        }
    })

    /// No standard input: nothing comes. The default of a context, so that a context that names none reads nothing.
    public static let none = StandardInput(isTerminal: { false }, read: { _ in 0 })
}

/// **Where the program reads a value**: a regular file of this Mac, or its standard input from a pipe. Each one is
/// bounded by `OwnerChannel.valueMax`, and each refusal is a fixed sentence that quotes nothing of the request (not the
/// path). The program's own buffer is wiped before it returns; the value is in an `OwnerChannel.Value`.
public enum ValueSource {
    static var most: String { "\(OwnerChannel.valueMax / 1024) KiB" }

    static let isLink = "path names a link at its last part: name the file itself. Nothing was sent."
    static let missing = "No file is at path on this Mac. Nothing was sent."
    static let forbidden = "This program may not open the file at path: the system refused it (its mode, or a privacy "
        + "setting of macOS). Nothing was sent."
    static let notOpened = "The file at path could not be opened on this Mac. Nothing was sent."
    static let notRegular = "path does not name a regular file (it names a folder, a pipe, a device or a socket): name "
        + "a file that holds only the value. Nothing was sent."
    static let emptyFile = "The file at path is empty. Nothing was sent."
    static var largeFile: String { "The file at path is larger than \(most): such a file holds only the value. Nothing "
        + "was sent." }
    static let unreadFile = "The file at path could not be read on this Mac. Nothing was sent."
    static let terminal = "from stdin reads a pipe from a program, and the standard input here is a terminal: nothing "
        + "was read and nothing was sent. Never type or echo the value."
    static let emptyInput = "Nothing came on the standard input: from stdin reads a program's pipe to its end. Nothing "
        + "was sent."
    static var largeInput: String { "More than \(most) came on the standard input: a value is at most \(most). "
        + "Nothing was sent." }
    static let unreadInput = "The standard input could not be read. Nothing was sent."

    /// **A regular file**: opened read only, following no link at its last part, not blocking (a FIFO with no writer
    /// does not hold the program), not given to a child, and never the program's controlling terminal (`fstat` refuses
    /// a terminal device only after the open, so the open must not take it first); then only a regular file of 1 byte to `max`, of which at
    /// most `max` and one byte are read (a file that grew after its check is refused).
    public static func file(_ path: String, max: Int = OwnerChannel.valueMax) -> Result<OwnerChannel.Value,
                                                                                         OwnerChannel.Refusal> {
        guard LocalFile.callable(path) else { return .failure(.init(missing)) }
        let file = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_NOCTTY | O_CLOEXEC)
        guard file >= 0 else {
            switch errno {
            case ELOOP: return .failure(.init(isLink))
            case ENOENT, ENOTDIR: return .failure(.init(missing))
            case EACCES, EPERM: return .failure(.init(forbidden))
            default: return .failure(.init(notOpened))
            }
        }
        defer { close(file) }
        var info = stat()
        guard fstat(file, &info) == 0 else { return .failure(.init(unreadFile)) }
        guard info.st_mode & S_IFMT == S_IFREG else { return .failure(.init(notRegular)) }
        guard info.st_size > 0 else { return .failure(.init(emptyFile)) }
        guard info.st_size <= max else { return .failure(.init(largeFile)) }
        return bounded(max: max, empty: emptyFile, large: largeFile, unread: unreadFile) { buffer in
            while true {
                let count = Darwin.read(file, buffer.baseAddress, buffer.count)
                if count < 0 && errno == EINTR { continue }
                return count
            }
        }
    }

    /// **The standard input, from a pipe**, to its end: never a terminal, never empty, at most `max`.
    public static func standardInput(_ input: StandardInput,
                                     max: Int = OwnerChannel.valueMax) -> Result<OwnerChannel.Value,
                                                                                 OwnerChannel.Refusal> {
        guard !input.isTerminal() else { return .failure(.init(terminal)) }
        return bounded(max: max, empty: emptyInput, large: largeInput, unread: unreadInput, read: input.read)
    }

    /// Reads to the end, or to `max` and one byte, into a buffer of the program's own that is wiped before it returns.
    static func bounded(max: Int, empty: String, large: String, unread: String,
                        read: (UnsafeMutableRawBufferPointer) -> Int) -> Result<OwnerChannel.Value,
                                                                               OwnerChannel.Refusal> {
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: max + 1, alignment: 1)
        defer {
            if let base = buffer.baseAddress { memset_s(base, buffer.count, 0, buffer.count) }
            buffer.deallocate()
        }
        var total = 0
        while total < buffer.count {
            let count = read(UnsafeMutableRawBufferPointer(rebasing: buffer[total...]))
            if count < 0 { return .failure(.init(unread)) }
            if count == 0 { break }
            total += count
        }
        guard total > 0 else { return .failure(.init(empty)) }
        guard total <= max else { return .failure(.init(large)) }
        return .success(OwnerChannel.Value(copying: UnsafeRawBufferPointer(rebasing: buffer[0..<total])))
    }
}

// ------------------------------------------------------------ save_bot_token

/// **`save_bot_token`**: a Discord or Telegram bot's token to the hub, from a file, a pipe or the clipboard of this
/// Mac, or its delete. The program checks the fields and reads a file or a pipe (`plan`, `ValueSource`); the app checks
/// both again, because a process on the socket can send any bytes, reads the clipboard itself, and sends the token as
/// its own Discord or Telegram page does (`answer`, with the app's own client in `Desk`). The program takes no command
/// lock of `~/.founderizer/lock`: the app does the write, as its form does.
///
/// **`replace`, in the form that the app can keep** (the plan's section 2): nothing says before the send whether the hub
/// holds a token file (the route learns it only in its act). But the chat apps page that the tool reads gives each
/// account's state from the bridge, and a bot whose state is `connected` has a token that works: a save over it leaves
/// the old token nowhere. So a save for a connected bot needs `replace` true; in every other state a save replaces what
/// is there, and the answer's `replaced`, from the hub's receipt, says so. The state is the bridge's last report and can
/// be late. This stops an agent's mistake, and no attack.
///
/// **No search on the value.** The app compares the value with nothing that the caller sent: a compare would tell a
/// caller one bit of a file's text for each call. Its answers say only whether the bytes have the form of a bot token.
public enum SaveBotToken {
    public static let name = "save_bot_token"
    public static let fields = ["account", "from", "path", "replace", "delete"]

    public static let tool = OwnerTable.Tool(
        name: name, description: """
            People: Saves the token of a Discord or Telegram bot of the fleet on the hub, or deletes it. account: the \
            id of a \
            Discord or Telegram chat account that the fleet has already (fleet_read page chat_apps); this tool does \
            not make the account. The token is never a field of this tool and never a word of a command line. You \
            never see it, type it or repeat it, and you never ask the owner to paste it into a chat. It comes from \
            this Mac, from a \
            file or a pipe that founderizer-cli reads and sends to the Founderizer app as a part after the request, or \
            from the clipboard, which the app reads itself. from file, with path: a regular file \
            of this Mac that holds only the token (at most 64 KiB). from stdin: only with founderizer-cli write, the \
            standard input from a program's pipe (never pbpaste or another read of the clipboard: for the clipboard, \
            use from clipboard), never an echo or a here-string of the token; the MCP form refuses \
            it. from clipboard: the app reads the clipboard itself, after every other check passed, once the owner \
            copied the bot's token (in Discord's Developer Portal, or from Telegram's BotFather) and said so; never \
            read the clipboard yourself. When macOS asks whether Founderizer may access the \
            pasteboard, the owner presses Allow Paste. After a clipboard save the app clears the clipboard when \
            nothing else changed it since the read, and the answer's clipboard says cleared or kept. replace true is \
            needed only when the bot is connected now: then the hub holds a token that works, and \
            a save replaces it. In every other state a save replaces what is there, and replaced says so; the state \
            is the bridge's last report and can be late. delete true removes the bot's token from the hub and takes \
            no from, no path and no replace. The app checks that the bytes have the form of a bot token of the \
            account's app. It answers account, set (whether the hub holds a token for the bot now) and replaced \
            (whether one was there \
            before, or null when the hub does not say), and never the token, its length or a fingerprint of it.
            """,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "account": .object(["type": .string("string")]),
                "from": .object(["type": .string("string"), "enum": .array([.string("file"), .string("stdin"),
                                                                                .string("clipboard")])]),
                "path": .object(["type": .string("string")]),
                "replace": .object(["type": .string("boolean")]),
                "delete": .object(["type": .string("boolean")]),
            ]),
            "required": .array([.string("account")]),
            "additionalProperties": .bool(false),
        ]),
        annotations: .object(["readOnlyHint": .bool(false)]), kind: .swift, route: "", fields: [], what: name,
        revisionPage: nil, requestIDFromArguments: false, feature: nil)

    // The fixed sentences: each names only the tool's own fields, and none quotes anything that the caller sent.
    static let only = "save_bot_token takes only account, from, path, replace and delete. Nothing was sent."
    static let account = "account must be the id of a Discord or Telegram chat account of the fleet, as fleet_read(page="
        + "\"chat_apps\") gives it. Nothing was sent."
    static let deleteWord = "delete must be true or false. Nothing was sent."
    static let replaceWord = "replace must be true or false. Nothing was sent."
    static let fromWord = "from must be file, stdin or clipboard. Nothing was sent."
    static let pathWord = "path must be the file on this Mac that holds only the token. Nothing was sent."
    static let deleteTakesNone = "A delete takes no from, no path, no replace and no token: it removes the bot's token "
        + "from the hub. Nothing was sent."
    static let needsFrom = "save_bot_token needs from: file with path, stdin, or clipboard. The token is never a "
        + "field. Nothing was sent."
    static let fileNeedsPath = "from file needs path: the file on this Mac that holds only the token. Nothing was sent."
    static let pathOnlyWithFile = "path goes only with from file. Nothing was sent."
    static let appTakesNoPath = "The app takes no path: founderizer-cli reads the file itself and sends only its "
        + "bytes. Nothing was sent."
    public static let stdinInMCP = "from stdin is for founderizer-cli write, run from a shell with the token piped "
        + "from a program: in this MCP form the standard input carries the protocol. Use from file with path, or "
        + "from clipboard. Nothing was sent."
    static let noValue = "save_bot_token needs the token as a part after its request line, which founderizer-cli reads "
        + "with from (file or stdin). Nothing was sent."
    /// With `from` clipboard the app reads the clipboard itself: a value part as well would be a second token.
    static let clipboardTakesNoPart = "With from clipboard the app reads the clipboard itself, so it takes no part "
        + "after the request line. Nothing was sent."
    /// **One sentence for a clipboard with no text and for a text that is no token**, so that an answer says as little
    /// as it can about what the owner copied.
    /// A "Don't Allow Paste" in macOS's own question gives the same nothing as an empty clipboard, so it gets this
    /// sentence too.
    static let notOnClipboard = "The Founderizer app got no Discord bot token from the clipboard: nothing with a bot "
        + "token's parts (50 to 100 characters of A-Z a-z 0-9 . _ - in three parts with two dots, the first part the "
        + "bot's id) is copied, or macOS did not allow the read. Ask the owner to copy the bot's token again in "
        + "Discord's Developer Portal, to say when it is copied, and to press Allow Paste if macOS asks. Nothing was "
        + "sent."
    /// The same for a Telegram bot: the clipboard is read after the account, so its sentence is of that app.
    static let notOnClipboardTelegram = "The Founderizer app got no Telegram bot token from the clipboard: nothing "
        + "with a bot token's parts (the bot's number, a colon and 30 to 80 characters of A-Z a-z 0-9 _ -) is copied, "
        + "or macOS did not allow the read. Ask the owner to copy the bot's token again from Telegram's BotFather, to "
        + "say when it is copied, and to press Allow Paste if macOS asks. Nothing was sent."
    /// The call ended while the read waited (macOS's question waits for the owner with no limit, and the program
    /// waits about a minute): nobody reads this, and nothing is sent or cleared.
    static let endedDuringRead = "The call ended while it waited for the clipboard, so nothing was sent."
    /// A fact of a setting of macOS, not of the clipboard's content.
    static let clipboardDenied = "macOS does not let the Founderizer app read the clipboard: the owner's setting in "
        + "System Settings, Privacy & Security, Paste from Other Apps. The owner pastes the token in the app's own "
        + "page, or names a file. Nothing was sent."
    /// One read of the clipboard at a time (`ClipboardGate`): a second call while macOS's question of the first is up
    /// brings no second question.
    static let clipboardBusy = "An earlier call of this tool waits for the clipboard now: macOS asks the owner whether "
        + "Founderizer may access the pasteboard. Ask the owner to answer it (Allow Paste), then call save_bot_token "
        + "again. Nothing was sent."
    /// One sentence for bytes that are not UTF-8 and for a text that is no token: the answer says as little as it can
    /// of a file's bytes.
    static let notToken = "That is not a bot token: a Discord bot token has 50 to 100 characters of A-Z a-z 0-9 . _ - "
        + "in three parts with two dots, the first part the bot's id, and a Telegram bot token is the bot's number, a "
        + "colon and 30 to 80 characters of A-Z a-z 0-9 _ -. Copy the bot's token again (Discord's Developer Portal, "
        + "or Telegram's BotFather). Nothing was sent."

    static let noAccount = "The fleet has no chat account of that id: read fleet_read(page=\"chat_apps\") for the ones "
        + "there are. This tool does not make the account. Nothing was sent."
    static let notBotApp = "That chat account is not a Discord or Telegram account: a bot token is for one of those. "
        + "Nothing was sent."
    static let notReady = "The Founderizer app's reading of the fleet is not current now, or the app has no fleet, so "
        + "it sent nothing. Call save_bot_token again in a moment."
    static let accountsUnread = "The Founderizer app could not read the fleet's chat accounts from the hub. Call "
        + "save_bot_token again in a moment. Nothing was sent."
    static let connected = "The bot is connected now, so the hub holds a token that works: a save replaces it, and the "
        + "old token is then nowhere. Call save_bot_token again with replace true when the owner wants the new token. "
        + "Nothing was sent."
    /// The app's words when the hub's outcome is not known: no answer, an answer that it could not read, or a fault of
    /// the hub (a status of 500 or more, after which the hub can have written the file).
    static let notKnown = "Whether the hub took this call is not known. Call save_bot_token again in the same way: the "
        + "same save or delete again does no harm. If that call answers that the bot is connected, this one arrived; "
        + "with from clipboard the token is then still in the clipboard, so tell the owner to copy something else."
    /// The program's words when its request went out and no answer came back (the app did not answer within the bound,
    /// the link ended, or the answer could not be read): the app may have sent the token.
    public static let notKnownHere = "The Founderizer app did not answer in time, or the link ended, so whether the hub "
        + "took this call is not known. With from clipboard, macOS may be asking the owner now whether Founderizer may "
        + "access the pasteboard: ask the owner to press Allow Paste there. Then call save_bot_token again in the same "
        + "way: the same save or delete again does no harm. If that call answers that the bot is connected, this one "
        + "arrived; with from clipboard the token can still be in the clipboard, so tell the owner to copy something "
        + "else. If that call finds no token in the clipboard, this one may have saved it and cleared the clipboard: "
        + "read the bot's state with fleet_read(page=\"chat_apps\") before you ask the owner to copy the token again."
    static let hubRefusedPlain = "The hub refused this call. Nothing was saved."

    // ------------------------------------------------------------ the fields, on both sides

    /// The fields as the tool takes them.
    struct Read: Equatable {
        var account: String
        var delete: Bool
        var replace: Bool
        var from: String?
        var path: String?
    }

    /// **The checks of the fields, in a fixed order**, the same in the program and in the app: a field named like a
    /// value first, then a field that the tool does not take, then each field's kind, then how they go together. The
    /// program sends no path, so the app refuses one (`app`).
    static func read(_ fields: [String: JSONValue], app: Bool) -> Result<Read, OwnerChannel.Refusal> {
        if fields.keys.contains(where: OwnerLinkTools.namedLikeAValue) {
            return .failure(.init(OwnerLinkTools.neverAField))
        }
        guard fields.keys.allSatisfy({ Self.fields.contains($0) }) else { return .failure(.init(only)) }
        guard case .string(let id)? = fields["account"], !PyText.strip(id).isEmpty else {
            return .failure(.init(account))
        }
        var delete = false
        switch fields["delete"] {
        case nil, .null?: break
        case .bool(let given)?: delete = given
        default: return .failure(.init(deleteWord))
        }
        var replace: Bool?
        switch fields["replace"] {
        case nil, .null?: break
        case .bool(let given)?: replace = given
        default: return .failure(.init(replaceWord))
        }
        var from: String?
        switch fields["from"] {
        case nil, .null?: break
        case .string(let given)? where ["file", "stdin", "clipboard"].contains(given): from = given
        default: return .failure(.init(fromWord))
        }
        var path: String?
        switch fields["path"] {
        case nil, .null?: break
        case .string(let given)? where !PyText.strip(given).isEmpty: path = given
        default: return .failure(.init(pathWord))
        }
        if app && path != nil { return .failure(.init(appTakesNoPath)) }
        if delete {
            guard from == nil && path == nil && replace == nil else { return .failure(.init(deleteTakesNone)) }
        } else {
            guard let from else { return .failure(.init(needsFrom)) }
            if !app && from == "file" && path == nil { return .failure(.init(fileNeedsPath)) }
            if from != "file" && path != nil { return .failure(.init(pathOnlyWithFile)) }
        }
        return .success(Read(account: id, delete: delete, replace: replace ?? false, from: from, path: path))
    }

    // ------------------------------------------------------------ the program's side

    /// Where the token comes from: the program reads a file or its standard input; the app reads the clipboard, so
    /// for `clipboard` the program reads nothing and sends no value part.
    public enum Source: Equatable, Sendable {
        case file(String)
        case stdin
        case clipboard
    }

    /// What the program sends: the fields for the app (never `path`), and where it reads the value, or nil for a delete.
    public struct Plan: Equatable, Sendable {
        public var send: [String: JSONValue]
        public var source: Source?
    }

    public static func plan(_ fields: [String: JSONValue]) -> Result<Plan, OwnerChannel.Refusal> {
        read(fields, app: false).map { read in
            var send: [String: JSONValue] = ["account": .string(read.account)]
            if fields["delete"] != nil && fields["delete"] != .null { send["delete"] = .bool(read.delete) }
            if fields["replace"] != nil && fields["replace"] != .null { send["replace"] = .bool(read.replace) }
            if let from = read.from { send["from"] = .string(from) }
            let source: Source?
            if read.delete {
                source = nil
            } else if read.from == "stdin" {
                source = .stdin
            } else if read.from == "clipboard" {
                source = .clipboard
            } else {
                source = .file(read.path ?? "")
            }
            return Plan(send: send, source: source)
        }
    }

    // ------------------------------------------------------------ the app's side

    /// One chat account as the app reads it from the hub: its id, its app (`discord`, `whatsapp`) and the bridge's last
    /// state of it (`connected`, `connecting`, `missing_token`, `logged_out`, `error`, or nil before its first report).
    public struct Account: Equatable, Sendable {
        public let id: String
        public let app: String
        public let state: String?
        public init(id: String, app: String, state: String? = nil) {
            self.id = id
            self.app = app
            self.state = state
        }
    }

    /// The hub's receipt of a save or a delete. `replaced` is nil when the hub does not say.
    public struct Receipt: Equatable, Sendable {
        public let set: Bool
        public let replaced: Bool?
        public init(set: Bool, replaced: Bool?) {
            self.set = set
            self.replaced = replaced
        }
    }

    /// How a read or a send of the hub failed, as the app's client says it.
    public enum HubFailure: Error, Equatable, Sendable {
        /// The hub's status and its own words (its route's refusals are fixed sentences; checked in `hub.py`,
        /// `ui_chat_token`). A status of 500 or more is an outcome that is not known.
        case refused(Int, String)
        /// No answer: the send may have arrived.
        case noAnswer
        /// An answer that the client could not read.
        case unreadable
    }

    /// **What one read of the clipboard gives**: its text with the clipboard's change count at the read, nothing (no
    /// text there), that macOS does not let the app read it (a setting of System Settings), or that another read is
    /// in flight (`ClipboardGate`). It prints as hidden in every way that Swift prints a value, as `OwnerChannel.Value`
    /// does: its text is a secret, or something else that the owner copied.
    public enum Clipboard: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible,
                           CustomReflectable {
        case text(String, count: Int)
        case nothing
        case notAllowed
        case busy

        public var description: String { "a read of the clipboard (hidden)" }
        public var debugDescription: String { description }
        public var customMirror: Mirror { Mirror(self, children: [], displayStyle: .enum) }
    }

    /// **One read of the clipboard at a time.** When macOS asks the owner before a read, the read waits in macOS's own
    /// alert with no limit, and a call that comes in that time (a second try of an agent, or a process that calls in a
    /// loop) must not bring a second alert or a second waiting read: it gets `busy`, and the tool's fixed sentence.
    /// Measured in the app on macOS 26.6.2 (14 November 2026): the app's main thread is held while the alert is up,
    /// so a later call waits in line behind the first and does not come here; this is the guard for a macOS that
    /// serves the app's main queue during its alert.
    @MainActor
    public final class ClipboardGate {
        private var reading = false
        public init() {}

        public func read(_ read: () -> Clipboard) -> Clipboard {
            guard !reading else { return .busy }
            reading = true
            defer { reading = false }
            return read()
        }
    }

    /// **The app's engine for the tool**, as closures, so that a test gives stand-ins. `Token` is the app's
    /// `BotToken`, and `Place` the hub, the database and the installation that one call reads and sends with.
    @MainActor
    public struct Desk<Token, Place> {
        /// The app's own check of a pasted token (`BotToken(pasted:)`, which trims white space at the ends).
        public var token: (String) -> Token?
        /// The same for a Telegram bot's token (`BotToken(telegram:)`).
        public var telegramToken: (String) -> Token?
        /// The form of a chat account's id (`ChatApps.isAccountID`).
        public var isAccountID: (String) -> Bool
        /// The hub, its database and the installation when the app's reading is current, as the form asks
        /// (`store.isFresh` and a state with a database), else nil.
        public var ready: () -> Place?
        /// The fleet's chat accounts (`ChatAppsClient.read`).
        public var accounts: (Place) async throws -> [Account]
        /// The send (`ChatAppsClient.saveToken`): a token, or nil for a delete.
        public var save: (Place, String, Token?) async throws -> Receipt
        /// One read of the clipboard (`NSPasteboard.general`), on the main actor: on another thread AppKit ends the
        /// app when macOS asks the owner first (measured, 14 November 2026).
        public var readClipboard: () async -> Clipboard
        /// Clears the clipboard only when its change count is still the one given (the read's), and says whether it
        /// cleared.
        public var clearClipboard: (Int) async -> Bool

        public init(token: @escaping (String) -> Token?, telegramToken: @escaping (String) -> Token?,
                    isAccountID: @escaping (String) -> Bool,
                    ready: @escaping () -> Place?, accounts: @escaping (Place) async throws -> [Account],
                    save: @escaping (Place, String, Token?) async throws -> Receipt,
                    readClipboard: @escaping () async -> Clipboard, clearClipboard: @escaping (Int) async -> Bool) {
            self.token = token
            self.telegramToken = telegramToken
            self.isAccountID = isAccountID
            self.ready = ready
            self.accounts = accounts
            self.save = save
            self.readClipboard = readClipboard
            self.clearClipboard = clearClipboard
        }
    }

    /// **The parts of a Discord bot token**: three parts with two dots, the first the bot's id (a number of 15 to 22
    /// digits) in base64. The hub and the app's own page take any 50 to 100 characters of `A-Z a-z 0-9 . _ -` but a
    /// Slack token's start (`xox`, `xapp-`; owner API 1.338), which is
    /// also the form of many other services' keys (a 64-character API token, a Tailscale key). The page takes what the
    /// owner pastes; this tool takes a file that a caller names, so it is stricter: a file that holds another
    /// service's key must not go to the hub, and from there to Discord, as a bot's token. If Discord ever changes
    /// this form, the tool refuses a good token in words, and the owner pastes it in the app's own page.
    static func hasTokenParts(_ text: String) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty }), parts[0].utf8.count <= 40 else { return false }
        var first = String(parts[0])
        while first.utf8.count % 4 != 0 { first += "=" }
        guard let id = Data(base64Encoded: first), (15...22).contains(id.count) else { return false }
        return id.allSatisfy { (0x30...0x39).contains($0) }
    }

    /// **The parts of a Telegram bot token**, as BotFather gives it and the hub takes it (`TELEGRAM_TOKEN`): the bot's
    /// number (5 to 20 digits), a colon and 30 to 80 characters of `A-Z a-z 0-9 _ -`. The colon after a number is what
    /// no Discord token and few other keys have.
    static func hasTelegramParts(_ text: String) -> Bool {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        let number = parts[0].utf8, key = parts[1].utf8
        let keyByte: (UInt8) -> Bool = {
            (0x30...0x39).contains($0) || (0x41...0x5A).contains($0) || (0x61...0x7A).contains($0) || $0 == 0x5F || $0 == 0x2D
        }
        return (5...20).contains(number.count) && number.allSatisfy { (0x30...0x39).contains($0) }
            && (30...80).contains(key.count) && key.allSatisfy(keyByte)
    }


    /// **The app's answer**, in a fixed order: the fields; the account's form (short ids only, so that no account can
    /// hold a token); the value part (none for a delete or for `from` clipboard; present, UTF-8 and of a token's form
    /// for a save from a file or a pipe, of Discord's or Telegram's form); a current reading; the read of the accounts;
    /// the account among them, a Discord or Telegram one, and the value of that app's form; the `replace` rule; for `from` clipboard, the clipboard's read; then the send. The value is compared
    /// with nothing that the caller sent. The answer is `account`, `set` and `replaced` from the hub's receipt, and
    /// never the token, its length or a fingerprint.
    ///
    /// **The clipboard is read last**, so that a call that any other check refuses reads nothing of it, and never for a
    /// delete. Its text is held to a value part's form, and a clipboard with no text gets the same one sentence as a
    /// text that is no token. After a save that the hub's receipt confirms (`set` true), the app clears the clipboard
    /// only when nothing changed it since the read, and the answer's `clipboard` says `cleared` or `kept`. After any
    /// refusal, or an outcome that is not known, the clipboard stays, so that the same call again still works. A call
    /// whose task was cancelled while the read waited (the connection ended) sends nothing and clears nothing.
    @MainActor
    public static func answer<Token, Place>(fields: [String: JSONValue], value: OwnerChannel.Value?,
                                            desk: Desk<Token, Place>) async -> OwnerChannel.Answer {
        let read: Read
        switch Self.read(fields, app: true) {
        case .failure(let refusal): return .refused(refusal.text)
        case .success(let fields): read = fields
        }
        // Before anything of the value is read as text: an id (at most 40 characters) cannot have a token's form.
        guard desk.isAccountID(read.account) else { return .refused(noAccount) }
        var token: Token?
        var valueText: String?
        var hidden: [String] = [read.account]
        let fromClipboard = !read.delete && read.from == "clipboard"
        if read.delete {
            guard value == nil else { return .refused(deleteTakesNone) }
        } else if fromClipboard {
            guard value == nil else { return .refused(clipboardTakesNoPart) }
        } else {
            guard let value else { return .refused(noValue) }
            let trimmed = value.text?.trimmingCharacters(in: .whitespacesAndNewlines)
            // The form of either app's token here; the account's app, read below, decides which one it must be.
            guard let text = trimmed, hasTokenParts(text) || hasTelegramParts(text) else {
                return .refused(notToken)
            }
            valueText = text
            hidden.append(text)
        }
        guard let place = desk.ready() else { return .refused(notReady) }
        let accounts: [Account]
        do {
            accounts = try await desk.accounts(place)
        } catch {
            return .refused(accountsUnread)
        }
        guard let found = accounts.first(where: { $0.id == read.account }) else { return .refused(noAccount) }
        guard found.app == "discord" || found.app == "telegram" else { return .refused(notBotApp) }
        if let valueText {
            // the token of the account's own app only, made here, as the clipboard's below; a token of the other
            // app's form gets the one sentence of no token, so an answer tells nothing more of a file's bytes
            let made = found.app == "telegram" ? (hasTelegramParts(valueText) ? desk.telegramToken(valueText) : nil)
                : (hasTokenParts(valueText) ? desk.token(valueText) : nil)
            guard let made else { return .refused(notToken) }
            token = made
        }
        if !read.delete && found.state == "connected" && !read.replace { return .refused(connected) }
        var readCount: Int?
        if fromClipboard {
            // A caller that went away while this call waited (the app's main thread is held while macOS's question
            // of an earlier call is up): no read, so no further question for a call that nobody waits for.
            if Task.isCancelled { return .refused(endedDuringRead) }
            let copy = await desk.readClipboard()
            // A caller that went away while macOS asked the owner: no send and no clear.
            if Task.isCancelled { return .refused(endedDuringRead) }
            // The reading of before the read is the one that sends. It is not asked again here: while macOS's question
            // is up, the app's main thread is held and its reading cannot renew, so a second check refused the save
            // right after the owner's "Allow Paste" (measured in the app, 14 November 2026).
            switch copy {
            case .notAllowed:
                return .refused(clipboardDenied)
            case .busy:
                return .refused(clipboardBusy)
            case .nothing:
                return .refused(found.app == "telegram" ? notOnClipboardTelegram : notOnClipboard)
            case .text(let copied, let count):
                let nothing = found.app == "telegram" ? notOnClipboardTelegram : notOnClipboard
                // Bounded as a value part is, before any work on its text on the main actor.
                guard copied.utf8.count <= OwnerChannel.valueMax else { return .refused(nothing) }
                let text = copied.trimmingCharacters(in: .whitespacesAndNewlines)
                let made = found.app == "telegram" ? (hasTelegramParts(text) ? desk.telegramToken(text) : nil)
                    : (hasTokenParts(text) ? desk.token(text) : nil)
                guard let made else { return .refused(nothing) }
                token = made
                hidden.append(text)
                readCount = count
            }
        }
        do {
            let receipt = try await desk.save(place, read.account, token)
            var answer: [String: JSONValue] = ["account": .string(read.account), "set": .bool(receipt.set),
                                               "replaced": receipt.replaced.map(JSONValue.bool) ?? .null]
            if let readCount {
                // Only a save that the hub's receipt confirms clears; `kept` otherwise. A caller that went away during
                // the send gets no answer and calls again in the same way: for it the clipboard stays as it is.
                let cleared = receipt.set && !Task.isCancelled ? await desk.clearClipboard(readCount) : false
                answer["clipboard"] = .string(cleared ? "cleared" : "kept")
            }
            return .result(.object(answer))
        } catch let failure as HubFailure {
            return .refused(words(failure, hiding: hidden))
        } catch {
            return .refused(notKnown)
        }
    }

    /// The words of a hub's failure on the send. No answer, an answer that could not be read, and a status of 500 or
    /// more are outcomes that are not known. Below 500, the hub's own words pass unless they hold the whole account or
    /// the whole token, are not printable ASCII, or are longer than 200 characters; then fixed words do.
    static func words(_ failure: HubFailure, hiding: [String]) -> String {
        switch failure {
        case .noAnswer, .unreadable: return notKnown
        case .refused(let status, _) where status >= 500: return notKnown
        case .refused(_, let said):
            let plain = said.unicodeScalars.allSatisfy { (0x20...0x7E).contains($0.value) }
            guard plain, !said.isEmpty, said.count <= 200,
                  !hiding.contains(where: { !$0.isEmpty && said.contains($0) }) else { return hubRefusedPlain }
            return "The hub refused this call: \(said). Nothing was saved."
        }
    }
}
