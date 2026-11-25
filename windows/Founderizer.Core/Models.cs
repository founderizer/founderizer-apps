using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Founderizer.Core;

// The answers of the device routes (hub.py DEVICE_PATHS), field for field as the Swift decoders read them:
// app/ios/Sources/MobileAPI.swift for the phone's own reads, and FleetCore's models where the hub sends the same rows.
//
// The rules of a Swift `Decodable`, kept by CoreJson's options: a field that is not optional must be there and must not
// be null (RespectRequiredConstructorParameters and RespectNullableAnnotations), an optional one may be absent or null
// (a default of null), a number is never read from text (Strict), and a field that this side does not know is skipped.
// Each record's own checks (sizes, unique ids, the generation) are in HubDecode, as in the Swift decoders.

/// <summary>GET /ui/mobile: the heads of the whole fleet, with an ETag (MobileSnapshot).</summary>
public sealed record MobileSnapshot(
    long SchemaVersion,
    string Db,
    double Time,
    IReadOnlyList<MobileAgent> Agents,
    IReadOnlyList<OwnerNeed> Needs,
    IReadOnlyList<MobileTaskHead> Tasks,
    IReadOnlyList<MobileTaskHead> Recent,
    IReadOnlyList<TaskHold> Holds,
    IReadOnlyList<TaskOutcome> Outcomes,
    ManagerWarning? ManagerWarning = null,
    IReadOnlyList<string>? UiFeatures = null,
    IReadOnlyList<OwnerNeed>? AnsweredNeeds = null,
    MobileCounts? Counts = null,
    string? Token = null,
    string? EndedMark = null)
{
    /// <summary>The hub's change token as one that the wait can ask from, or null.</summary>
    public LiveToken? LiveToken => Core.LiveToken.Parse(Token);

    /// <summary>The hub serves this owner feature.</summary>
    public bool Offers(string feature) => UiFeatures is not null && UiFeatures.Contains(feature);

    /// <summary>This hub takes a message to this agent: the route is there and the agent is active (canChat).</summary>
    public bool CanChat(string name)
    {
        MobileAgent? agent = null;
        foreach (var a in Agents) if (a.Name == name) { agent = a; break; }
        if (agent is null) return false;
        return (name == "manager" || Offers("direct_chat")) && agent.DirectChat != false && agent.Active != false;
    }
}

public sealed record MobileCounts(long TasksOpen, long NeedsOpen, long Messages, long Reports);

/// <summary>One agent's row of GET /ui/mobile (MobileAgent). `can` is its Tools boxes (team.json `can`): without "shell",
/// a worker's or a lead's sessions record no outcome, and the owner checks its tasks' unknown outcomes
/// (<see cref="TaskOutcome.ShellOff"/>). Null from a hub that does not send it, which reads as [], as the hub sends a
/// missing list. `alive` is the sessions that its helper lists, comma-separated ("manager,owner-chat"): the setup of the
/// owner's computer reads it for the end of a manager's first setup (step 2, piece L4).</summary>
public sealed record MobileAgent(
    string Name,
    string Role,
    string Runtime,
    long OpenTasks,
    IReadOnlyList<MobileUsageWindow> Usage,
    string? Title = null,
    bool? Active = null,
    bool? DirectChat = null,
    double? LastSeen = null,
    RuntimeLimit? Limit = null,
    MobilePreview? Last = null,
    string? Machine = null,
    double? TurnEndedAfter = null,
    double? WaitsSince = null,
    bool? ChatUndelivered = null,
    IReadOnlyList<string>? Can = null,
    string? Alive = null)
{
    /// <summary>The helper answered in the last minute of the hub's own clock (helperIsRecent).</summary>
    public bool HelperIsRecent(double serverTime) =>
        LastSeen is { } seen && serverTime - seen >= -5 && serverTime - seen < 60;
}

public sealed record MobileUsageWindow(string? Label = null, double? UsedPercent = null, double? ResetsAt = null);

/// <summary>The newest line of one conversation: who wrote it (`owner` or `agent`), when, and its first characters.</summary>
public sealed record MobilePreview(double Ts, string Side, string Preview);

