import Foundation

/// **What the apps decide by in a refusal.** A few lines of the app decide something from what the hub refused: a save is read
/// again once when `team.json` changed meanwhile, a move waits while the agent is in the middle of a turn, a request that
/// already has its answer is no error. They looked for a phrase in the hub's English, which breaks without a sign when
/// the hub changes a word, and which no other language can keep. They read the code that the hub writes beside its line
/// (UI-API.md 1.181) with `HubRefusal.means(_:)`, in this one place and not in a copy at each line.
///
/// **A hub that sends no code is read as it was.** A refusal with no code (an older hub) is read by the phrase that the
/// app looked for before it read codes, so a new app never loses a retry on an old hub. A refusal with a code is read by
/// the code alone, and its words, which may be in the language of the device, decide nothing.
///
/// `app/vectors/refusal-codes.json` holds the codes; `RefusalMeaningTests` holds each meaning to it: each code is there,
/// its English holds the phrase, and no other code of the table has that phrase in its English.
public enum RefusalMeaning: CaseIterable, Sendable {
    /// `team.json` changed since the app read it (409): a save reads it again and sends once more.
    case teamChanged
    /// The agent is in the middle of a turn (409): a move waits for the turn to end.
    case agentMidTurn
    /// The agent has an open sign-in (409): a move waits for it.
    case agentOpenSignIn
    /// The owner request has its answer already (409): the press that answered it is no error.
    case requestAnswered
    /// The hub's database was restored since the app read it (409): the app reads it again. The phone's line.
    case hubChanged
    /// The address that the call came from is no owner device (403). The phone's line.
    case notOwnerDevice

    /// The codes of the hub (`refusal_words.py`) that say it.
    public var codes: [String] {
        switch self {
        case .teamChanged: ["team_changed", "team_changed_lines"]
        case .agentMidTurn: ["agent_mid_turn"]
        case .agentOpenSignIn: ["agent_open_signin"]
        case .requestAnswered: ["request_answered"]
        case .hubChanged: ["hub_changed", "hub_changed_sending"]
        case .notOwnerDevice: ["not_owner_device", "not_owner_device_no_code"]
        }
    }

    /// What the English of an older hub holds, in small letters: the phrase that the apps looked for before codes.
    public var phrase: String {
        switch self {
        case .teamChanged: "team.json changed"
        case .agentMidTurn: "middle of a turn"
        case .agentOpenSignIn: "open sign-in"
        case .requestAnswered: "already answered"
        case .hubChanged: "generation"
        case .notOwnerDevice: "owner device"
        }
    }
}

extension HubRefusal {
    /// Whether the hub refused for this reason: by its code, and for a refusal with no code (an older hub) by the
    /// phrase of its English line. The status is the caller's own test, as it always was.
    public func means(_ meaning: RefusalMeaning) -> Bool {
        if let code { return meaning.codes.contains(code) }
        return hubWords.lowercased().contains(meaning.phrase)
    }
}
