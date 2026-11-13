using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.Json;

namespace Founderizer.Core;

/// <summary>What the owner does to a task from a device: its control (pause, stop, resume) and its guidance.</summary>
public enum TaskControl { Pause, Stop, Resume, ResumeCheck }

/// <summary>The owner commands that a device may send (hub.py DEVICE_PATHS: POST /ui/tasks and POST /ui/needs), as
/// FleetCore's OwnerCommand writes them.</summary>
public sealed record OwnerCommand
{
    public string Kind { get; }
    public long Target { get; }
    public long Attempt { get; }
    public TaskControl Action { get; }

    private OwnerCommand(string kind, long target, long attempt = 0, TaskControl control = TaskControl.Pause)
    {
        Kind = kind;
        Target = target;
        Attempt = attempt;
        Action = control;
    }

    /// <summary>Guidance for one attempt of a task: POST /ui/tasks/&lt;id&gt;/steer.</summary>
    public static OwnerCommand Steer(long task, long attempt) => new("steer", task, attempt);
    /// <summary>Pause, stop or resume a task: POST /ui/tasks/&lt;id&gt;/control.</summary>
    public static OwnerCommand Control(long task, TaskControl action) => new("control", task, control: action);
    public string Route => Kind == "steer" ? $"ui/tasks/{Target}/steer" : $"ui/tasks/{Target}/control";

    /// <summary>The hub feature that this command needs.</summary>
    public string RequiredFeature => Kind == "steer" ? "task_steering" : "task_controls";

    public string ActionName => Action switch
    {
        Core.TaskControl.Pause => "pause",
        Core.TaskControl.Stop => "stop",
        Core.TaskControl.Resume => "resume",
        _ => "resume_check",
    };

    internal static OwnerCommand? FromRecord(string? kind, long target, long attempt, string? action) => kind switch
    {
        null => null,
        "steer" => Steer(target, attempt),
        "control" => Control(target, action switch
        {
            "pause" => Core.TaskControl.Pause,
            "stop" => Core.TaskControl.Stop,
            "resume" => Core.TaskControl.Resume,
            "resume_check" => Core.TaskControl.ResumeCheck,
            _ => throw new OutboxException(OutboxException.Problem.InvalidRecord),
        }),
        _ => throw new OutboxException(OutboxException.Problem.InvalidRecord),
    };
}

/// <summary>One owner write, written to the outbox before it goes and kept until its receipt (FleetCore's
/// PendingRequest). Its request id makes a repeat the same request on the hub.</summary>
public sealed record PendingRequest
{

    public Guid RequestId { get; init; }
    public Uri Hub { get; init; } = null!;
    public string Database { get; init; } = "";
    public long? NeedId { get; init; }
    /// <summary>An option of the item pressed: its 0-based index. `choice` and `answer` are exclusive.</summary>
    public long? Choice { get; init; }
    /// <summary>The options ticked on an item whose options combine, in order.</summary>
    public IReadOnlyList<long>? Choices { get; init; }
    public string? Recipient { get; init; }
    public OwnerCommand? Command { get; init; }
    public string? ReplacesRequestId { get; init; }
    /// <summary>The files that the hub already holds and that this message carries.</summary>
    public IReadOnlyList<long> Attachments { get; init; } = [];
    /// <summary>The owner's signed yes to a door call, beside an answer (owner feature `door_calls`).</summary>
    public string? Statement { get; init; }
    public string? Signature { get; init; }
    public string Text { get; init; } = "";
    public DateTimeOffset CreatedAt { get; init; }
    public string Client { get; init; } = "";
    public string? Refusal { get; init; }

