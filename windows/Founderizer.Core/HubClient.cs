using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization.Metadata;
using System.Threading;
using System.Threading.Tasks;

namespace Founderizer.Core;

/// <summary>The settings of one <see cref="HubClient"/>: the timeouts of the Mac's sessions (HubClient.swift,
/// LiveChanges.swift, Knowledge.swift), and how long a connection may take.</summary>
public sealed record HubClientOptions
{
    /// <summary>A read or a write, from the request to the last byte (the Mac: 15 seconds a resource).</summary>
    public TimeSpan RequestTimeout { get; init; } = TimeSpan.FromSeconds(15);
    /// <summary>The wait of GET /ui/wait, which the hub holds open for up to 20 seconds (the Mac: 40).</summary>
    public TimeSpan WaitTimeout { get; init; } = TimeSpan.FromSeconds(40);
    /// <summary>One knowledge file with its text (the Mac: 90).</summary>
    public TimeSpan KnowledgeTimeout { get; init; } = TimeSpan.FromSeconds(90);
    /// <summary>Opening the connection (the Mac: 10 seconds without a byte).</summary>
    public TimeSpan ConnectTimeout { get; init; } = TimeSpan.FromSeconds(10);
}

/// <summary>Who calls the owner's API, and where (windows-app-plan-v2.md, section 6): the hub, the key of this PC's role
/// for it, the generation that the PC holds, and the client's label of each write. <see cref="OwnerStore.Call"/> gives it.
/// Its text (<see cref="ToString"/>) never holds the key, so a line that names a call writes no key.</summary>
public sealed record OwnerCall(Uri Hub, string? Key, string Database, string Client)
{
    public override string ToString() =>
        $"OwnerCall {{ Hub = {Hub}, Key = {(Key is null ? "none" : "(held)")}, Database = {Database}, Client = {Client} }}";
}

/// <summary>What the hub keeps of the owner's computer (owner API 1.273, owner_computer): its kind ("mac" or "windows"),
/// the label of its words ("Mac" or "PC"), and the names of what its app can do, in the order of the hub's table.</summary>
public sealed record OwnerComputer(string Kind, string Label, IReadOnlyList<string> Can);

/// <summary>What an owner read or write gave: its answer, or that the hub's generation changed (a 409 whose code is
/// hub_changed or hub_changed_sending), which a caller meets by reading the fleet again
/// (<see cref="OwnerStore.RefreshAsync"/>) before it asks once more.</summary>
public sealed record OwnerAnswer<T>(T? Value) where T : class
{
    public bool IsGenerationChanged => Value is null;
    public static OwnerAnswer<T> GenerationChanged { get; } = new((T?)null);
}

/// <summary>What GET /ui/mobile gave: the snapshot, its ETag, and the bytes as the hub sent them, for the next start.</summary>
public sealed record SnapshotReading(MobileSnapshot Snapshot, string? ETag, byte[] Body);

/// <summary>Everything that the Windows app sends to the hub, on the routes that an owner device reaches (hub.py
/// DEVICE_PATHS): the iPhone's MobileClient, with the Mac's hardening. No redirect (the hub is one address inside the
/// private network, and a redirect would take the key somewhere else), no cookie, no stored credential, no proxy (the
/// bearer key goes to the hub and to nothing between), gzip and no other encoding, and the device's key as a bearer
/// token on every call once it has one. Each answer is read with a size cap and decoded by <see cref="HubDecode"/>.</summary>
public sealed partial class HubClient : IDisposable
{
    private readonly HttpClient http;
    private readonly HubClientOptions options;

    public HubClient(HubClientOptions? options = null) : this(NewHandler(options ?? new HubClientOptions()), options) { }

    internal HubClient(HttpMessageHandler handler, HubClientOptions? options = null)
    {
        this.options = options ?? new HubClientOptions();
        http = new HttpClient(handler, disposeHandler: true) { Timeout = Timeout.InfiniteTimeSpan };
    }

    /// <summary>The handler of every client: what the Mac's ephemeral session with NoRedirects does.</summary>
    internal static SocketsHttpHandler NewHandler(HubClientOptions options) => new()
    {
        AllowAutoRedirect = false,
        AutomaticDecompression = DecompressionMethods.GZip,
        UseCookies = false,
        UseProxy = false,
        Credentials = null,
        PreAuthenticate = false,
        ConnectTimeout = options.ConnectTimeout,
        PooledConnectionIdleTimeout = TimeSpan.FromSeconds(60),
        MaxResponseHeadersLength = 64,
    };

    public void Dispose() => http.Dispose();

