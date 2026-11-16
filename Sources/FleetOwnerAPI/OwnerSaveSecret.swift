import Foundation

/// **`save_secret`**: a new login or a new API key into the fleet's central vault, from a file, a pipe or the
/// clipboard of this Mac (the secrets plan, `agent-install-secrets-plan.md`, step E). It does what the app's own form
/// Add secret does for a new value with no grant: the value is sealed in the app to the central vault's key, the hub
/// gets the entry of its list, and the hub passes the sealed copy on to the vault. It gives the secret to no agent,
/// it replaces no value, and it sets no site.
///
/// **This file is the part that both sides share**: the fields and their forms (`read`), the order in the program
/// (`plan`), the two lists that the forms need, every fixed sentence, and the tool's description. The app's own part
/// (its desk, `answer` and the work that outlives its call) is in `OwnerSaveSecretApp.swift`. The tool is the last
/// one of `OwnerLinkTools.names` and `tools`: the program lists it and sends each call of it to the running app
/// (`OwnerTools.linkWrite`), and the app answers it from its board, with a desk of its own engine (`LinkTools`).
///
/// **Each field has one form, and the app holds each to it before it looks at the value and before it reads the
/// hub.** A field's text reaches places that are no secret: a login's title ("host · username") and a key's variable
/// name go into the hub's list, its git history and its log. So a form here is narrow on purpose (ASCII, a whole
/// match, no trim and no change of case), and what passes is the same text in the program, in the app and in the hub.
///
/// **A whole match, character by character.** A search with `^…$` also takes a text with a line end after it, and
/// the form's own type (`LoginSecret` in FleetCore) would then trim that text: two readers, two texts. So each check
/// here reads every byte of the text and takes no line end, no white space and no character that is not ASCII.
///
/// **Two lists of its own.** The reserved variable names are the hub's (`lifecycle.py` `ENV_RESERVED`), and the model
/// providers' sign-in sites are the vault's (`vault.py` `PROVIDER_SITES`, `PROVIDER_KEY_SITES`). The Mac's older
/// copies of both differ from them, and this library links neither, so the tool keeps its own, and a test holds each
/// to the Python file where the repository has it.
///
/// **No search on the value**, as for `save_bot_token`: the value is compared with nothing that the caller sent, and
/// one sentence covers every way in which a text is no value.
public enum SaveSecret {
    public static let name = "save_secret"
    public static let fields = ["kind", "env", "url", "username", "from", "path", "request_id"]
    /// The fields of an authenticator seed, which this version does not take: they get their own sentence
    /// (`noSeedYet`), so that a caller learns where such a login is saved and does not read "unknown field".
    static let seedFields = ["seed_from", "seed_path"]

    /// The shortest value, in Unicode scalars: the vault's own bound for a value that gets a fingerprint (`vault.py`
    /// `eligible`). A shorter value would get an entry in the list that the vault then refuses at every try.
    public static let valueLeast = 8
    /// The longest value, in bytes of UTF-8: with the longest `url` and `username` the item stays under what a sealed
    /// copy carries (`LoginSecret.maxValueBytes` in FleetCore; a test holds it).
    public static let valueMost = 4096
    /// The longest `url`, in ASCII characters.
    public static let siteMost = 300
    /// The most entries of the hub's list of secrets (`LoginSecret.maxCatalog` in FleetCore, which this library does
    /// not link; a test holds the two equal). Only the words of `full` use it.
    static let listMost = 256

    /// The value's form in words, one time, for the description and for the two sentences that say it.
    static let valueForm = "text of \(valueLeast) characters or more, at most \(valueMost) bytes, with no white space "
        + "and no invisible character in it"

