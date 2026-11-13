using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
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

/// <summary>What GET /ui/mobile gave: the snapshot, its ETag, and the bytes as the hub sent them, for the next start.</summary>
public sealed record SnapshotReading(MobileSnapshot Snapshot, string? ETag, byte[] Body);

/// <summary>Everything that the Windows app sends to the hub, on the routes that an owner device reaches (hub.py
/// DEVICE_PATHS): the iPhone's MobileClient, with the Mac's hardening. No redirect (the hub is one address inside the
/// private network, and a redirect would take the key somewhere else), no cookie, no stored credential, no proxy (the
/// bearer key goes to the hub and to nothing between), gzip and no other encoding, and the device's key as a bearer
/// token on every call once it has one. Each answer is read with a size cap and decoded by <see cref="HubDecode"/>.</summary>
public sealed class HubClient : IDisposable
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

    /// <summary>GET /ui/mobile, with the generation that the device holds and the ETag of its last body. Null when the
    /// hub answers 304: the fleet did not change and the device keeps what it has. A hub without the route answers 404,
    /// which is <see cref="HubErrorKind.NoPhoneRoutes"/>.</summary>
    public async Task<SnapshotReading?> SnapshotAsync(Uri hub, string? key, string? database, string? etag,
                                                      CancellationToken cancel = default)
    {
        using var request = Request(HttpMethod.Get, hub, "ui/mobile", key, database is null ? [] : [("db", database)]);
        if (etag is not null) request.Headers.TryAddWithoutValidation("If-None-Match", etag);
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
                var (error, auth) = HubDecode.Refusal(body ?? []);
                var words = error ?? "The hub gave no reason.";
                throw HubException.Refusal(status, auth, words.Length > 500 ? words[..500] : words);
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