    /// <summary>A hub address as the owner typed it: HTTP or HTTPS, a host, and no login, path, query or fragment. The
    /// address that comes back ends in "/", so a route is appended to it.</summary>
    public static Uri Address(string text)
    {
        if (!Uri.TryCreate(text.Trim(), UriKind.Absolute, out var uri) || uri.Scheme is not ("http" or "https") ||
            uri.Host.Length == 0 || uri.UserInfo.Length > 0 || uri.Query.Length > 0 || uri.Fragment.Length > 0 ||
            uri.AbsolutePath != "/" || text.Trim().Contains('?') || text.Trim().Contains('#'))
            throw HubException.InvalidAddress();
        return new Uri(uri.GetLeftPart(UriPartial.Authority) + "/");
    }

    // ---------------------------------------------------------------- the reads

    /// <summary>The header of a read of the state that says what this build draws (owner API 1.285): the hub takes such a
    /// thing on an item only while each app of the owner's said it, and a device's read with no such header takes that
    /// device's word back.</summary>
    public const string DrawsHeader = "X-Fleet-Draws";

    /// <summary>What this build draws, by the hub's names (hub.py APP_DRAWS): pictures as the options of a request
    /// (<see cref="NeedPictures"/>). A name goes in only with the build that draws it.</summary>
    public static readonly IReadOnlyList<string> Draws = [NeedPictures.Feature];

    /// <summary>GET /ui/mobile, with the generation that the device holds and the ETag of its last body. Null when the
    /// hub answers 304: the fleet did not change and the device keeps what it has. A hub without the route answers 404,
    /// which is <see cref="HubErrorKind.NoPhoneRoutes"/>. It is this app's one read of the state, as a device and as the
    /// owner's computer, so it says what this build draws (<see cref="DrawsHeader"/>) each time; a hub before owner API
    /// 1.285 ignores the header.</summary>
    public async Task<SnapshotReading?> SnapshotAsync(Uri hub, string? key, string? database, string? etag,
                                                      CancellationToken cancel = default)
    {
        using var request = Request(HttpMethod.Get, hub, "ui/mobile", key, database is null ? [] : [("db", database)]);
        if (etag is not null) request.Headers.TryAddWithoutValidation("If-None-Match", etag);
        request.Headers.TryAddWithoutValidation(DrawsHeader, string.Join(",", Draws));
        Answer answer;
        try
        {
            answer = await SendAsync(request, HubDecode.SnapshotLimit, options.RequestTimeout, cancel, allow304: true);
        }
        catch (HubException e) when (e is { Kind: HubErrorKind.Refusal, Status: 404 })
        {
            throw HubException.NoPhoneRoutes();
        }
        if (answer.Status == 304) return null;
        return new SnapshotReading(HubDecode.Snapshot(answer.Body), answer.ETag, answer.Body);
    }

    /// <summary>GET /ui/mobile/chat/&lt;agent&gt;: the last page, or with <paramref name="since"/> the page after it.</summary>
    public async Task<MobileChatPage> ChatAsync(Uri hub, string? key, string database, string agent, double? since = null,
                                                CancellationToken cancel = default)
    {
        if (!Patterns.AgentName().IsMatch(agent))
            throw HubException.InvalidResponse("GET /ui/mobile/chat", "not an agent's name");
        var query = new List<(string, string)> { ("db", database) };
        if (since is { } cursor) query.Add(("since", cursor.ToString("R", CultureInfo.InvariantCulture)));
        using var request = Request(HttpMethod.Get, hub, $"ui/mobile/chat/{agent}", key, query);
        var answer = await SendAsync(request, HubDecode.ChatLimit, options.RequestTimeout, cancel);
        return HubDecode.ChatPage(answer.Body, database, agent);
    }

    /// <summary>GET /ui/mobile/task/&lt;id&gt;: the task itself and its notes after <paramref name="since"/>.</summary>
    public async Task<MobileTaskPage> TaskAsync(Uri hub, string? key, string database, long id, long since = 0,
                                                CancellationToken cancel = default)
    {
        if (id <= 0 || since < 0) throw HubException.InvalidResponse("GET /ui/mobile/task", "not a task and a cursor");
        using var request = Request(HttpMethod.Get, hub, $"ui/mobile/task/{id}", key,
                                    [("db", database), ("since", since.ToString(CultureInfo.InvariantCulture))]);
        var answer = await SendAsync(request, HubDecode.TaskLimit, options.RequestTimeout, cancel);
        return HubDecode.TaskPage(answer.Body, database, id);
    }

    /// <summary>The largest answer of GET /ui/mobile/ended: about 70,000 ended heads (483 bytes each at a hub of 586).</summary>
    public const int EndedLimit = 32 * 1024 * 1024;

