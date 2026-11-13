using System;
using System.Collections.Generic;
using System.Globalization;
using System.Text.Json;
using System.Text.Json.Serialization.Metadata;

namespace Founderizer.Core;

/// <summary>The decoders of the device routes, with the checks of the Swift decoders: a size cap before the parse, the
/// fields of the record, and the record's own rules (the schema, the generation, unique ids). Each throws a
/// <see cref="HubException"/> of kind InvalidResponse that names the read and the rule.</summary>
public static class HubDecode
{
    public const int SnapshotLimit = 2_000_000;
    public const int ChatLimit = 1_000_000;
    public const int TaskLimit = 2_000_000;
    public const int DevicesLimit = 262_144;
    public const int WaitLimit = 4096;
    public const int KnowledgeLimit = 8 * 1024 * 1024;
    public const int ReceiptLimit = 262_144;

    /// <summary>GET /ui/mobile (MobileSnapshot.decode).</summary>
    public static MobileSnapshot Snapshot(ReadOnlySpan<byte> data)
    {
        const string read = "GET /ui/mobile";
        var s = Parse(data, SnapshotLimit, CoreJson.Default.MobileSnapshot, read);
        Require(s.SchemaVersion == 1, read, "schema_version is not 1");
        Require(s.Db.Length > 0, read, "db is empty");
        Require(double.IsFinite(s.Time), read, "time is not finite");
        Require(Unique(s.Agents, a => a.Name), read, "two agents have one name");
        Require(Unique(s.Needs, n => n.Id), read, "two needs have one id");
        Require(Unique(s.AnsweredNeeds ?? [], n => n.Id), read, "two answered needs have one id");
        Require(Unique(s.Tasks, t => t.Id), read, "two tasks have one id");
        Require(Unique(s.Recent, t => t.Id), read, "two recent tasks have one id");
        foreach (var need in s.Needs) CheckSecret(need, read);
        foreach (var need in s.AnsweredNeeds ?? []) CheckSecret(need, read);
        return s;
    }

    /// <summary>GET /ui/mobile/chat/&lt;agent&gt; (MobileClient.chat): the page of the generation and agent asked for.</summary>
    public static MobileChatPage ChatPage(ReadOnlySpan<byte> data, string database, string agent)
    {
        const string read = "GET /ui/mobile/chat";
        var page = Parse(data, ChatLimit, CoreJson.Default.MobileChatPage, read);
        Require(page.Db == database, read, "the page is of another generation");
        Require(page.Agent == agent, read, "the page is of another agent");
        var items = new List<MobileChatItem>(page.Items.Count);
        foreach (var item in page.Items)
        {
            Require(item.Kind is "message" or "report", read, "an item is neither a message nor a report");
            items.Add(item with { Key = ItemKey(item.RawId, read) });
        }
        return page with { Items = items };
    }

    /// <summary>GET /ui/mobile/task/&lt;id&gt; (MobileClient.task): the task asked for, in the generation asked for.</summary>
    public static MobileTaskPage TaskPage(ReadOnlySpan<byte> data, string database, long id)
    {
        const string read = "GET /ui/mobile/task";
        var page = Parse(data, TaskLimit, CoreJson.Default.MobileTaskPage, read);
        Require(page.Db == database, read, "the page is of another generation");
        Require(page.Task.Id == id, read, "the page is of another task");
        return page;
    }

    /// <summary>GET /ui/owner/devices as a device reads it (MobileClient.devices).</summary>
    public static MobileDeviceList Devices(ReadOnlySpan<byte> data) =>
        Parse(data, DevicesLimit, CoreJson.Default.MobileDeviceList, "GET /ui/owner/devices");

    /// <summary>POST /ui/owner/enroll (MobileClient.enroll): a key and a device name.</summary>
    public static MobileEnrollment Enrollment(ReadOnlySpan<byte> data)
    {
        const string read = "POST /ui/owner/enroll";
        var e = Parse(data, DevicesLimit, CoreJson.Default.MobileEnrollment, read);
        Require(e.Key.Length > 0 && e.Device.Length > 0, read, "no key or no device");
        return e;
    }

    /// <summary>GET /ui/knowledge (KnowledgeClient.file): the file asked for, in the generation asked for.</summary>
    public static KnowledgeFile Knowledge(ReadOnlySpan<byte> data, string database, string path)
    {
        const string read = "GET /ui/knowledge";
        var file = Parse(data, KnowledgeLimit, CoreJson.Default.KnowledgeFile, read);
        Require(file.Db == database && file.Path == path, read, "the file is of another generation or path");
        return file;
    }