/// <summary>A task's head: no details, done-when or result, which come with the task itself (MobileTaskHead).</summary>
public sealed record MobileTaskHead(
    long Id,
    string Title,
    string State,
    string Owner,
    string Requester,
    long Attempt,
    double Created,
    string? Goal = null,
    string? Needs = null,
    long? Accepted = null,
    double? Started = null,
    double? LastActivity = null,
    double? Delivered = null,
    double? CheckedAt = null,
    string? WaitingOn = null,
    long? Follows = null,
    double? StalledSince = null,
    long? NudgeLevel = null,
    double? MissingSince = null,
    bool? Works = null,
    string? Doing = null,
    double? ParkedUntil = null,
    long? Parent = null,
    long? TriggerId = null)
{
    public bool IsTerminal => State is "completed" or "failed" or "rejected" or "canceled";
}

/// <summary>GET /ui/mobile/chat/&lt;agent&gt;: one page of a conversation, oldest first (MobileChatPage).</summary>
public sealed record MobileChatPage(string Db, string Agent, IReadOnlyList<MobileChatItem> Items, double Cursor);

/// <summary>One line of a conversation: a message of the owner, or a report of the agent (MobileChatItem). Its `id` is a
/// message's request UUID or a report's number; <see cref="Key"/> holds either as text.</summary>
public sealed record MobileChatItem(
    string Kind,
    double Ts,
    [property: JsonPropertyName("id")] JsonElement RawId,
    string Text,
    string? Client = null,
    double? ReadAt = null,
    string? Replaces = null,
    string? About = null,
    string? InReplyTo = null,
    [property: JsonPropertyName("attachments")] IReadOnlyList<MessageAttachment>? RawAttachments = null,
    bool? Pushed = null,
    long? AnswerTo = null,
    double? Edited = null)
{
    /// <summary>A message's request UUID, or a report's number as text. Set by HubDecode.</summary>
    [JsonIgnore] public string Key { get; init; } = "";
    /// <summary>The files that went with the owner's message; none from a hub without them.</summary>
    [JsonIgnore] public IReadOnlyList<MessageAttachment> Attachments => RawAttachments ?? [];
    [JsonIgnore] public string Id => Kind + "-" + Key;
    [JsonIgnore] public bool IsFromAgent => Kind == "report";
    [JsonIgnore] public bool IsPushed => Pushed == true;
    /// <summary>His words on their way, which the chat itself draws until the hub's copy comes (the Mac's event 0).</summary>
    [JsonIgnore] public bool OnItsWay { get; init; }
}

/// <summary>GET /ui/mobile/task/&lt;id&gt;: the task itself, its notes after the cursor, its holds and outcomes.</summary>
public sealed record MobileTaskPage(
    string Db,
    FleetTask Task,
    IReadOnlyList<ProgressNote> Notes,
    IReadOnlyList<TaskHold> Holds,
    IReadOnlyList<TaskOutcome> Outcomes,
    long Cursor,
    IReadOnlyList<TaskPermission>? Permissions = null,
    IReadOnlyList<TaskSteer>? Steers = null,
    IReadOnlyList<MobileTaskHead>? Subtasks = null,
    MobileTaskHead? ParentTask = null);

/// <summary>A task in full (FleetCore's FleetTask). `goal` must be there and may be null, which reads as none.</summary>
public sealed record FleetTask(
    long Id,
    string Title,
    string Details,
    string DoneWhen,
    string Needs,
    string? Goal,
    string Owner,
    string Requester,
    string State,
    double Created,
    long Attempt,
    long Restarts,
    long NudgeLevel,
    long StopSent,
    long? GoalId = null,
    long? TriggerId = null,
    long? TriggerRun = null,
    string? Project = null,
    string? Why = null,
    long? Parent = null,
    long? Follows = null,
    double? Started = null,
    double? LastActivity = null,
    double? Delivered = null,
    double? CheckedAt = null,
    double? MissingSince = null,
    string? LastTool = null,
    string? Outcome = null,
    string? What = null,
    [property: JsonPropertyName("where_")] string? Where = null,
    string? How = null,
    string? CheckNote = null,
    string? WaitingOn = null,
    string? CaseId = null,
    long? Accepted = null,
    string? LivePath = null,
    double? ParkedUntil = null,
    double? StalledSince = null,
    string? StalledReason = null)
{
    public bool IsTerminal => State is "completed" or "failed" or "rejected" or "canceled";
    /// <summary>The goal in words, "" for none.</summary>
    public string GoalText => Goal ?? "";
}