    public static let tool = OwnerTable.Tool(
        // One text in three groups: what the tool saves and the fields of each kind; the value and its three sources;
        // `request_id` and the answers.
        name: name, description: """
            Saves a new login or a new API key of the fleet into the fleet's central vault. It gives the secret to no \
            agent. It replaces nothing: a name that the fleet's list of secrets has already is refused. kind: login \
            or api_key. A login takes url (the address of its sign-in page) and username, and no env. An API key \
            takes env (its variable name: capital letters, digits and _, with _KEY, _TOKEN, _SECRET, _PASSWORD or \
            _PAT at its end), may take url (the address of its service), and takes no username. A login's name in \
            the fleet's list is the host of its url with its username, and a key's name is its env: put nothing \
            secret in them. For an API key with an https url, only the scheme, the host and the port go to the hub, \
            which can then set the key's site from its own table of well-known services; fleet_read(page="team") \
            shows whether it did. The whole address stays in the value that the vault keeps, and this tool sets no \
            site. This tool takes no seed for one-time codes. \
            The value (a login's password, or the key) is never a field of this tool, never a word of a command \
            line and never a word of a chat. You never see it, type it or repeat it, and you never ask the owner to \
            paste it into a chat. It comes from this Mac: from a file or a pipe that founderizer-cli reads and sends \
            to the Founderizer app after the request, not as a field, or from the clipboard, which the app reads \
            itself. from file, with path: a regular file of this Mac that holds only the value (at most 64 KiB). \
            from stdin: only with founderizer-cli write, the standard input from a program's pipe (never pbpaste or \
            another read of the clipboard: for the clipboard, use from clipboard), never an echo or a here-string of \
            the value; the MCP form refuses it. from clipboard: the app reads the clipboard itself, after every \
            other check passed, once the owner copied the value and said so; never read the clipboard yourself. \
            When macOS asks whether Founderizer may access the pasteboard, the owner presses Allow Paste. After a \
            clipboard save the app clears the clipboard when nothing else changed it since the read, and the \
            answer's clipboard says cleared or kept. The value from a file or from stdin is the one line that the \
            text holds: one line end after it is not part of the value. The app takes nothing else off a value and \
            changes nothing in it, so a value with white space at its start or at its end, or a text of two lines, \
            is refused. \
            The value is \(valueForm). \
            request_id: a UUID that names one save. A new save gives its own or none: with none, founderizer-cli \
            makes one, and an answer with a state names it. A save can take longer than its call: then the answer \
            says state running, with stage registering or storing, and the save goes on. Read its state later with \
            only request_id, until state done or a refusal. A later call has two forms. With only request_id, it \
            reads the state of that save and changes nothing. With the same fields, the same from and the same \
            request_id, it goes on with that save, which is never made twice. With state done, the answer has \
            reference (the secret's reference in the list), title and kind. No answer has the value, its length or a \
            fingerprint of it.
            """,
        // No `required` list: a read of a save's state sends only `request_id`.
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "kind": .object(["type": .string("string"), "enum": .array([.string("login"), .string("api_key")])]),
                "env": .object(["type": .string("string")]),
                "url": .object(["type": .string("string")]),
                "username": .object(["type": .string("string")]),
                "from": .object(["type": .string("string"), "enum": .array([.string("file"), .string("stdin"),
                                                                                .string("clipboard")])]),
                "path": .object(["type": .string("string")]),
                "request_id": .object(["type": .string("string")]),
            ]),
            "additionalProperties": .bool(false),
        ]),
        annotations: .object(["readOnlyHint": .bool(false)]), kind: .swift, route: "", fields: [], what: name,
        revisionPage: nil, requestIDFromArguments: false, feature: nil)

    // ------------------------------------------------------------ the fixed sentences

    // Each names only the tool's own fields, and none quotes anything that the caller sent: not a field's text, not a
    // title and not the hub's words. The variable parts are the reference of the entry, which the app made, the
    // hub's status number, and the save's own `request_id`, in the form that `LinkWork.isID` holds it to: in the two
    // sentences that ask for the same call again, and in the program's words for a lost answer when the program made
    // the id. No sentence says that an agent can read a login. Each refusal before the send says that nothing was
    // sent.

    // The words of `save_bot_token`, under this tool's name and with "the value" for "the token".
    static let only = "save_secret takes only kind, env, url, username, from, path and request_id. Nothing was sent."
    static let fromWord = "from must be file, stdin or clipboard. Nothing was sent."
    static let pathWord = "path must be the file on this Mac that holds only the value. Nothing was sent."
    static let needsFrom = "save_secret needs from: file with path, stdin, or clipboard. The value is never a field. "
        + "Nothing was sent."
    static let fileNeedsPath = "from file needs path: the file on this Mac that holds only the value. Nothing was sent."
    static let pathOnlyWithFile = "path goes only with from file. Nothing was sent."
    static let appTakesNoPath = "The app takes no path: founderizer-cli reads the file itself and sends only its "
        + "bytes. Nothing was sent."
    public static let stdinInMCP = "from stdin is for founderizer-cli write, run from a shell with the value piped "
        + "from a program: in this MCP form the standard input carries the protocol. Use from file with path, or "
        + "from clipboard. Nothing was sent."
    static let noValue = "save_secret needs the value as a part after its request line, which founderizer-cli reads "
        + "with from (file or stdin). Nothing was sent."
    /// With `from` clipboard the app reads the clipboard itself: a value part as well would be a second value.
    static let clipboardTakesNoPart = "With from clipboard the app reads the clipboard itself, so it takes no part "
        + "after the request line. Nothing was sent."
    /// The call ended while the read waited: nobody reads this, and nothing is sent or cleared.
    static let endedDuringRead = "The call ended while it waited for the clipboard, so nothing was sent."
    /// The call ended (its connection went) in one of its own waits before the save began: before the clipboard was
    /// read, or right before `LinkWork.begin`. Nobody reads this. Nothing was read from the clipboard for it after
    /// its end, and nothing was sent. Not `endedDuringRead`, which is only for a call that ended while the read of
    /// the clipboard waited.
    static let endedBeforeBegin = "The call ended before the save began, so nothing was sent."
    /// A fact of a setting of macOS, not of the clipboard's content. **Not the bot token's words in one place, on
    /// purpose**: the owner's other way for a secret is the app's own form, by its name, and not "the app's own page".
    static let clipboardDenied = "macOS does not let the Founderizer app read the clipboard: the owner's setting in "
        + "System Settings, Privacy & Security, Paste from Other Apps. The owner saves the secret in Founderizer, on "
        + "Secrets, with Add secret, or names a file. Nothing was sent."
    /// One read of the clipboard at a time (`SaveBotToken.ClipboardGate`, which this tool shares).
    static let clipboardBusy = "An earlier call of this tool waits for the clipboard now: macOS asks the owner whether "
        + "Founderizer may access the pasteboard. Ask the owner to answer it (Allow Paste), then call save_secret "
        + "again. Nothing was sent."
    static let notReady = "The Founderizer app's reading of the fleet is not current now, or the app has no fleet, so "
        + "it sent nothing. Call save_secret again in a moment."

    /// The program's words when its request went out and no answer came back: the save may have begun, and with the
    /// clipboard macOS may still be asking the owner. The same call again with the same `request_id` joins the save
    /// that began, so nothing is made twice. This form holds no id: the caller gave the id and has it.
    public static let notKnownHere = "The Founderizer app did not answer in time, or the link ended, so the outcome of "
        + "this save is not known. With from clipboard, macOS may be asking the owner now whether Founderizer may "
        + "access the pasteboard: ask the owner to press Allow Paste there. Then call save_secret again in the same "
        + "way with the same request_id: a save that began goes on, and it is not made twice."

    /// The same words with the id, only for a call whose id the program made (`Plan.made`): the caller gave none, and
    /// without it the same call again would be a new save. The id is the program's own, so this quotes no field.
    public static func notKnownHereWithID(_ id: String) -> String {
        notKnownHere + " This call gave no request_id, so founderizer-cli made one: \(id). Give it in that call."
    }

    /// The program's words when a READ of a save's state (a call with only `request_id`) went out and no answer came
    /// back. Not `notKnownHere`: a read begins no save and reads no clipboard, so nothing of that sentence is true of
    /// it. A read changes nothing, and the same read again is the next step. It holds no id: the caller gave it.
    public static let notKnownState = "The Founderizer app did not answer in time, or the link ended, so the state of "
        + "this save was not read. Nothing was changed. Call save_secret again with only this request_id."

    // This tool's own words.
    static let noSeedYet = "save_secret takes no seed for one-time codes in this version of the app: the owner saves "
        + "such a login in Founderizer, on Secrets, with Add 2FA code. Nothing was sent."
    /// Not "in lower case": the program puts the letters A to F of a given id in lower case itself.
    static let requestWord = "request_id must be a UUID, or absent in a new save. Nothing was sent."
    /// The app never makes the id: an id made in the app is lost with a lost answer, and the caller could then not
    /// ask for the save again. Only a process that is not the program can send a request with none.
    static let appNeedsRequest = "The app takes no call without request_id: founderizer-cli makes one for a new save "
        + "and sends it. Nothing was sent."
    static let kindWord = "kind must be login or api_key. Nothing was sent."
    static let kindFields = "A login takes url and username, and no env. An API key takes env, may take url, and takes "
        + "no username. Nothing was sent."
    /// The names that are reserved as a whole (PATH, HOME and the others) end in none of the endings, so the words
    /// name only the reserved starts (a test holds that).
    static let envWord: String = {
        let starts = listed(reservedPrefixes.map { $0 + "_" }, last: "and")
        return "env must be the key's variable name: 1 to 60 characters of A-Z, 0-9 and _, with a letter first, and "
            + "with " + listed(keySuffixes) + " at its end. Reserved are " + starts + ", and every name that begins "
            + "with one of them, because a session or a program uses such a name itself. Nothing was sent."
    }()
    /// **The form as `siteHost` checks it, part for part**, so that a caller whose address was refused can find the
    /// part that is wrong. A name under a site ends with a dot and the site (`isProviderSite`).
    static let urlWord: String = {
        let allowed = listed(providerKeySites, last: "and")
        return "url must be an address of at most \(siteMost) ASCII characters: http:// or https://, a host of at most "
            + "253 characters of a to z, 0 to 9, dots and hyphens that starts and ends with a letter or a digit, then "
            + "an optional : and a port of 1 to 5 digits, then an optional path that starts with / (a query comes after it, "
            + "as /?a=b), with no space, no capital letter in the host, no user part and no fragment, and a % only "
            + "with two hex digits after it. A path takes only letters, digits and the marks . _ ~ % ! $ & ' ( ) * + "
            + ", ; = : @ / ? - in it. The host must not be a model provider's own sign-in site: "
            + listed(providerSites) + ", or a name that ends with a dot and one of them. " + allowed + " are allowed, "
            + "with each name that ends with a dot and one of them. Nothing was sent."
    }()
    static let userWord = "username must be 1 to 100 printable ASCII characters, with no space. Nothing was sent."
    /// One sentence for bytes that are not UTF-8, for a text that is too short or too long, and for a text with white
    /// space or an invisible character in it, at an end too: the answer says as little as it can of a file's bytes.
    /// It says what the app takes off, because a caller whose file has a space or a second line end at its end must
    /// know that the app does not cut it: the app never changes a value (`value(of:line:)`).
    static let notAValue = "That is not a value that the vault keeps: \(valueForm). The app takes off only the one "
        + "line end of a file or of stdin, and nothing else. Nothing was sent."
    /// One sentence for a clipboard with no text, for a text that is no value, and for a "Don't Allow Paste" in
    /// macOS's own question, so that an answer says as little as it can about what the owner copied. The app takes
    /// the clipboard's text as it is, so the words ask for a copy with no space and no line end around the value.
    static let notOnClipboard = "The Founderizer app got no value from the clipboard: no \(valueForm) is copied, or "
        + "macOS did not allow the read. Ask the owner to copy the value again, with no space and no line end around "
        + "it, to say when it is copied, and to press Allow Paste if macOS asks. Nothing was sent."
    /// The fields passed the tool's forms and the form's own type did not take them (`LoginSecret.problem` in
    /// FleetCore): its words can hold a field's text, so they never pass.
    static let formRefused = "The app's own form does not take these fields. Nothing was sent."
    /// The form's own type took the fields and the value, and the app could not seal the item to the vault's key, at
    /// the first run of the work: nothing was sent. Not `formRefused`, which would be untrue here: the form took the
    /// fields. At a later run a seal that failed is "not known", because an earlier run's request may have arrived.
    static let sealFailed = "The Founderizer app could not seal the value for the vault. Nothing was sent."
    /// **Not only before the send**: these are also the words for a 503 of the hub's step, after the request for the
    /// entry went out. So they end "Nothing was saved.", which is true of both: "Nothing was sent." would be false
    /// after that request.
    static let noVault = "The fleet's central vault does not answer the hub now, so no secret can be saved. Call "
        + "save_secret again in a moment. Nothing was saved."
    /// The app's own read of the vault's status failed, in a call's check before anything is sent: the hub did not
    /// answer this Mac, or it refused the read. Not `noVault`: that the vault does not answer the hub is not known
    /// when the hub did not answer the Mac.
    static let vaultUnread = "The Founderizer app could not read the central vault's status from the hub. Call "
        + "save_secret again in a moment. Nothing was sent."
    /// This Mac has no pin for this hub and this fleet: the vault's Set up on this Mac makes it.
    static let noPin = "This Mac pinned no key of the central vault yet. The owner sets up Founderizer Vault in the "
        + "app on this Mac. Nothing was sent."
    /// **Its own words, apart from `noPin`.** A vault whose key is not the pinned one is a fact that the owner must
    /// know before anything is saved: a hub that is broken into can name a key of its own. A new Set up would put a
    /// new pin in the place of the old one with no look at why the key changed, so the words say not to do that to
    /// get past the refusal.
    static let otherKey = "The central vault answers with another key than the one that this Mac pinned. Tell the "
        + "owner, and save nothing until the owner knows why: do not set the vault up again to get past this. Nothing "
        + "was sent."
    static let noRecovery = "The central vault holds no recovery key yet, so the hub takes no new secret. The owner "
        + "finishes Founderizer Vault's setup in the app. Nothing was sent."
    static let listUnread = "The Founderizer app could not read the list of secrets from the hub. Call save_secret "
        + "again in a moment. Nothing was sent."
    static let full = "The list has \(listMost) secrets and takes no more. Nothing was sent."
    /// **No word here tells a caller to remove the entry of this name.** The list does not show whether an entry has
    /// a value in the vault, so a caller that removed "the entry with no value" by its name could remove a secret
    /// that works. Only an answer of this tool that names a reference says that an entry has no value.
    static let held = "The list has a secret of this name already, and save_secret saves only a new one: the owner "
        + "replaces a secret in Founderizer, on Secrets. Remove an entry with save_login only when an answer of "
        + "save_secret named its reference as an entry with no value. Nothing was sent."
    static let busy = "Another save_secret runs now. Call again when it has ended. If it is a save of yours, read its "
        + "state with its request_id. Nothing was sent."
    static let otherFields = "This request_id belongs to a save with other fields. Use a new request_id for a new "
        + "save. Nothing was changed."
    /// The answer to a read of a state that the app does not have. It gives the next step for both things that the
    /// list can show, because the app cannot say which of its three reasons is the true one.
    static let noWork = "The Founderizer app has no save of this request_id: nothing was saved, it ended long ago, or "
        + "the app started again since. Read fleet_read(page=\"team\"). If the list has no secret of this name, "
        + "nothing was saved: save again with a new request_id. If it has one, the save may have ended: do not save "
        + "it again and do not remove it, and ask the owner to look at it on Secrets."

    /// The hub refused the entry with a status under 500, except 503. Its own words never pass: they can hold `env`.
    static func hubRefused(status: Int) -> String { "The hub refused the new entry (status \(status)). Nothing was saved." }

    /// No answer to the hub's step, or a status of 500 and above: the entry may be there. `reference` is the one that
    /// the app made for this save.
    ///
    /// **"With the same fields, the same from and request_id …"**, here and in `notInVault`: these words can be the
    /// answer to a read of the state, which has only `request_id`. "In the same way" would then ask for that read
    /// again, and a read never goes on with a save.
    ///
    /// **The id is in the words**, here and in `notInVault`, because a caller that gave none cannot know it: the
    /// program made it, and a refusal carries no id. The app always has it (its read refuses a save with none), so
    /// the program needs no search in an answer's text. It is the save's own id, in the one form of `LinkWork.isID`.
    static func registerNotKnown(_ reference: String, id: String) -> String {
        "Whether the hub took the entry \(reference) is not known. Call save_secret again with the same fields, the "
            + "same from and request_id \(id): it goes on under the same reference."
    }

    /// The hub has the entry, and the sealed copy did not reach the vault yet.
    static func notInVault(_ reference: String, id: String) -> String {
        "The list has the entry \(reference), and its value is not in the vault yet. Call save_secret again with the "
            + "same fields, the same from and request_id \(id)."
    }

    /// The vault refused the value: the list has an entry with no value, which is a fact here, because the vault
    /// itself said no. The vault takes no value under a reference that left the list, so the words ask for a new
    /// `request_id`.
    static func vaultRefused(_ reference: String) -> String {
        "The list has the entry \(reference) with no value in the vault. " + removeAndSaveAgain(reference)
    }

    /// **A later run of a save read the vault's key again, and it is another key than the one that this Mac
    /// pinned.** Nothing is sealed to that key and nothing of the save is sent at that run, and the save ends for good
    /// there, also when it has runs left: "it goes on under the same reference" would be untrue while the key
    /// differs, and the owner must know of the key now, not after the last run. **The value itself was never sent**:
    /// these words come only before the hub confirmed the entry, so no run sent the sealed copy to the vault. An
    /// earlier run's request for the entry may have arrived: whether the list has the entry is not known, and an
    /// entry that is there has no value in the vault, which is a fact. So the words say "if the list has the entry",
    /// and the removal is no save. The words ask for no `request_id`: a new save would get `otherKey` at its own
    /// check.
    static func otherKeyLater(_ reference: String) -> String {
        "The central vault answers now with another key than the one that this Mac pinned, so the value was not sent, "
            + "and this save has ended. Tell the owner, and save nothing until the owner knows why: do not set the "
            + "vault up again to get past this. If the list has the entry \(reference), it has no value in the "
            + "vault: remove it with save_login (login \(reference), delete true)."
    }

    /// The last words of a save whose hub step stayed not known in its tries: the entry may be there.
    static func registerNeverKnown(_ reference: String) -> String { mayBeLeft(reference) }

    /// The last words of a save whose copy did not reach the vault in its tries, as far as the app knows. The same
    /// "may have" words: a send with no answer can have arrived, so that the vault has no value is no fact.
    static func neverInVault(_ reference: String) -> String { mayBeLeft(reference) }

    private static func mayBeLeft(_ reference: String) -> String {
        "The list may have the entry \(reference) with no value in the vault. " + removeAndSaveAgain(reference)
    }

    private static func removeAndSaveAgain(_ reference: String) -> String {
        "Remove it with save_login (login \(reference), delete true), then save again with a new request_id."
    }

    /// "a, b or c", for the sentences that say a list of this file.
    static func listed(_ words: [String], last: String = "or") -> String {
        guard let end = words.last, words.count > 1 else { return words.first ?? "" }
        return words.dropLast().joined(separator: ", ") + " \(last) " + end
    }

    // ------------------------------------------------------------ the two lists

    /// The endings of an API key's variable name (`lifecycle.py` `KEY_SUFFIXES`).
    public static let keySuffixes = ["_KEY", "_TOKEN", "_SECRET", "_PASSWORD", "_PAT"]
    /// **The reserved names** (`lifecycle.py` `ENV_RESERVED`): a name with one of these starts and "_", which the
    /// start of a session sets or a runtime reads itself.
    public static let reservedPrefixes = ["FLEET", "BWS", "LD", "DYLD", "ANTHROPIC", "CLAUDE", "CODEX", "XAI"]
    /// The names that are reserved as a whole.
    public static let reservedNames = ["PATH", "HOME", "SHELL", "USER", "LOGNAME", "TMPDIR", "TERM", "PWD", "IFS", "ENV",
                                       "BASH_ENV", "ZDOTDIR", "NODE_OPTIONS", "PYTHONPATH", "PYTHONHOME"]

    /// **The model providers' own sign-in sites** (`vault.py` `PROVIDER_SITES`), each with the names under it. The
    /// fleet holds no provider credential, so the vault refuses a login or a key with such an address at its intake:
    /// the tool refuses it before anything is sent, or the list would get an entry with no value.
    public static let providerSites = ["claude.ai", "claude.com", "chatgpt.com", "auth.openai.com", "x.ai"]
    /// An API console or a paid API under one of them (`vault.py` `PROVIDER_KEY_SITES`): an address there is allowed.
    public static let providerKeySites = ["platform.claude.com", "api.x.ai"]

    // ------------------------------------------------------------ the forms

    private static func isCapital(_ byte: UInt8) -> Bool { (0x41...0x5A).contains(byte) }
    private static func isSmall(_ byte: UInt8) -> Bool { (0x61...0x7A).contains(byte) }
    private static func isDigit(_ byte: UInt8) -> Bool { (0x30...0x39).contains(byte) }

    /// **An API key's variable name, by the hub's own rule** (`lifecycle.py` `key_env`), as sent, with no trim and no
    /// change of case: a whole match of `[A-Z][A-Z0-9_]{0,59}`, with one of `keySuffixes` at its end, and not
    /// reserved. The hub refuses any other name for a key, and a name that changed on the way would be another
    /// variable in a session.
    public static func isKeyName(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        guard (1...60).contains(bytes.count), isCapital(bytes[0]),
              bytes.allSatisfy({ isCapital($0) || isDigit($0) || $0 == 0x5F }) else { return false }
        // Every byte is ASCII from here, so a compare of texts is a compare of bytes.
        guard keySuffixes.contains(where: { text.hasSuffix($0) }) else { return false }
        return !reservedNames.contains(text) && !reservedPrefixes.contains(where: { text.hasPrefix($0 + "_") })
    }

    /// **An address in the tool's form**: ASCII, at most `siteMost` characters, a whole match of
    /// `https?://[a-z0-9]([a-z0-9.-]{0,251}[a-z0-9])?(:[0-9]{1,5})?(/([A-Za-z0-9._~!$&'()*+,;=:@/?-]|%[0-9A-Fa-f]{2})*)?`,
    /// and not on a model provider's own sign-in site. The form has no user part, no fragment, no capital letter in
    /// the host and nothing before the first "/" but the host and a port, so every reader of the address (this check,
    /// the form's type, the hub and the vault) finds the same host in it.
    ///
    /// **A "%" only with two hex digits after it.** A lone "%" is no valid address: one reader of it encodes the
    /// sign, and another can refuse the whole text. The form's type makes a login's title of the host that it reads
    /// (`LoginSecret.title`), and it takes the WHOLE address for the title when it reads none: the path and the query
    /// of a login's address would then be in the hub's list, in its git history and in its log. So the tool takes
    /// only an address that every reader reads in one way.
    ///
    /// **What this form does not hold**: a host with a label that begins with "xn--" and is no valid name in that
    /// coding passes here, and the form's type reads no host in it (measured on macOS, 15 November 2026). That type
    /// then refuses the secret (`LoginSecret.problem`), which is the app's second check of these fields, and the
    /// tool's answer is `formRefused`. So the title of a secret is read only after that check passed.
    public static func isSite(_ text: String) -> Bool {
        guard let host = siteHost(text) else { return false }
        return !isProviderSite(host)
    }

    /// The host of an address in the tool's form, or nil for a text that has not the form.
    static func siteHost(_ text: String) -> String? {
        let bytes = Array(text.utf8)
        guard bytes.count <= siteMost else { return nil }
        var at: Int
        if bytes.starts(with: Array("https://".utf8)) {
            at = 8
        } else if bytes.starts(with: Array("http://".utf8)) {
            at = 7
        } else {
            return nil
        }
        // The host: the longest run of its characters. What comes after it is a port, a path or the end, and none of
        // them starts with a character of a host, so this is the pattern's own reading.
        let start = at
        while at < bytes.count, isSmall(bytes[at]) || isDigit(bytes[at]) || bytes[at] == 0x2E || bytes[at] == 0x2D { at += 1 }
        let host = bytes[start..<at]
        guard (1...253).contains(host.count), let first = host.first, let last = host.last,
              isSmall(first) || isDigit(first), isSmall(last) || isDigit(last) else { return nil }
        if at < bytes.count, bytes[at] == 0x3A {                   // ":" and a port of 1 to 5 digits
            at += 1
            let port = at
            while at < bytes.count, isDigit(bytes[at]) { at += 1 }
            guard (1...5).contains(at - port) else { return nil }
        }
        if at < bytes.count {                                      // "/" and the path with its query, to the end
            guard bytes[at] == 0x2F else { return nil }
            while at < bytes.count {
                if bytes[at] == 0x25 {                             // "%" only with two hex digits after it
                    guard at + 2 < bytes.count, isHex(bytes[at + 1]), isHex(bytes[at + 2]) else { return nil }
                    at += 3
                } else {
                    guard isPathByte(bytes[at]) else { return nil }
                    at += 1
                }
            }
        }
        return String(decoding: host, as: UTF8.self)
    }

    /// The marks of a path and its query, beside letters and digits. "%" is not one of them: it has its own rule.
    private static let pathMarks = Set("._~!$&'()*+,;=:@/?-".utf8)
    private static func isPathByte(_ byte: UInt8) -> Bool {
        isCapital(byte) || isSmall(byte) || isDigit(byte) || pathMarks.contains(byte)
    }
    private static func isHex(_ byte: UInt8) -> Bool {
        isDigit(byte) || (0x41...0x46).contains(byte) || (0x61...0x66).contains(byte)
    }

    /// **The vault's own rule** (`vault.py` `provider_site`), for a host in the tool's form (lower case, no dot at
    /// its end): the host, or a parent of it, is one of `providerSites` and is not under one of `providerKeySites`.
    static func isProviderSite(_ host: String) -> Bool {
        func under(_ site: String) -> Bool { host == site || host.hasSuffix("." + site) }
        if providerKeySites.contains(where: under) { return false }
        return providerSites.contains(where: under)
    }

    /// **A login's user name**: a whole match of `[!-~]{1,100}`, printable ASCII with no space. It is the second half
    /// of the login's title in the list, so it holds no white space, no line end and nothing that a reader cannot see.
    public static func isUserName(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        return (1...100).contains(bytes.count) && bytes.allSatisfy { (0x21...0x7E).contains($0) }
    }

    /// **The value's own form**, for a text from which the one line end of a file or of stdin is off already
    /// (`value(of:line:)`): `valueLeast` Unicode scalars or more, at most `valueMost` bytes of UTF-8, with no white
    /// space by Python's rule (`PyText.space`) and no control or format character (Unicode's categories Cc and Cf),
    /// at any place: inside the text, at its start and at its end.
    ///
    /// - A shorter value, or one with white space, gets no fingerprint from the vault (`vault.py` `eligible`), and
    ///   the vault then refuses it at every try: the list would have an entry with no value.
    /// - A format character is invisible: a byte order mark at the start of a file, or a zero-width character in a
    ///   copied text, would be saved as a part of the value, and the key would then fail where it is used. So no value
    ///   is ever saved with one in it, and none is taken off a text: nothing can say whether the owner's value has
    ///   it. One at an end makes the text no value, as one inside does.
    public static func isValueText(_ text: String) -> Bool {
        guard text.utf8.count <= valueMost, text.unicodeScalars.count >= valueLeast else { return false }
        return !text.unicodeScalars.contains { scalar in
            PyText.space.contains(scalar.value) || scalar.properties.generalCategory == .control
                || scalar.properties.generalCategory == .format
        }
    }

    /// **The value of a text as it came** (a value part's strict UTF-8 text, or the clipboard's), or nil for a text
    /// that is no value. **The app never cuts or changes a value**: a changed secret is worse than a refused one, and
    /// a password can end in a space. So the app takes off only what is no part of a value by the source's own form.
    ///
    /// - **From a file or from stdin** (`line` true), the value is the one line that the text holds. Exactly one line
    ///   end at the very end (one LF, or one CR LF) is the line's end and no part of the value: it is taken off.
    ///   Nothing else is taken off: no space, no tab, no second line end, no lone CR and no invisible character, at
    ///   the start or at the end.
    /// - **From the clipboard** (`line` false), the text is taken as it is: nothing is taken off, a line end at its
    ///   end too.
    ///
    /// What is left must have the value's form (`isValueText`), which takes no white space and no invisible
    /// character at any place. So a text with one of them at an end is refused, and never saved without it. nil for
    /// no text at all, so that bytes that are not UTF-8 get the same answer as a text that is no value. There is no
    /// branch on what the text holds beyond the line end: one sentence covers every text that is no value.
    ///
    /// **The line end is looked for in Unicode scalars.** In Swift a CR LF is one `Character`, so a look for a LF
    /// at the end of the text's characters does not find it.
    static func value(of text: String?, line: Bool) -> String? {
        guard let text else { return nil }
        var scalars = text.unicodeScalars
        if line, scalars.last == "\n" {
            scalars.removeLast()
            if scalars.last == "\r" { scalars.removeLast() }
        }
        let value = String(scalars)
        return isValueText(value) ? value : nil
    }

    // **The form of a `request_id`** is the table's own, in one place: `LinkWork.isID`, a UUID in lower case with its
    // hyphens, which is exactly 36 ASCII bytes. The program and the app hold an id to it in `read`.

    /// A given id with its letters A to F in lower case: `uuidgen` writes capitals. Only these six ASCII letters
    /// change, so no other character can become a part of an id.
    private static func lowered(_ id: String) -> String {
        String(decoding: id.utf8.map { (0x41...0x46).contains($0) ? $0 + 0x20 : $0 }, as: UTF8.self)
    }

    // ------------------------------------------------------------ the fields, on both sides

    /// The two kinds of a secret, by the hub's own words (`hub.py` `SECRET_KINDS`; `LoginSecret.Kind` in FleetCore).
    public enum Kind: String, Equatable, Sendable { case login, apiKey = "api_key" }

    /// **The fields of one secret**, each in its form and as it was sent. A login has `url` and `username`; an API
    /// key has `env` and can have `url`.
    public struct Fields: Equatable, Sendable {
        public let kind: Kind
        public let env: String?
        public let url: String?
        public let username: String?

        public init(kind: Kind, env: String? = nil, url: String? = nil, username: String? = nil) {
            self.kind = kind
            self.env = env
            self.url = url
            self.username = username
        }
    }

    /// One call, as the tool reads it.
    enum Read: Equatable {
        /// Only `request_id`: a read of that save's state, which changes nothing.
        case state(id: String)
        /// A save: the secret's fields and where its value comes from. `id` is nil only in the program, for a call
        /// that gave none (the program then makes one); the app refuses such a call.
        case save(id: String?, secret: Fields, from: String, path: String?)
    }

    /// **The checks of the fields, in a fixed order**, the same in the program and in the app:
    ///
    /// 1. a field named like a value, whatever it holds;
    /// 2. a field of a seed;
    /// 3. a field that the tool does not take;
    /// 4. `request_id`, which the app needs and the program can make;
    /// 5. a call with only `request_id`, which is a read of the state and has no other check;
    /// 6. `kind`, then the fields that the kind takes, then each field's form;
    /// 7. `from` and `path`, by the rules of `SaveBotToken.read`: the program sends no path, so the app refuses one.
    ///
    /// A field with null is a field that was not given, as in `save_bot_token`. The program takes a given id with
    /// capital letters and puts it in lower case; the app takes only lower case, because the program sends only that.
    static func read(_ fields: [String: JSONValue], app: Bool) -> Result<Read, OwnerChannel.Refusal> {
        if fields.keys.contains(where: OwnerLinkTools.namedLikeAValue) {
            return .failure(.init(OwnerLinkTools.neverAField))
        }
        if fields.keys.contains(where: { seedFields.contains($0) }) { return .failure(.init(noSeedYet)) }
        guard fields.keys.allSatisfy({ Self.fields.contains($0) }) else { return .failure(.init(only)) }
        let given = fields.filter { $0.value != .null }
        var id: String?
        switch given["request_id"] {
        case nil: break
        case .string(let text)?:
            let sent = app ? text : lowered(text)
            guard LinkWork.isID(sent) else { return .failure(.init(requestWord)) }
            id = sent
        default: return .failure(.init(requestWord))
        }
        if app && id == nil { return .failure(.init(appNeedsRequest)) }
        if let id, given.count == 1 { return .success(.state(id: id)) }
        guard case .string(let word)? = given["kind"], let kind = Kind(rawValue: word) else {
            return .failure(.init(kindWord))
        }
        switch kind {
        case .login:
            guard given["url"] != nil, given["username"] != nil, given["env"] == nil else {
                return .failure(.init(kindFields))
            }
        case .apiKey:
            guard given["env"] != nil, given["username"] == nil else { return .failure(.init(kindFields)) }
        }
        var env: String?, url: String?, username: String?
        if let field = given["env"] {
            guard case .string(let text) = field, isKeyName(text) else { return .failure(.init(envWord)) }
            env = text
        }
        if let field = given["url"] {
            guard case .string(let text) = field, isSite(text) else { return .failure(.init(urlWord)) }
            url = text
        }
        if let field = given["username"] {
            guard case .string(let text) = field, isUserName(text) else { return .failure(.init(userWord)) }
            username = text
        }
        var from: String?
        switch given["from"] {
        case nil: break
        case .string(let word)? where ["file", "stdin", "clipboard"].contains(word): from = word
        default: return .failure(.init(fromWord))
        }
        var path: String?
        switch given["path"] {
        case nil: break
        case .string(let text)? where !PyText.strip(text).isEmpty: path = text
        default: return .failure(.init(pathWord))
        }
        if app && path != nil { return .failure(.init(appTakesNoPath)) }
        guard let from else { return .failure(.init(needsFrom)) }
        if !app && from == "file" && path == nil { return .failure(.init(fileNeedsPath)) }
        if from != "file" && path != nil { return .failure(.init(pathOnlyWithFile)) }
        return .success(.save(id: id, secret: Fields(kind: kind, env: env, url: url, username: username), from: from,
                              path: path))
    }

    // ------------------------------------------------------------ the program's side

    /// What the program does with one call.
    public struct Plan: Equatable, Sendable {
        /// The fields for the app: always `request_id`, never `path`, and no field with null.
        public var send: [String: JSONValue]
        /// Where the program reads the value (`SaveBotToken.Source`, which this tool shares). nil for a read of a
        /// save's state: the program then reads no file and not its standard input.
        public var source: SaveBotToken.Source?
        /// The id that the program made for this call, or nil when the caller gave it. Only with a made id do the
        /// words for a lost answer hold the id (`notKnownHereWithID`).
        public var made: String?
    }

    /// **The order in the program**, after the shared check that the arguments are one object: the checks of `read`;
    /// `stdin` refused in the MCP form, whose standard input carries the protocol (`standardInputFree` is false
    /// there); then the id, given or made; then the fields for the app, without `path`. The caller reads the source
    /// that the plan names, and reads none for a read of the state.
    ///
    /// The id is made before any source is read and only for a call that passed every check: a refused call sends
    /// nothing, so its id would name nothing. `newID` is the program's own maker; only a test gives another.
    public static func plan(_ fields: [String: JSONValue], standardInputFree: Bool,
                            newID: () -> String = { UUID().uuidString.lowercased() }) -> Result<Plan, OwnerChannel.Refusal> {
        switch read(fields, app: false) {
        case .failure(let refusal):
            return .failure(refusal)
        case .success(.state(let id)):
            return .success(Plan(send: ["request_id": .string(id)], source: nil, made: nil))
        case .success(.save(let given, let secret, let from, let path)):
            if from == "stdin" && !standardInputFree { return .failure(.init(stdinInMCP)) }
            let id = given ?? newID()
            var send: [String: JSONValue] = ["request_id": .string(id), "kind": .string(secret.kind.rawValue),
                                             "from": .string(from)]
            if let env = secret.env { send["env"] = .string(env) }
            if let url = secret.url { send["url"] = .string(url) }
            if let username = secret.username { send["username"] = .string(username) }
            let source: SaveBotToken.Source
            switch from {
            case "stdin": source = .stdin
            case "clipboard": source = .clipboard
            default: source = .file(path ?? "")
            }
            return .success(Plan(send: send, source: source, made: given == nil ? id : nil))
        }
    }
}
