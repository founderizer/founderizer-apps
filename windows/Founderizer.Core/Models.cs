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
    string? Token = null)
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

/// <summary>One agent's row of GET /ui/mobile (MobileAgent).</summary>
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
    bool? ChatUndelivered = null)
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
    string? Doing = null)
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
    long? AnswerTo = null)
{
    /// <summary>A message's request UUID, or a report's number as text. Set by HubDecode.</summary>
    [JsonIgnore] public string Key { get; init; } = "";
    /// <summary>The files that went with the owner's message; none from a hub without them.</summary>
    [JsonIgnore] public IReadOnlyList<MessageAttachment> Attachments => RawAttachments ?? [];
    [JsonIgnore] public string Id => Kind + "-" + Key;
    [JsonIgnore] public bool IsFromAgent => Kind == "report";
    [JsonIgnore] public bool IsPushed => Pushed == true;
}

/// <summary>GET /ui/mobile/task/&lt;id&gt;: the task itself, its notes after the cursor, its holds and outcomes.</summary>
public sealed record MobileTaskPage(
    string Db,
    FleetTask Task,
    IReadOnlyList<ProgressNote> Notes,
    IReadOnlyList<TaskHold> Holds,
    IReadOnlyList<TaskOutcome> Outcomes,
    long Cursor);

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
                                 string? Note = null);

public sealed record RuntimeLimit(double Since, double Until, bool ResetKnown, long? Task = null);

public sealed record ManagerWarning(string Kind, double Since);

/// <summary>One message in the discussion of a Needs-you item: `who` is `owner` or the agent that replied.</summary>
public sealed record NeedMessage(string Who, string Text, double Ts)
{
    public bool FromOwner => Who == "owner";
}

/// <summary>One Needs-you item (FleetCore's OwnerNeed). `secret` is read leniently, as Swift's NeedSecret reads it: see
/// <see cref="NeedSecret.From"/>.</summary>
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
    IReadOnlyList<NeedMessage>? Talk = null)
{
    [JsonIgnore] public bool IsOpen => Answered is null && Answer is null;
    [JsonIgnore] public NeedSecret? Secret => NeedSecret.From(RawSecret);
    [JsonIgnore] public bool AsksForSecret => Kind == "secret";
    [JsonIgnore] public bool TakesFiles => Conversation is null && !AsksForSecret;

    /// <summary>The options as one answer each, or none (OwnerNeed.choices): fewer than two, an empty label, a control
    /// character, or two that say the same thing make it no choice.</summary>
    [JsonIgnore]
    public IReadOnlyList<string> Choices
    {
        get
        {
            var given = new List<string>();
            foreach (var option in Options ?? []) given.Add(option.Trim());
            if (given.Count < 2) return [];
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
}

/// <summary>What a secret request asks for (owner feature `secret_requests`). It names a secret and never holds a value.
/// A field that does not read is left out rather than failing the read, as in Swift.</summary>
public sealed record NeedSecret(string Kind, string? Env, string? Site, IReadOnlyDictionary<string, string> Give,
                                string? Saved)
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
        return new NeedSecret(kind, env, site, give, saved);
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

/// <summary>A task's guidance as the hub keeps it (FleetCore's TaskSteer).</summary>
public sealed record TaskSteer(long Id, long Task, long Attempt, string Text, double Created, string RequestId,
                               string Client, double? ReadAt = null)
{
    public bool IsValid => Id > 0 && Task > 0 && Attempt > 0 && Text.Length > 0 && Text.Length <= 4000 &&
                           double.IsFinite(Created);
}

/// <summary>The hub's receipt of an owner command (FleetCore's ControlReceipt), with the fields that the device's
/// commands read: a task's control and guidance, and the discussion of a Needs-you item.</summary>
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
        return (size / (1024.0 * 1024)).ToString("N1", culture) + " MB";
    }

    /// <summary>These bytes are the file that the hub named: the same count and the same SHA-256.</summary>
    public bool Matches(System.ReadOnlySpan<byte> data) =>
        data.Length == Size && System.Convert.ToHexStringLower(System.Security.Cryptography.SHA256.HashData(data)) == Sha256;
}

/// <summary>When the owner kept a file past the ninety days, and the knowledge file that it became (null when kept
/// alone).</summary>
public sealed record AttachmentKept(double At, string? Knowledge = null);

/// <summary>The body of a refusal: `{"error": ..., "auth": ...}`.</summary>
internal sealed record RefusalBody(string? Error = null, string? Auth = null);