    /// <summary>GET /ui/mobile/ended (owner API 1.166): the head of every ended task, with its schedule, and the mark of
    /// GET /ui/mobile that it is of. Held to its rules: this generation, ended states only, each id once, by id.</summary>
    public Task<EndedReading> EndedAsync(Uri hub, string? key, string database, CancellationToken cancel = default) =>
        EndedReadAsync(hub, key, database, [("db", database)], "GET /ui/mobile/ended", cancel);

    /// <summary>GET /ui/mobile/ended?window=1 (owner API 1.270): the heads of the ended tasks at or above
    /// `older.before`, and `older`. A hub that does not serve the window gives every head and no `older`. Held to the
    /// rules of the whole read, with each head at or above `older.before`.</summary>
    public async Task<EndedReading> EndedWindowAsync(Uri hub, string? key, string database, CancellationToken cancel = default)
    {
        const string read = "GET /ui/mobile/ended?window";
        var reading = await EndedReadAsync(hub, key, database, [("db", database), ("window", "1")], read, cancel);
        if (reading.Older is { } older && (!older.IsValid || reading.Tasks.Any(t => t.Id < older.Before)))
            throw HubException.InvalidResponse(read, "the answer breaks its rules");
        return reading;
    }

    private async Task<EndedReading> EndedReadAsync(Uri hub, string? key, string database,
                                                    IReadOnlyList<(string Name, string Value)> query, string read,
                                                    CancellationToken cancel)
    {
        using var request = Request(HttpMethod.Get, hub, "ui/mobile/ended", key, query);
        var answer = await SendAsync(request, EndedLimit, options.RequestTimeout, cancel);
        var reading = Decoded(answer.Body, CoreJson.Default.EndedReading, read);
        if (reading.Db != database || reading.Mark.Length == 0 || !AreEndedHeads(reading.Tasks))
            throw HubException.InvalidResponse(read, "the answer breaks its rules");
        return reading;
    }

    /// <summary>GET /ui/mobile/ended?blocks=1 (owner API 1.270): the blocks below the window, each with its mark. Held to
    /// its rules: this generation, and each block once, below `before`, at a multiple of `block`.</summary>
    public async Task<EndedBlockList> EndedBlocksAsync(Uri hub, string? key, string database, CancellationToken cancel = default)
    {
        const string read = "GET /ui/mobile/ended?blocks";
        using var request = Request(HttpMethod.Get, hub, "ui/mobile/ended", key, [("db", database), ("blocks", "1")]);
        var answer = await SendAsync(request, EndedLimit, options.RequestTimeout, cancel);
        var list = Decoded(answer.Body, CoreJson.Default.EndedBlockList, read);
        var starts = list.Blocks.Select(b => b.From).ToList();
        if (list.Db != database || !list.Head.IsValid || starts.Distinct().Count() != starts.Count ||
            list.Blocks.Any(b => b.From < 0 || b.From >= list.Before || b.From % list.Block != 0 || b.Mark.Length == 0 || b.Tasks < 0))
            throw HubException.InvalidResponse(read, "the answer breaks its rules");
        return list;
    }

    /// <summary>GET /ui/mobile/ended?block=&lt;from&gt; (owner API 1.270): the heads of the block of <paramref name="size"/>
    /// ids from <paramref name="from"/>. Held to its rules: this generation and block, ended states only, each id once,
    /// by id, inside the block.</summary>
    public async Task<EndedBlock> EndedBlockAsync(Uri hub, string? key, string database, long from, long size,
                                                  CancellationToken cancel = default)
    {
        const string read = "GET /ui/mobile/ended?block";
        if (from < 0 || size <= 0 || from % size != 0) throw HubException.InvalidResponse(read, "not the first id of a block");
        using var request = Request(HttpMethod.Get, hub, "ui/mobile/ended", key,
                                    [("db", database), ("block", from.ToString(CultureInfo.InvariantCulture))]);
        var answer = await SendAsync(request, EndedLimit, options.RequestTimeout, cancel);
        var block = Decoded(answer.Body, CoreJson.Default.EndedBlock, read);
        if (block.Db != database || block.From != from || block.Mark.Length == 0 || !AreEndedHeads(block.Tasks) ||
            block.Tasks.Any(t => t.Id < from || t.Id >= from + size))
            throw HubException.InvalidResponse(read, "the answer breaks its rules");
        return block;
    }

    /// <summary>Heads as an ended read gives them: ended states only, each id once, by id.</summary>
    internal static bool AreEndedHeads(IReadOnlyList<MobileTaskHead> tasks)
    {
        for (var i = 0; i < tasks.Count; i++)
            if (!tasks[i].IsTerminal || i > 0 && tasks[i].Id <= tasks[i - 1].Id) return false;
        return true;
    }