public sealed record ProgressNote(long Id, long Task, string Agent, double Ts, string Text);

public sealed record TaskHold(
    long Id,
    long Task,
    string Kind,
    string State,
    long Attempt,
    string? Detail = null,
    double? Released = null,
    string? ResumeMode = null,
    string? By = null);

public sealed record TaskOutcome(long Id, long Task, long Attempt, string Title, string Kind, string State,
                                 string? Note = null, string? Checker = null)
{
    /// <summary>Whether the owner checks this action, and not its agent (FleetCore's TaskOutcome.waitsOnOwner; the owner,
    /// 19 November 2026, of an orange check on a task whose new session had not started yet: "who needs to check?"): its
    /// outcome is not known, and no session of the task's agent comes to check it, because a hold that is not released
    /// holds the task (any hold), the task has ended (<paramref name="taskEnded"/> null: the reading has no such task,
    /// which counts as ended), or its agent's sessions cannot record a finding (<paramref name="shellOff"/>). While the
    /// task runs or waits for its next session, each new session of its agent gets the list of these actions first and
    /// records each one, so no Needs-you row, count or orange line asks the owner. A hub that says who checks it
    /// decides alone, as on the Mac (<paramref name="routed"/>: the hub serves <see cref="RoutedFeature"/>, and the row
    /// has its <see cref="Checker"/>, owner API 1.324: "" the task's own agent, an agent's name, or "owner"): only
    /// "owner" is the owner's, because the hub gives a check that the task's agent cannot make to its requester first.
    /// A null Checker, or a hub that does not serve the name (an older one, or one that went back to an older release
    /// and still sends the column), keeps the rule above. The hub's owner_count, the number on the phone's icon, counts
    /// the same rows.</summary>
    public bool WaitsOnOwner(IReadOnlyList<TaskHold> holds, bool? taskEnded, bool shellOff, bool routed = false) =>
        routed && Checker is not null
            ? State == "unknown" && Checker == "owner"
            : State == "unknown" && (shellOff || taskEnded != false || holds.Any(h => h.Task == Task && h.State != "released"));

    /// <summary>The feature name of a hub that gives each unknown outcome its <see cref="Checker"/>.</summary>
    public const string RoutedFeature = "outcome_checks";

    /// <summary>Whether the sessions of an agent with this role and these Tools boxes have no resolve_outcome (FleetCore's
    /// TaskOutcome.shellOff): a worker's or a lead's whose Shell box is off, as the hub's shell_off reads it. A manager's
    /// sessions always have it. Null boxes read as not off; <see cref="Activity.ShellOff"/> gives a missing list as [],
    /// as the iPhone does.</summary>
    public static bool ShellOff(string? role, IReadOnlyList<string>? can) =>
        role is "worker" or "lead" && can is not null && !can.Contains("shell");
}

public sealed record RuntimeLimit(double Since, double Until, bool ResetKnown, long? Task = null);

public sealed record ManagerWarning(string Kind, double Since);

/// <summary>The mark of a file where no picture shows: a picture's, a PDF's, a ZIP's, or a text's.</summary>
public enum FileSymbol { Picture, Pdf, Zip, Text }