    /// <summary>GET /ui/wait (LiveChangesClient.wait): the hub's token now, or <see cref="LiveAnswer.GenerationChanged"/>
    /// for an answer of another generation.</summary>
    public static LiveAnswer Wait(ReadOnlySpan<byte> data, string database)
    {
        const string read = "GET /ui/wait";
        var answer = Parse(data, WaitLimit, CoreJson.Default.WaitAnswer, read);
        if (answer.Db != database) return LiveAnswer.GenerationChanged;
        var token = LiveToken.Parse(answer.Token);
        Require(token is not null, read, "the token is not a token");
        return LiveAnswer.Of(token!);
    }

    /// <summary>The receipt of a message or an answer, which must name the same request.</summary>
    public static SendReceipt Receipt(ReadOnlySpan<byte> data, PendingRequest request)
    {
        var read = "POST /" + request.Route;
        var receipt = Parse(data, ReceiptLimit, CoreJson.Default.SendReceipt, read);
        Require(request.IsConfirmedBy(receipt), read, "the receipt is not of this request");
        return receipt;
    }

    /// <summary>The receipt of an owner command, which must name the same request and say what it did.</summary>
    public static ControlReceipt CommandReceipt(ReadOnlySpan<byte> data, PendingRequest request)
    {
        var read = "POST /" + request.Route;
        var receipt = Parse(data, ReceiptLimit, CoreJson.Default.ControlReceipt, read);
        Require(request.IsConfirmedBy(receipt), read, "the receipt is not of this request");
        return receipt;
    }

    /// <summary>The answer of POST /ui/attachments: the file as the hub keeps it, which must be one an app may ask for.</summary>
    public static MessageAttachment Attachment(ReadOnlySpan<byte> data)
    {
        const string read = "POST /ui/attachments";
        var file = Parse(data, ReceiptLimit, CoreJson.Default.MessageAttachment, read);
        if (!file.IsValid) throw new AttachmentException(AttachmentException.Problem.Metadata);
        return file;
    }

    /// <summary>The key of a chat item that a file of this device kept: a message's request UUID or a report's number.</summary>
    internal static MobileChatItem Keyed(MobileChatItem item) => item with { Key = ItemKey(item.RawId, "a kept chat") };

    /// <summary>The hub's `{"error", "auth"}` of a refusal, or nulls when the body does not read as one.</summary>
    internal static (string? Error, string? Auth) Refusal(ReadOnlySpan<byte> data)
    {
        if (data.Length > 65_536) return (null, null);
        try
        {
            var body = JsonSerializer.Deserialize(data, CoreJson.Default.RefusalBody);
            return (body?.Error, body?.Auth);
        }
        catch (JsonException) { return (null, null); }
    }

    private static T Parse<T>(ReadOnlySpan<byte> data, int limit, JsonTypeInfo<T> type, string read) where T : class
    {
        Require(data.Length <= limit, read, $"the answer is larger than {limit} bytes");
        try
        {
            return JsonSerializer.Deserialize(data, type) ?? throw HubException.InvalidResponse(read, "the answer is null");
        }
        catch (JsonException e)
        {
            throw HubException.InvalidResponse(read, e.Message, e);
        }
    }

    /// <summary>A message is known by its request UUID, a report by its number (MobileChatItem.init(from:)).</summary>
    private static string ItemKey(JsonElement id, string read)
    {
        if (id.ValueKind == JsonValueKind.Number)
        {
            if (id.TryGetInt64(out var whole)) return whole.ToString(CultureInfo.InvariantCulture);
            if (id.TryGetDouble(out var number) && number == Math.Floor(number) && Math.Abs(number) < 9.2e18)
                return ((long)number).ToString(CultureInfo.InvariantCulture);
        }
        if (id.ValueKind == JsonValueKind.String) return id.GetString()!;
        throw HubException.InvalidResponse(read, "an item's id is neither a number nor a text");
    }

    private static void CheckSecret(OwnerNeed need, string read) =>
        Require(need.RawSecret is null || need.RawSecret.Value.ValueKind is JsonValueKind.Object or JsonValueKind.Null,
                read, "a need's secret is not an object");

    private static bool Unique<T, TKey>(IReadOnlyList<T> items, Func<T, TKey> key) where TKey : notnull
    {
        var seen = new HashSet<TKey>();
        foreach (var item in items) if (!seen.Add(key(item))) return false;
        return true;
    }

    private static void Require(bool holds, string read, string why)
    {
        if (!holds) throw HubException.InvalidResponse(read, why);
    }
}