    /// <summary>A new request, as the Swift initializer makes one.</summary>
    public static PendingRequest New(Uri hub, string database, string client, string text, long? needId = null,
                                     long? choice = null, IEnumerable<long>? choices = null, string? recipient = null,
                                     string? replacesRequestId = null, OwnerCommand? command = null,
                                     IEnumerable<long>? attachments = null, string? statement = null,
                                     string? signature = null) =>
        new()
        {
            RequestId = Guid.NewGuid(),
            Hub = hub,
            Database = database,
            Client = client,
            NeedId = needId,
            Choice = needId is null ? null : choice,
            Choices = needId is null || choice is not null || choices is null
                ? null : choices.Distinct().Order().ToArray(),
            Recipient = recipient,
            Command = command,
            ReplacesRequestId = replacesRequestId,
            Attachments = attachments?.ToArray() ?? [],
            Statement = needId is null || signature is null ? null : statement,
            Signature = needId is null || statement is null ? null : signature,
            Text = text,
            CreatedAt = DateTimeOffset.UtcNow,
        };

    public string RequestIdText => RequestId.ToString("D");

    public string Route => Command?.Route ?? (NeedId is { } need ? $"ui/needs/{need}" : "ui/messages");

    /// <summary>The body that goes, with its keys sorted as the Mac's: `request_id` and `db`, then the request's own.</summary>
    public byte[] Body()
    {
        var fields = new SortedDictionary<string, object>(StringComparer.Ordinal)
        {
            ["request_id"] = RequestIdText,
            ["db"] = Database,
        };
        if (Command is { } command)
        {
            switch (command.Kind)
            {
                case "steer":
                    var steer = NormalizedOwnerText(Text);
                    if (command.Target <= 0 || command.Attempt <= 0 || steer.Length == 0 || steer.Length > 4000)
                        throw new OutboxException(OutboxException.Problem.InvalidRecord);
                    fields["text"] = steer;
                    fields["expected_attempt"] = command.Attempt;
                    break;
                default:
                    fields["action"] = command.ActionName;
                    fields["note"] = Text;
                    break;
            }
            return Write(fields);
        }
        if (Choice is { } choice && NeedId is not null) fields["choice"] = choice;
        else if (Choices is { } choices && NeedId is not null) fields["choices"] = choices;
        else fields[NeedId is null ? "text" : "answer"] = Text;
        if (Recipient is not null) fields["recipient"] = Recipient;
        if (ReplacesRequestId is not null) fields["replaces_request_id"] = ReplacesRequestId;
        if (Attachments.Count > 0) fields["attachments"] = Attachments;
        if (Statement is not null && Signature is not null && NeedId is not null)
        {
            fields["statement"] = Statement;
            fields["signature"] = Signature;
        }
        return Write(fields);
    }

    /// <summary>The receipt names this request: the same id and client, recipient, correction and files.</summary>
    public bool IsConfirmedBy(SendReceipt receipt) =>
        receipt.Ok && string.Equals(receipt.RequestId, RequestIdText, StringComparison.OrdinalIgnoreCase) &&
        receipt.Client == Client &&
        (NeedId is not null || (receipt.Recipient ?? "manager") == (Recipient ?? "manager")) &&
        receipt.ReplacesRequestId == ReplacesRequestId &&
        (receipt.Attachments ?? []).SequenceEqual(Attachments);

    /// <summary>The receipt of a command names this request and says that it did what was asked
    /// (ControlReceipt.matches).</summary>
    public bool IsConfirmedBy(ControlReceipt receipt)
    {
        if (!receipt.Ok || receipt.RequestId.ToLowerInvariant() != RequestIdText || receipt.Client != Client ||
            Command is not { } command)
            return false;
        switch (command.Kind)
        {
            case "steer":
                return receipt.Steer is { } steer && steer.IsValid && steer.Task == command.Target &&
                       steer.Attempt == command.Attempt && steer.Client == Client &&
                       steer.RequestId.ToLowerInvariant() == RequestIdText && steer.Text == NormalizedOwnerText(Text);
            default:
                if (receipt.Hold is not { } hold || hold.Task != command.Target || hold.Id <= 0) return false;
                if (command.Action is Core.TaskControl.Resume or Core.TaskControl.ResumeCheck)
                    return hold.State == "released";
                return (hold.Kind == command.ActionName || hold.Kind == "stop" || receipt.ChangedFlag == false) &&
                       hold.State is "requested" or "stopped" or "not_confirmed";
        }
    }