    private static T Decoded<T>(byte[] body, System.Text.Json.Serialization.Metadata.JsonTypeInfo<T> type, string read)
        where T : class
    {
        try
        {
            return JsonSerializer.Deserialize(body, type) ?? throw HubException.InvalidResponse(read, "no answer");
        }
        catch (JsonException e)
        {
            throw HubException.InvalidResponse(read, e.Message, e);
        }
    }

    /// <summary>GET /ui/owner/devices: the owner's devices, so that Settings can name this one.</summary>
    public async Task<MobileDeviceList> DevicesAsync(Uri hub, string? key, string database,
                                                     CancellationToken cancel = default)
    {
        using var request = Request(HttpMethod.Get, hub, "ui/owner/devices", key, [("db", database)]);
        var answer = await SendAsync(request, HubDecode.DevicesLimit, options.RequestTimeout, cancel);
        return HubDecode.Devices(answer.Body);
    }

    /// <summary>GET /ui/knowledge: one owner knowledge file with its text.</summary>
    public async Task<KnowledgeFile> KnowledgeAsync(Uri hub, string? key, string database, string path,
                                                    CancellationToken cancel = default)
    {
        using var request = Request(HttpMethod.Get, hub, "ui/knowledge", key, [("db", database), ("path", path)]);
        var answer = await SendAsync(request, HubDecode.KnowledgeLimit, options.KnowledgeTimeout, cancel);
        return HubDecode.Knowledge(answer.Body, database, path);
    }

    /// <summary>GET /ui/wait: it comes back when the hub's boot or state count is past <paramref name="since"/>, or after
    /// <paramref name="seconds"/> (at most 20). A generation that changed answers 409, as every `?db=` read does, and so
    /// does an answer of another generation: both are <see cref="LiveAnswer.GenerationChanged"/>.</summary>
    public async Task<LiveAnswer> WaitAsync(Uri hub, string? key, string database, LiveToken since,
                                            int seconds = LiveChanges.Wait, CancellationToken cancel = default)
    {
        var wait = Math.Min(Math.Max(seconds, 0), LiveChanges.Wait).ToString(CultureInfo.InvariantCulture);
        using var request = Request(HttpMethod.Get, hub, "ui/wait", key,
                                    [("db", database), ("since", since.Text), ("wait", wait)]);
        try
        {
            var answer = await SendAsync(request, HubDecode.WaitLimit, options.WaitTimeout, cancel);
            return HubDecode.Wait(answer.Body, database);
        }
        catch (HubException e) when (e is { Kind: HubErrorKind.Refusal, Status: 409 })
        {
            return LiveAnswer.GenerationChanged;
        }
    }

    /// <summary>Whether a hub answers its GET /health at <paramref name="hub"/> with 200, in
    /// <see cref="Tailnet.HealthTimeout"/> (the Mac's FleetOnTailscale.answersHealth). It sends no key: a hub that a
    /// search finds is not one that this PC has a key for yet.</summary>
    public async Task<bool> AnswersHealthAsync(Uri hub, CancellationToken cancel = default)
    {
        using var request = Request(HttpMethod.Get, hub, "health", key: null, []);
        try
        {
            await SendAsync(request, 65_536, Tailnet.HealthTimeout, cancel);
            return true;
        }
        catch (HubException)
        {
            return false;
        }
    }

    // ---------------------------------------------------------------- enrollment

    /// <summary>The eight characters of a code from what the owner typed, or null. The alphabet leaves out the letters
    /// and digits that look alike, so a code holds no I, O, 0 or 1.</summary>
    public static string? NormalizedCode(string typed)
    {
        const string alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
        var code = new StringBuilder();
        foreach (var c in typed.ToUpperInvariant())
            if (!char.IsWhiteSpace(c) && c != '-') code.Append(c);
        if (code.Length != 8) return null;
        foreach (var c in code.ToString()) if (!alphabet.Contains(c)) return null;
        return code.ToString();
    }

    /// <summary>The kind of app that this library is, which an enrollment names (owner API 1.149): the hub calls a new
    /// device of this kind "PC", and its messages say via=Windows. The iPhone sends no kind, which is "iphone".</summary>
    public const string DeviceKind = "windows";