/// <summary>One Needs-you item (FleetCore's OwnerNeed). `secret` is read leniently, as Swift's NeedSecret reads it: see
/// <see cref="NeedSecret.From"/>. `replaced_by` (owner API 1.274) is the id of the item that took this one's place (the
/// manager raised it again with `replaces`, or a new plan of team changes replaced it), whose answer is the hub's own
/// words; null on every other item and from a hub before that version. No page draws a card for it
/// (<see cref="Activity.Drawn"/>). `team_state`, `team_reason` and `task` (owner API 1.280, feature `need_marks`) say what
/// an answered card's mark stands on (<see cref="AnswerMark"/>): where a team card's plan stands after his yes ("making",
/// "made", "not_made", else null), the hub's words for a plan that it did not make, and the task that his answer lets go
/// on. They are no words of the card: no check of a pressed card compares them, as none compares `recommended`. `give`
/// (the lane "Give on a card") is the grant that the item's first option makes, read only for whether it is there
/// (<see cref="Gives"/>).
/// `pictures` (owner API 1.285, feature `need_pictures`): one picture for each option,
/// in the order of `options`, as a file of a message is; null for an item with none and from a hub before that version.
/// All or none: the hub gives null when the bytes of one picture are gone. A card draws them only as
/// <see cref="NeedPictures.Drawn"/> says, and the answer does not change: a press of an option's words sends its
/// index.
/// `clarify` and `talk` (owner API 1.272, feature `need_clarify`): the card takes his message under it now
/// (<see cref="Clarifies"/>), and his talk with the manager there, oldest first (<see cref="NeedMessage"/>); a hub with
/// `need_talk` alone sends `talk` empty, and one before it none.</summary>
public sealed record OwnerNeed(
    long Id,
    string Title,
    string Why,
    string Todo,
    double Raised,
    string By,
    string? Answer = null,
    double? Answered = null,
    IReadOnlyList<string>? Options = null,
    long? Chosen = null,
    string? Kind = null,
    long? Conversation = null,
    long? Question = null,
    [property: JsonPropertyName("secret")] JsonElement? RawSecret = null,
    string? DoorCall = null,
    string? DoorFleet = null,
    string? DoorHost = null,
    string? DoorScript = null,
    string? GithubApp = null,
    long? AddDevice = null,
    string? Details = null,
    bool? Multi = null,
    IReadOnlyList<long>? Chose = null,
    long? ReplacedBy = null,
    string? TeamState = null,
    string? TeamReason = null,
    long? Task = null,
    [property: JsonPropertyName("give")] JsonElement? RawGive = null,
    IReadOnlyList<MessageAttachment>? Pictures = null,
    bool? Clarify = null,
    IReadOnlyList<NeedMessage>? Talk = null,
    bool? Team = null)
{
    [JsonIgnore] public bool IsOpen => Answered is null && Answer is null;

    /// <summary>The card takes his message under it now (OwnerNeed.clarifies): an open item that the hub says takes one
    /// (`clarify`), on a hub that names <see cref="NeedClarify.Feature"/>. The hub says false for a key request, which
    /// has its own Needs clarification, for a conversation's item, which is that person's question, and for an item
    /// that another agent than the manager raised.</summary>
    public bool Clarifies(MobileSnapshot? fleet) => IsOpen && Clarify == true && fleet?.Offers(NeedClarify.Feature) == true;

    /// <summary>His talk under the card as the hub gives it (OwnerNeed.shownTalk): on a hub that names the feature, the
    /// whole talk, open or answered, also where the card takes no more of it; none on a hub without it.</summary>
    public IReadOnlyList<NeedMessage> ShownTalk(MobileSnapshot? fleet) =>
        fleet?.Offers(NeedClarify.Feature) == true ? Talk ?? [] : [];
    [JsonIgnore] public NeedSecret? Secret => NeedSecret.From(RawSecret);
    /// <summary>Its first option gives a grant (OwnerNeed.give): Give, whose press makes the grant with his answer.</summary>
    [JsonIgnore] public bool Gives => RawGive is { ValueKind: JsonValueKind.Object };
    /// <summary>A key that he saved answered this secret request (OwnerNeed.answeredWithKey), or he answered it in his own
    /// words (Needs clarification, `clarified`), which the Mac counts as words (OwnerNeed.answeredInWords): neither card
    /// has the mark of an answered card (<see cref="AnswerMark"/>).</summary>
    [JsonIgnore] public bool AnsweredWithKeyOrWords =>
        AsksForSecret && !IsOpen && Secret is { } secret && (secret.Saved is not null || secret.Clarified);
    [JsonIgnore] public bool AsksForSecret => Kind == "secret";

    /// <summary>**Its first option starts a step that only the Mac's press starts** (FleetCore's
    /// `OwnerNeed.firstOptionStartsOnTheMac`, which the iPhone's `MobileStore.startsOnTheMac` holds to): an item of two
    /// options or more, which is no team yes, no full access and no give (FleetCore's `onlyOnAComputer`), whose first
    /// option makes a GitHub App in the account that `github_app` names (owner feature `door_setup`: GitHub's manifest
    /// flow, GitHubManifestFlow), or opens the Add device picture (`add_device` 1, owner feature `recovery_copy`). This
    /// app starts neither, and a press here answered the item with choice 0: the hub closed it, and nothing started. So
    /// the option stands, and no route of this app sends it; the other options and his own words still go.</summary>
    [JsonIgnore] public bool FirstOptionOnTheMac =>
        Choices.Count >= 2 && Team != true && DoorHost is not { Length: > 0 } && !Gives && (GithubApp is { Length: > 0 } || AddDevice == 1);

    /// <summary>Option <paramref name="choice"/> is one that only the Mac's press starts (<see cref="FirstOptionOnTheMac"/>).</summary>
    public bool OnlyOnTheMac(long choice) => choice == 0 && FirstOptionOnTheMac;
    [JsonIgnore] public bool TakesFiles => Conversation is null && !AsksForSecret;

    /// <summary>The task of the item stands on the front of its card, under the reason (OwnerNeed.taskInFront, Founderizer
    /// 0.1.239; the owner, 15 November 2026: "the task itself need to be very clear"): the words that an agent wrote as
    /// what he does. Not the hub's own sentence of a secret request or of a conversation's item (both have a kind), and
    /// not an item with a door call, whose yes signs a call by its hash: those keep their task behind Details.</summary>
    [JsonIgnore] public bool TaskInFront => Kind is null && DoorCall is null;

    /// <summary>The options as one answer each, or none (OwnerNeed.choices): fewer than two, an empty label, a control
    /// character, or two that say the same thing make it no choice. One option is a choice on an item with one picture
    /// for it (owner API 1.285): one design to approve, whose no is his own words.</summary>
    [JsonIgnore]
    public IReadOnlyList<string> Choices
    {
        get
        {
            var given = new List<string>();
            foreach (var option in Options ?? []) given.Add(option.Trim());
            if (given.Count < (Pictures?.Count == given.Count ? 1 : 2)) return [];
            var seen = new HashSet<string>();
            foreach (var label in given)
            {
                if (label.Length == 0) return [];
                foreach (var c in label) if (c < 32 || c == 127) return [];
                if (!seen.Add(label.ToLowerInvariant())) return [];
            }
            return given;
        }
    }

    /// <summary>The options combine: he ticks any of them and sends them together.</summary>
    [JsonIgnore] public bool Combines => Multi == true && Choices.Count >= 2;

    /// <summary>He answered it in his own words (OwnerNeed.answeredInWords): no option pressed or ticked, and no secure
    /// form.</summary>
    [JsonIgnore] public bool AnsweredInWords => !IsOpen && Chosen is null && (Chose ?? []).Count == 0 && !AsksForSecret;

    /// <summary><paramref name="words"/> are an option of this request, or its ticked options as the hub joins them
    /// (OwnerNeed.offers): what a press writes as the answer.</summary>
    public bool Offers(string words)
    {
        var choices = Choices;
        if (choices.Contains(words)) return true;
        var parts = words.Split("; ");
        return Combines && parts.Length > 1 && parts.All(choices.Contains);
    }
}