    /// <summary>The owner's text as the hub keeps it: CRLF as LF, without white space at the ends.</summary>
    public static string NormalizedOwnerText(string text) => text.Replace("\r\n", "\n").Trim();

    /// <summary>The same request, as the outbox compares two (Outbox.save): every field that goes.</summary>
    internal bool SameRequest(PendingRequest other) =>
        RequestId == other.RequestId && Hub == other.Hub && Database == other.Database && NeedId == other.NeedId &&
        Choice == other.Choice && Command == other.Command && Recipient == other.Recipient &&
        ReplacesRequestId == other.ReplacesRequestId && Attachments.SequenceEqual(other.Attachments) &&
        Statement == other.Statement && Signature == other.Signature && Text == other.Text && Client == other.Client;

    private static byte[] Write(SortedDictionary<string, object> fields)
    {
        using var stream = new MemoryStream();
        using (var json = new Utf8JsonWriter(stream))
        {
            json.WriteStartObject();
            foreach (var (key, value) in fields)
            {
                json.WritePropertyName(key);
                switch (value)
                {
                    case string text: json.WriteStringValue(text); break;
                    case long number: json.WriteNumberValue(number); break;
                    case IEnumerable<long> numbers:
                        json.WriteStartArray();
                        foreach (var n in numbers) json.WriteNumberValue(n);
                        json.WriteEndArray();
                        break;
                }
            }
            json.WriteEndObject();
        }
        return stream.ToArray();
    }

    internal PendingRequestRecord ToRecord() => new(
        RequestIdText, Hub.ToString(), Database, NeedId, Choice, Choices, Recipient, Command?.Kind, Command?.Target ?? 0,
        Command?.Attempt ?? 0, Command is { Kind: "control" } c ? c.ActionName : null, ReplacesRequestId, Attachments,
        Statement, Signature, Text, CreatedAt.ToUnixTimeMilliseconds() / 1000.0, Client, Refusal);

    internal static PendingRequest FromRecord(PendingRequestRecord r)
    {
        if (!Guid.TryParseExact(r.RequestId, "D", out var id) || !Uri.TryCreate(r.Hub, UriKind.Absolute, out var hub))
            throw new OutboxException(OutboxException.Problem.InvalidRecord);
        return new PendingRequest
        {
            RequestId = id,
            Hub = hub,
            Database = r.Database,
            NeedId = r.NeedId,
            Choice = r.Choice,
            Choices = r.Choices,
            Recipient = r.Recipient,
            Command = OwnerCommand.FromRecord(r.Command, r.CommandTarget, r.CommandAttempt, r.CommandAction),
            ReplacesRequestId = r.ReplacesRequestId,
            Attachments = r.Attachments ?? [],
            Statement = r.Statement,
            Signature = r.Signature,
            Text = r.Text,
            CreatedAt = DateTimeOffset.FromUnixTimeMilliseconds((long)Math.Round(r.CreatedAt * 1000)),
            Client = r.Client,
            Refusal = r.Refusal,
        };
    }
}

/// <summary>A pending request as the outbox file keeps it. The Windows app's own format: no Swift app reads it.</summary>
internal sealed record PendingRequestRecord(
    string RequestId,
    string Hub,
    string Database,
    long? NeedId,
    long? Choice,
    IReadOnlyList<long>? Choices,
    string? Recipient,
    string? Command,
    long CommandTarget,
    long CommandAttempt,
    string? CommandAction,
    string? ReplacesRequestId,
    IReadOnlyList<long>? Attachments,
    string? Statement,
    string? Signature,
    string Text,
    double CreatedAt,
    string Client,
    string? Refusal = null);

/// <summary>Why the outbox refused (FleetCore's OutboxError).</summary>
public sealed class OutboxException(OutboxException.Problem problem) : Exception(problem switch
{
    Problem.PendingRequest => "Another saved request is waiting for a receipt.",
    _ => "The saved request cannot be read. Sending is blocked to prevent a duplicate.",
})
{
    public enum Problem { PendingRequest, InvalidRecord }
    public Problem Kind { get; } = problem;
}