    /// <summary>POST /ui/owner/enroll, from this device's own address and before it has a key, so it carries no bearer
    /// token and no request number, and with this app's kind (<see cref="DeviceKind"/>). The hub gives the key once and
    /// never again. <paramref name="signing"/> and <paramref name="recovery"/> are the device's own keys with their
    /// bindings to the QR's one-time value.</summary>
    public async Task<MobileEnrollment> EnrollAsync(Uri hub, string code, (string Key, string Binding)? signing = null,
                                                    (string Key, string Binding)? recovery = null,
                                                    CancellationToken cancel = default)
    {
        if (NormalizedCode(code) is not { } normalized)
            throw HubException.InvalidResponse("POST /ui/owner/enroll", "not a code");
        var fields = new SortedDictionary<string, string>(StringComparer.Ordinal) { ["code"] = normalized, ["kind"] = DeviceKind };
        if (signing is { } s)
        {
            fields["signing_key"] = s.Key;
            fields["binding"] = s.Binding;
            if (recovery is { } r && r.Key != s.Key)
            {
                fields["recovery_key"] = r.Key;
                fields["recovery_binding"] = r.Binding;
            }
        }
        using var request = Request(HttpMethod.Post, hub, "ui/owner/enroll", key: null, []);
        request.Content = Json(fields);
        var answer = await SendAsync(request, HubDecode.DevicesLimit, options.RequestTimeout, cancel);
        return HubDecode.Enrollment(answer.Body);
    }

    // ---------------------------------------------------------------- the claim of a new hub

    /// <summary>How long the claim may take (the Mac's sendClaim: 30 seconds).</summary>
    public static readonly TimeSpan ClaimTimeout = TimeSpan.FromSeconds(30);