/// <summary>**Needs clarification on every card** (owner feature `need_clarify`, owner API 1.272; FleetCore's NeedClarify;
/// the owner, 20 November 2026: "a button link, that then shows the extra text input", and "Keep Your answer too"): under
/// his answer a quiet link opens one field, and his message there goes to the manager while the item stays open
/// (<see cref="OwnerCommand.Talk"/>). The manager's replies and his messages stand in the card over the answers
/// (<see cref="OwnerNeed.Talk"/>). His answer still closes the item.</summary>
public static class NeedClarify
{
    /// <summary>`ui_features` of a hub that takes his message under a card (`POST /ui/needs/&lt;id&gt;/talk`).</summary>
    public const string Feature = "need_clarify";
    /// <summary>The hub's most for one message (NEED_TALK_CHARS), as Python counts it: code points, not the characters
    /// that he sees.</summary>
    public const int Most = 2000;

    /// <summary>The length of a message as the hub counts it: its code points.</summary>
    public static int Length(string text)
    {
        var count = 0;
        foreach (var _ in text.EnumerateRunes()) count++;
        return count;
    }
}

/// <summary>One message of the talk under a card (FleetCore's NeedMessage): `who` is `owner` or the agent that replied.
/// The hub's receipt of his message carries the card's talk too.</summary>
public sealed record NeedMessage(string Who, string Text, double Ts)
{
    [JsonIgnore] public bool FromOwner => Who == "owner";
}