/// <summary>One saved request at a time, in one file, until its receipt (FleetCore's Outbox). A second request waits until
/// the first is confirmed or cleared, so no write goes twice and none is lost across a restart.</summary>
public sealed class Outbox(string file)
{
    public const int RecordLimit = 262_144;
    public const int BodyLimit = 65_536;
    public string File { get; } = file;

    /// <summary>The command kind of an outbox record that no write makes any more and that is dropped when it is read.</summary>
    internal const string DroppedKind = "need_talk";

    public PendingRequest? Load()
    {
        if (!System.IO.File.Exists(File)) return null;
        var data = System.IO.File.ReadAllBytes(File);
        if (data.Length > RecordLimit) throw new OutboxException(OutboxException.Problem.InvalidRecord);
        try
        {
            var record = JsonSerializer.Deserialize(data, CoreJson.Default.PendingRequestRecord)
                         ?? throw new OutboxException(OutboxException.Problem.InvalidRecord);
            if (record.Command == DroppedKind)
            {
                // A question about a request that a build before Discuss left the product saved (owner API 1.158): its
                // route answers 404 now, so it is dropped here, with no word to the owner, and never goes again.
                System.IO.File.Delete(File);
                return null;
            }
            return PendingRequest.FromRecord(record);
        }
        catch (JsonException)
        {
            throw new OutboxException(OutboxException.Problem.InvalidRecord);
        }
    }

    /// <summary>Keeps the request. The same request again is kept again; another one is refused while one waits.</summary>
    public void Save(PendingRequest request)
    {
        var encoded = JsonSerializer.SerializeToUtf8Bytes(request.ToRecord(), CoreJson.Default.PendingRequestRecord);
        if (encoded.Length > RecordLimit || request.Body().Length > BodyLimit)
            throw new OutboxException(OutboxException.Problem.InvalidRecord);
        if (Load() is { } existing && !existing.SameRequest(request))
            throw new OutboxException(OutboxException.Problem.PendingRequest);
        Write(encoded);
    }

    /// <summary>Removes the saved request once its receipt came. Another request is not this one's to remove.</summary>
    public void Clear(Guid requestId)
    {
        if (Load() is not { } request) return;
        if (request.RequestId != requestId) throw new OutboxException(OutboxException.Problem.PendingRequest);
        System.IO.File.Delete(File);
    }

    /// <summary>The hub refused the text because it holds a registered login (422): the saved text goes, and the request
    /// stays as a refusal for the owner to see. <paramref name="clearDrafts"/> removes the app's drafts, because the hub
    /// does not say which part was the secret.</summary>
    public PendingRequest RejectSecret(Guid requestId, Action clearDrafts)
    {
        clearDrafts();
        if (Load() is not { } request || request.RequestId != requestId)
            throw new OutboxException(OutboxException.Problem.InvalidRecord);
        var refused = request with
        {
            Text = "",
            Refusal = "The hub refused registered login text (422). Saved text and drafts were removed.",
        };
        try
        {
            Write(JsonSerializer.SerializeToUtf8Bytes(refused.ToRecord(), CoreJson.Default.PendingRequestRecord));
        }
        catch (IOException)
        {
            System.IO.File.Delete(File);    // the refusal is definitive: deleting this record cannot replay work
        }
        return refused;
    }

    private void Write(byte[] data)
    {
        var folder = Path.GetDirectoryName(Path.GetFullPath(File))!;
        if (OperatingSystem.IsWindows()) Directory.CreateDirectory(folder);
        else Directory.CreateDirectory(folder, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
        var temporary = File + ".new";
        var options = new FileStreamOptions { Mode = FileMode.Create, Access = FileAccess.Write };
        if (!OperatingSystem.IsWindows()) options.UnixCreateMode = UnixFileMode.UserRead | UnixFileMode.UserWrite;
        using (var stream = new FileStream(temporary, options))
        {
            stream.Write(data);
            stream.Flush(flushToDisk: true);
        }
        System.IO.File.Move(temporary, File, overwrite: true);
    }
}