    /// <summary>POST /claim to the claim's listener of a new hub (hubsetup.py ClaimHandler): the code as text, and the
    /// SHA-256 of the key of the owner's computer in <see cref="OwnerPcKey.ClaimHeader"/> when there is one. The
    /// listener answers in plain text, so its status, its <see cref="OwnerPcKey.ClaimKept"/> header and its first 300
    /// bytes come back as they are. <see cref="OwnerPcKey.ClaimAsync"/> checks the address before it calls this.</summary>
    public async Task<ClaimAnswer> ClaimAsync(Uri claim, string code, string? keySha256, CancellationToken cancel = default)
    {
        using var request = new HttpRequestMessage(HttpMethod.Post, claim);
        request.Content = new ByteArrayContent(Encoding.UTF8.GetBytes(code.Trim()));
        request.Content.Headers.ContentType = new MediaTypeHeaderValue("text/plain");
        if (keySha256 is not null) request.Headers.TryAddWithoutValidation(OwnerPcKey.ClaimHeader, keySha256);
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancel);
        deadline.CancelAfter(ClaimTimeout);
        try
        {
            using var response = await http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, deadline.Token);
            var body = await ReadAsync(response.Content, 65_536, deadline.Token) ?? [];
            var said = Encoding.UTF8.GetString(body, 0, Math.Min(body.Length, 300)).Trim();
            var kept = response.Headers.TryGetValues(OwnerPcKey.ClaimKept, out var values) && values.Any(v => v.Trim() == "kept");
            return new ClaimAnswer((int)response.StatusCode, kept, said);
        }
        catch (OperationCanceledException) when (!cancel.IsCancellationRequested)
        {
            throw HubException.NoAnswer();
        }
        catch (HttpRequestException e)
        {
            throw HubException.NoAnswer(e);
        }
        catch (IOException e)
        {
            throw HubException.NoAnswer(e);
        }
    }

    // ---------------------------------------------------------------- the owner's calls

    /// <summary>The largest answer of an owner read, unless its family gives its own.</summary>
    public const int OwnerReadLimit = 16 * 1024 * 1024;

    /// <summary>A read of the owner's API (windows-app-plan-v2.md, section 6): GET <paramref name="route"/> with the
    /// generation that the PC holds as <c>db</c> before the other values of <paramref name="query"/>, and the key of
    /// <paramref name="call"/>. The answer is decoded with <paramref name="type"/>, from the family's own JSON context.
    /// A changed generation (<see cref="HubException.IsGenerationChanged"/>) is its own result; any other refusal, a
    /// 409 of another kind among them, is a <see cref="HubException"/> with the hub's words, as every read of step 1
    /// (the Mac's HubError.conflict: a 409 is also a stale base, a request number used again, or an action that the
    /// state does not allow now).</summary>
    public async Task<OwnerAnswer<T>> OwnerGetAsync<T>(OwnerCall call, string route, JsonTypeInfo<T> type,
                                                       IReadOnlyList<(string Name, string Value)>? query = null,
                                                       int limit = OwnerReadLimit, CancellationToken cancel = default)
        where T : class
    {
        var read = "GET /" + OwnerRoute(route);
        using var request = Request(HttpMethod.Get, call.Hub, route, call.Key, [("db", call.Database), .. query ?? Array.Empty<(string Name, string Value)>()]);
        Answer answer;
        try
        {
            answer = await SendAsync(request, limit, options.RequestTimeout, cancel);
        }
        catch (HubException e) when (e.IsGenerationChanged)
        {
            return OwnerAnswer<T>.GenerationChanged;
        }
        return new OwnerAnswer<T>(Decoded(answer.Body, type, read));
    }

    /// <summary>A write of the owner's API, in the Mac's envelope (HubClient.ownerCommand): POST
    /// <paramref name="route"/> with the fields of <paramref name="body"/> and beside them <c>request_id</c> (a new one,
    /// or <paramref name="requestId"/>, in small letters) and <c>db</c>, the keys in order, and the client's label in
    /// X-Fleet-Client. An answer that names a request or a client must name these, and one that says <c>"ok": false</c>
    /// is no answer. A changed generation (<see cref="HubException.IsGenerationChanged"/>) is its own result; any other
    /// refusal, a 409 of another kind among them, is a <see cref="HubException"/> with the hub's words.</summary>
    public async Task<OwnerAnswer<TAnswer>> OwnerPostAsync<TBody, TAnswer>(OwnerCall call, string route, TBody body,
                                                                           JsonTypeInfo<TBody> bodyType,
                                                                           JsonTypeInfo<TAnswer> answerType,
                                                                           Guid? requestId = null,
                                                                           CancellationToken cancel = default)
        where TAnswer : class
    {
        var write = "POST /" + OwnerRoute(route);
        var id = (requestId ?? Guid.NewGuid()).ToString("D");
        using var request = Request(HttpMethod.Post, call.Hub, route, call.Key, []);
        request.Headers.TryAddWithoutValidation("X-Fleet-Client", call.Client);
        request.Content = new ByteArrayContent(Envelope(JsonSerializer.SerializeToUtf8Bytes(body, bodyType), id, call.Database));
        request.Content.Headers.ContentType = new MediaTypeHeaderValue("application/json");
        Answer answer;
        try
        {
            answer = await SendAsync(request, HubDecode.ReceiptLimit, options.RequestTimeout, cancel);
        }
        catch (HubException e) when (e.IsGenerationChanged)
        {
            return OwnerAnswer<TAnswer>.GenerationChanged;
        }
        try
        {
            using var document = JsonDocument.Parse(answer.Body);
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object ||
                root.TryGetProperty("request_id", out var named) && !(named.ValueKind == JsonValueKind.String &&
                                                                       string.Equals(named.GetString(), id, StringComparison.OrdinalIgnoreCase)) ||
                root.TryGetProperty("client", out var client) && !(client.ValueKind == JsonValueKind.String && client.GetString() == call.Client) ||
                root.TryGetProperty("ok", out var ok) && ok.ValueKind != JsonValueKind.True)
                throw HubException.InvalidResponse(write, "the answer is not the receipt of this request");
        }
        catch (JsonException e)
        {
            throw HubException.InvalidResponse(write, e.Message, e);
        }
        return new OwnerAnswer<TAnswer>(Decoded(answer.Body, answerType, write));
    }

    /// <summary>POST /ui/owner/computer (owner API 1.273, owner_computer): this computer's kind and the names of what its
    /// app can do, as exactly <c>{"can": [...], "kind": "..."}</c>: the hub refuses any other field, so this write has no
    /// <c>request_id</c> and no <c>db</c> (it is not in the records). Gives what the hub keeps now.</summary>
    public async Task<OwnerComputer> ComputerAsync(OwnerCall call, string kind, IReadOnlyList<string> can,
                                                   CancellationToken cancel = default)
    {
        using var request = Request(HttpMethod.Post, call.Hub, "ui/owner/computer", call.Key, []);
        request.Headers.TryAddWithoutValidation("X-Fleet-Client", call.Client);
        using var stream = new MemoryStream();
        using (var json = new Utf8JsonWriter(stream))
        {
            json.WriteStartObject();
            json.WriteStartArray("can");
            foreach (var name in can) json.WriteStringValue(name);
            json.WriteEndArray();
            json.WriteString("kind", kind);
            json.WriteEndObject();
        }
        request.Content = new ByteArrayContent(stream.ToArray());
        request.Content.Headers.ContentType = new MediaTypeHeaderValue("application/json");
        var answer = await SendAsync(request, HubDecode.ReceiptLimit, options.RequestTimeout, cancel);
        var held = Decoded(answer.Body, CoreJson.Default.ComputerAnswer, "POST /ui/owner/computer").OwnerComputer;
        return new OwnerComputer(held.Kind, held.Label, held.Can);
    }

    /// <summary>A route of the owner's API as a family names it: under ui/, with no query, no "..", no "//".</summary>
    private static string OwnerRoute(string route) =>
        route.StartsWith("ui/", StringComparison.Ordinal) && !route.Contains("..") && !route.Contains("//") &&
        route.All(c => c is >= 'a' and <= 'z' or >= 'A' and <= 'Z' or >= '0' and <= '9' or '/' or '_' or '-' or '.')
            ? route
            : throw new ArgumentException("not a route of the owner's API", nameof(route));

    /// <summary>The body of an owner write: the family's fields with request_id and db, the keys in ordinal order.</summary>
    private static byte[] Envelope(byte[] fields, string requestId, string database)
    {
        using var document = JsonDocument.Parse(fields);
        if (document.RootElement.ValueKind != JsonValueKind.Object)
            throw new ArgumentException("the body of an owner write is a JSON object");
        var all = new SortedDictionary<string, JsonElement>(StringComparer.Ordinal);
        foreach (var field in document.RootElement.EnumerateObject())
        {
            if (field.Name is "request_id" or "db") throw new ArgumentException($"the envelope gives {field.Name}");
            all[field.Name] = field.Value;
        }
        using var stream = new MemoryStream();
        using (var json = new Utf8JsonWriter(stream))
        {
            json.WriteStartObject();
            var added = new SortedDictionary<string, string>(StringComparer.Ordinal) { ["db"] = database, ["request_id"] = requestId };
            foreach (var name in all.Keys.Concat(added.Keys).Order(StringComparer.Ordinal))
            {
                if (added.TryGetValue(name, out var text)) json.WriteString(name, text);
                else
                {
                    json.WritePropertyName(name);
                    all[name].WriteTo(json);
                }
            }
            json.WriteEndObject();
        }
        return stream.ToArray();
    }

    // ---------------------------------------------------------------- the writes

    /// <summary>One message or one answer (POST /ui/messages, POST /ui/needs/&lt;id&gt;), with its own request number,
    /// its generation and this device's client label. The receipt must name the same request.</summary>
    public async Task<SendReceipt> SendAsync(PendingRequest pending, string? key, CancellationToken cancel = default)
    {
        if (pending.Command is not null)
            throw HubException.InvalidResponse("POST /" + pending.Route, "a command goes with CommandAsync");
        using var request = Write(pending, key);
        var answer = await SendAsync(request, HubDecode.ReceiptLimit, options.RequestTimeout, cancel);
        return HubDecode.Receipt(answer.Body, pending);
    }

    /// <summary>One owner command (a task's control or guidance, a question about a Needs-you item), whose receipt must
    /// name the same request and say what it did.</summary>
    public async Task<ControlReceipt> CommandAsync(PendingRequest pending, string? key, CancellationToken cancel = default)
    {
        if (pending.Command is null)
            throw HubException.InvalidResponse("POST /" + pending.Route, "a message goes with SendAsync");
        using var request = Write(pending, key);
        var answer = await SendAsync(request, HubDecode.ReceiptLimit, options.RequestTimeout, cancel);
        return HubDecode.CommandReceipt(answer.Body, pending);
    }

    private static HttpRequestMessage Write(PendingRequest pending, string? key)
    {
        var request = Request(HttpMethod.Post, pending.Hub, pending.Route, key, []);
        request.Headers.TryAddWithoutValidation("X-Fleet-Client", pending.Client);
        request.Headers.TryAddWithoutValidation("X-Fleet-Request-Id", pending.RequestIdText);
        request.Content = new ByteArrayContent(pending.Body());
        request.Content.Headers.ContentType = new MediaTypeHeaderValue("application/json");
        return request;
    }

    // ---------------------------------------------------------------- files

    /// <summary>POST /ui/attachments: one file, before the message that carries it (MobileClient.upload). Its own number
    /// makes it idempotent, so a repeat is one file on the hub. The answer must describe the bytes that went. The upload's
    /// client must be the message's.</summary>
    public async Task<MessageAttachment> UploadAsync(Uri hub, string? key, string database, byte[] data, string name,
                                                     string mime, Guid requestId, string client,
                                                     CancellationToken cancel = default)
    {
        if (!MessageAttachment.Types.ContainsKey(mime)) throw new AttachmentException(AttachmentException.Problem.Type);
        if (data.Length == 0 || data.Length > MessageAttachment.SizeLimit)
            throw new AttachmentException(AttachmentException.Problem.TooLarge);
        using var request = Request(HttpMethod.Post, hub, "ui/attachments", key, [("db", database)]);
        request.Headers.TryAddWithoutValidation("X-Fleet-Client", client);
        request.Headers.TryAddWithoutValidation("X-Fleet-Request-Id", requestId.ToString("D"));
        request.Headers.TryAddWithoutValidation("X-Fleet-Name", MessageAttachment.SafeName(name, mime));
        request.Content = new ByteArrayContent(data);
        request.Content.Headers.ContentType = new MediaTypeHeaderValue(mime);
        var answer = await SendAsync(request, HubDecode.ReceiptLimit, options.KnowledgeTimeout, cancel);
        var file = HubDecode.Attachment(answer.Body);
        if (file.Mime != mime || !file.Matches(data)) throw new AttachmentException(AttachmentException.Problem.Bytes);
        return file;
    }

    /// <summary>GET /ui/attachments/&lt;id&gt;: the bytes of a file that a message carries, with their count and their
    /// SHA-256 checked before anything shows them (MobileClient.attachment). A device gets 404 for an upload that no
    /// message carries yet.</summary>
    public async Task<byte[]> AttachmentAsync(Uri hub, string? key, string database, MessageAttachment file,
                                              CancellationToken cancel = default)
    {
        if (!file.IsValid) throw new AttachmentException(AttachmentException.Problem.Metadata);
        using var request = Request(HttpMethod.Get, hub, $"ui/attachments/{file.Id}", key, [("db", database)]);
        var answer = await SendAsync(request, (int)MessageAttachment.SizeLimit, options.KnowledgeTimeout, cancel);
        if (!file.Matches(answer.Body)) throw new AttachmentException(AttachmentException.Problem.Bytes);
        return answer.Body;
    }

    // ---------------------------------------------------------------- one request

    /// <summary>One request: the route under the hub's address, the query with every value percent-encoded, JSON
    /// accepted, and the device's key as a bearer token when it has one. A device without a key sends no header at all,
    /// because the owner's own computer is refused when it sends one (`key_not_expected`). The key never goes into the
    /// address, a query or a log.</summary>
    internal static HttpRequestMessage Request(HttpMethod method, Uri hub, string route, string? key,
                                               IReadOnlyList<(string Name, string Value)> query)
    {
        var address = new StringBuilder(hub.ToString().TrimEnd('/')).Append('/').Append(route);
        for (var i = 0; i < query.Count; i++)
            address.Append(i == 0 ? '?' : '&').Append(Uri.EscapeDataString(query[i].Name)).Append('=')
                   .Append(Uri.EscapeDataString(query[i].Value));
        var request = new HttpRequestMessage(method, address.ToString());
        request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));
        if (!string.IsNullOrEmpty(key)) request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", key);
        return request;
    }

    private static ByteArrayContent Json(SortedDictionary<string, string> fields)
    {
        using var stream = new MemoryStream();
        using (var json = new Utf8JsonWriter(stream))
        {
            json.WriteStartObject();
            foreach (var (name, value) in fields) json.WriteString(name, value);
            json.WriteEndObject();
        }
        var content = new ByteArrayContent(stream.ToArray());
        content.Headers.ContentType = new MediaTypeHeaderValue("application/json");
        return content;
    }

    private readonly record struct Answer(int Status, byte[] Body, string? ETag);

    /// <summary>Sends one request with its own timeout, reads at most <paramref name="limit"/> bytes of the answer, and
    /// turns every status but 200 (and 304 where it is asked for) into a refusal with the hub's own words.</summary>
    private async Task<Answer> SendAsync(HttpRequestMessage request, int limit, TimeSpan timeout,
                                         CancellationToken cancel, bool allow304 = false)
    {
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancel);
        deadline.CancelAfter(timeout);
        try
        {
            using var response = await http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, deadline.Token);
            var status = (int)response.StatusCode;
            if (allow304 && status == 304) return new Answer(304, [], response.Headers.ETag?.ToString());
            var body = await ReadAsync(response.Content, status == 200 ? limit : 65_536, deadline.Token);
            if (status != 200)
            {
                var (error, auth, code) = HubDecode.Refusal(body ?? []);
                var words = error ?? "The hub gave no reason.";
                throw HubException.Refusal(status, auth, words.Length > 500 ? words[..500] : words, code);
            }
            if (body is null)
                throw HubException.InvalidResponse($"{request.Method} {request.RequestUri?.AbsolutePath}",
                                                   $"the answer is larger than {limit} bytes");
            string? etag = null;
            if (response.Headers.TryGetValues("ETag", out var tags)) foreach (var tag in tags) etag = tag;
            return new Answer(status, body, etag);
        }
        catch (OperationCanceledException) when (!cancel.IsCancellationRequested)
        {
            throw HubException.NoAnswer();
        }
        catch (HttpRequestException e)
        {
            throw HubException.NoAnswer(e);
        }
        catch (IOException e)
        {
            throw HubException.NoAnswer(e);
        }
    }

    /// <summary>The body, or null when it is longer than <paramref name="limit"/>: a body that is too large is never held
    /// in memory whole.</summary>
    private static async Task<byte[]?> ReadAsync(HttpContent content, int limit, CancellationToken cancel)
    {
        await using var stream = await content.ReadAsStreamAsync(cancel);
        var buffer = new MemoryStream();
        var chunk = new byte[16_384];
        while (true)
        {
            var read = await stream.ReadAsync(chunk, cancel);
            if (read == 0) return buffer.ToArray();
            if (buffer.Length + read > limit) return null;
            buffer.Write(chunk, 0, read);
        }
    }
}