/// <summary>What a secret request asks for (owner feature `secret_requests`). It names a secret and never holds a value.
/// A field that does not read is left out rather than failing the read, as in Swift. `clarified` (feature
/// `need_clarify`): he answered the request in his own words, with no key.</summary>
public sealed record NeedSecret(string Kind, string? Env, string? Site, IReadOnlyDictionary<string, string> Give,
                                string? Saved, bool Clarified = false)
{
    /// <summary>The secret of an item, or null. HubDecode refuses a `secret` that is neither an object nor null.</summary>
    public static NeedSecret? From(JsonElement? raw)
    {
        if (raw is not { ValueKind: JsonValueKind.Object } value) return null;
        string? Text(string name) =>
            value.TryGetProperty(name, out var field) && field.ValueKind == JsonValueKind.String ? field.GetString() : null;
        var kind = Text("kind") is "login" ? "login" : "api_key";
        var env = Text("env");
        if (env is not null && !Patterns.Variable().IsMatch(env)) env = null;
        var site = Text("site");
        if (site is not null && !IsAddress(site)) site = null;
        var give = new Dictionary<string, string>();
        if (value.TryGetProperty("give", out var grants) && grants.ValueKind == JsonValueKind.Object)
        {
            var all = true;
            foreach (var p in grants.EnumerateObject()) if (p.Value.ValueKind != JsonValueKind.String) all = false;
            if (all)
                foreach (var p in grants.EnumerateObject())
                    if (p.Value.GetString() is "use" or "read") give[p.Name] = p.Value.GetString()!;
        }
        var saved = Text("saved");
        if (saved is not null && !Patterns.SecretReference().IsMatch(saved)) saved = null;
        var clarified = value.TryGetProperty("clarified", out var words) && words.ValueKind == JsonValueKind.True;
        return new NeedSecret(kind, env, site, give, saved, clarified);
    }

    private static bool IsAddress(string text) =>
        System.Uri.TryCreate(text, System.UriKind.Absolute, out var uri) && (uri.Scheme is "https" or "http") &&
        uri.Host.Length > 0 && uri.UserInfo.Length == 0;
}

/// <summary>POST /ui/owner/enroll: this device's key, given once and never again.</summary>
public sealed record MobileEnrollment(string Device, string Label, string Key, double? Since = null);

/// <summary>GET /ui/owner/devices as a device reads it: `key` says that the hub has one, and is never a key.</summary>
public sealed record MobileDeviceList(string Db, IReadOnlyList<MobileDevice> Devices)
{
    public MobileDevice? ThisDevice
    {
        get
        {
            foreach (var d in Devices) if (d.ThisDevice == true) return d;
            return null;
        }
    }
}

/// <summary>One owner device. <see cref="Kind"/> (owner API 1.149): the kind of app that took its key, "iphone" or
/// "windows", null while it has none or on a hub of before the kind.</summary>
public sealed record MobileDevice(string Device, string Label, string Address, bool? Key = null, double? Since = null,
                                  double? LastSeen = null, bool? ThisDevice = null, string? Kind = null);

/// <summary>GET /ui/knowledge: one owner file with its text, which is untrusted display content.</summary>
public sealed record KnowledgeFile(string Db, string Path, string Title, string Text, string? Source = null);

/// <summary>The answer of GET /ui/wait.</summary>
public sealed record WaitAnswer(string Db, string Token);

/// <summary>The hub's receipt of POST /ui/messages and POST /ui/needs/&lt;id&gt; (FleetCore's SendReceipt).</summary>
public sealed record SendReceipt(
    bool Ok,
    string RequestId,
    long EventId,
    double Created,
    bool Replayed,
    string Client,
    string? Recipient = null,
    string? ReplacesRequestId = null,
    IReadOnlyList<long>? Attachments = null,
    double? ReadAt = null,
    bool? Edited = null,
    string? MessageRequestId = null);

/// <summary>GET /ui/mobile/ended (owner API 1.166): the head of every ended task, by id, with its schedule, and the
/// `ended_mark` of GET /ui/mobile that it is of. With `window=1` (owner API 1.270) the heads of the newest ids and
/// <see cref="Older"/>, where the others are; a reading that the store joined holds every head and no Older.</summary>
public sealed record EndedReading(string Db, string Mark, IReadOnlyList<MobileTaskHead> Tasks, EndedOlder? Older = null);

/// <summary>`older` of GET /ui/mobile/ended?window=1 (owner API 1.270): the id below which the heads are in blocks, the ids
/// of one block, and a mark that differs when a block below <see cref="Before"/> changed, or Before did.</summary>
public sealed record EndedOlder(long Before, long Block, string Mark)
{
    public bool IsValid => Block > 0 && Before >= 0 && Before % Block == 0 && Mark.Length > 0;
}

/// <summary>GET /ui/mobile/ended?blocks=1 (owner API 1.270): the blocks below the window, each with its mark.</summary>
public sealed record EndedBlockList(string Db, long Before, long Block, string Mark, IReadOnlyList<EndedBlockEntry> Blocks)
{
    public EndedOlder Head => new(Before, Block, Mark);
}

/// <summary>One block of <see cref="EndedBlockList"/>: its first id, its mark and the number of its heads.</summary>
public sealed record EndedBlockEntry(long From, string Mark, long Tasks);

/// <summary>GET /ui/mobile/ended?block=&lt;from&gt; (owner API 1.270): the heads of the ended tasks of one block, by id,
/// and its mark of the same moment.</summary>
public sealed record EndedBlock(string Db, long From, string Mark, IReadOnlyList<MobileTaskHead> Tasks);

/// <summary>A task's guidance as the hub keeps it (FleetCore's TaskSteer).</summary>
public sealed record TaskSteer(long Id, long Task, long Attempt, string Text, double Created, string RequestId,
                               string Client, double? ReadAt = null)
{
    public bool IsValid => Id > 0 && Task > 0 && Attempt > 0 && Text.Length > 0 && Text.Length <= 4000 &&
                           double.IsFinite(Created);
}

/// <summary>The hub's receipt of an owner command (FleetCore's ControlReceipt), with the fields that the device's
/// commands read: a task's control and its guidance, and his message under a card, whose receipt names the item and
/// carries its talk with that message in it (`need`, `talk`).</summary>
public sealed record ControlReceipt(
    bool Ok,
    string RequestId,
    string Client,
    bool Replayed,
    JsonElement? Changed = null,
    TaskSteer? Steer = null,
    TaskHold? Hold = null,
    long? Need = null,
    IReadOnlyList<NeedMessage>? Talk = null)
{
    /// <summary>`changed` when the hub sent true or false; null for a list or nothing.</summary>
    [JsonIgnore]
    public bool? ChangedFlag => Changed is { ValueKind: JsonValueKind.True } ? true
        : Changed is { ValueKind: JsonValueKind.False } ? false : null;
}

/// <summary>One file that went with a message (FleetCore's MessageAttachment).</summary>
public sealed record MessageAttachment(long Id, string Name, string Mime, long Size, string Sha256, double Created,
                                       AttachmentKept? Kept = null)
{
    /// <summary>A picture, which a message shows whole (MessageAttachment.isImage).</summary>
    public bool IsImage => Mime.StartsWith("image/", System.StringComparison.Ordinal);

    /// <summary>The mark that stands for it where no picture shows (MessageAttachment.symbol).</summary>
    public FileSymbol Symbol => Mime switch
    {
        _ when IsImage => FileSymbol.Picture,
        "application/pdf" => FileSymbol.Pdf,
        "application/zip" => FileSymbol.Zip,
        _ => FileSymbol.Text,
    };

    /// <summary>The types that the hub takes, and the extension that each keeps.</summary>
    public static readonly IReadOnlyDictionary<string, string> Types = new Dictionary<string, string>
    {
        ["image/png"] = "png", ["image/jpeg"] = "jpg", ["image/gif"] = "gif", ["image/webp"] = "webp",
        ["application/pdf"] = "pdf", ["application/zip"] = "zip", ["text/plain"] = "txt",
        ["text/markdown"] = "md", ["text/csv"] = "csv", ["application/json"] = "json",
    };
    public const long SizeLimit = 25L * 1024 * 1024;
    public const int PerMessage = 4;

    /// <summary>What the hub said about this file is a file that an app may ask for (validate).</summary>
    public bool IsValid
    {
        get
        {
            if (Id <= 0 || Name.Length == 0 || System.Text.Encoding.UTF8.GetByteCount(Name) > 200) return false;
            if (!Types.ContainsKey(Mime) || Size <= 0 || Size > SizeLimit || Created <= 0) return false;
            if (Sha256.Length != 64) return false;
            foreach (var c in Sha256) if (!(c is >= '0' and <= '9' or >= 'a' and <= 'f')) return false;
            return Kept is null || (Kept.At > 0 && Kept.Knowledge != "");
        }
    }

    /// <summary>The type that the hub takes for a file name, or null.</summary>
    public static string? MimeFor(string name)
    {
        var ext = System.IO.Path.GetExtension(name).TrimStart('.').ToLowerInvariant();
        if (ext == "jpeg") return "image/jpeg";
        if (ext == "markdown") return "text/markdown";
        foreach (var (mime, known) in Types) if (known == ext) return mime;
        return null;
    }

    /// <summary>A name that travels in a header: ASCII letters, digits, . _ - and spaces, never a path, with the
    /// extension of its type (the hub's own rule, step by step).</summary>
    public static string SafeName(string name, string mime)
    {
        var keep = new System.Text.StringBuilder();
        foreach (var c in name)
            keep.Append(c is >= 'A' and <= 'Z' or >= 'a' and <= 'z' or >= '0' and <= '9' or '.' or '_' or '-' or ' ' ? c : '_');
        var cleaned = keep.ToString().Trim(' ');
        var lead = 0;
        while (lead < cleaned.Length && cleaned[lead] is '.' or '-') lead++;
        if (lead > 0) cleaned = "_" + cleaned[lead..];
        if (cleaned.Length > 80) cleaned = cleaned[..80];
        var ext = "." + (Types.TryGetValue(mime, out var known) ? known : "bin");
        return cleaned.ToLowerInvariant().EndsWith(ext, StringComparison.Ordinal) ? cleaned
            : (cleaned.Length == 0 ? "file" : cleaned) + ext;
    }

    /// <summary>The size in the owner's words: "512 B", "40 KB", "2.5 MB".</summary>
    public static string SizeWords(long size, System.Globalization.CultureInfo? culture = null)
    {
        culture ??= System.Globalization.CultureInfo.CurrentCulture;
        if (size < 1024) return size.ToString("N0", culture) + " B";
        if (size < 1024 * 1024) return (size / 1024).ToString("N0", culture) + " KB";
        // Swift's FormatStyle rounds half to even: 1,310,720 B is "1.2 MB".
        return Math.Round(size / (1024.0 * 1024), 1, MidpointRounding.ToEven).ToString("N1", culture) + " MB";
    }

    /// <summary>These bytes are the file that the hub named: the same count and the same SHA-256.</summary>
    public bool Matches(System.ReadOnlySpan<byte> data) =>
        data.Length == Size && System.Convert.ToHexStringLower(System.Security.Cryptography.SHA256.HashData(data)) == Sha256;
}

/// <summary>When the owner kept a file past the ninety days, and the knowledge file that it became (null when kept
/// alone).</summary>
public sealed record AttachmentKept(double At, string? Knowledge = null);

/// <summary>The body of a refusal: `{"error": ..., "auth": ...}`.</summary>
internal sealed record RefusalBody(string? Error = null, string? Auth = null, string? Code = null);
