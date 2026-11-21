using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Reflection;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Threading;
using System.Threading.Tasks;

namespace Founderizer.Setup.Network;

/// <summary>The one way out to a provider's own API (Tailscale's, Hetzner's, DigitalOcean's, Vultr's, Akamai's): the
/// Mac's <c>ProviderExchange</c>. All HTTP of <see cref="TailscaleApi"/> and of the clouds goes through the handler that
/// the caller gives, so each request is proved against a stand-in with no network (windows-app-plan-v2.md, piece L2).
/// The window gives <see cref="ProviderHandler.Create"/>.</summary>
public static class ProviderHandler
{
    /// <summary>The Mac's provider session: nothing cached, no cookie, no stored credential, and **no redirect
    /// followed**, so a token goes to the host it was written for and to no other. The system's proxy, as the Mac's
    /// session has it.</summary>
    public static HttpMessageHandler Create() => new SocketsHttpHandler
    {
        AllowAutoRedirect = false,
        UseCookies = false,
        Credentials = null,
        PreAuthenticate = false,
        ConnectTimeout = TimeSpan.FromSeconds(30),
        AutomaticDecompression = DecompressionMethods.None,
    };
}

/// <summary>One answer of a provider: its status, its body, and the version tag of what was read.</summary>
internal sealed record ProviderAnswer(int Status, byte[] Body, string? ETag)
{
    public bool Ok => Status is >= 200 and <= 299;
    public string Text => Encoding.UTF8.GetString(Body);
}

/// <summary>A request that did not reach the provider, or whose answer did not come back (the Mac's <c>URLError</c>).
/// Each caller says it in its own words.</summary>
internal sealed class ProviderUnreachableException(string message, Exception? inner = null) : Exception(message, inner);

/// <summary>The exchange with one provider: a request out, its answer back. The time limits are the Mac's: 30 seconds
/// to connect and for a request, 60 for the whole of it.</summary>
internal sealed class ProviderHttp
{
    private readonly HttpClient client;

    /// <summary>**The one User-Agent of this app's requests to a provider**: its name, its version and Windows. The Mac's
    /// session sends one of its own (the app's name and build, then CFNetwork's); an API behind a content network can
    /// refuse a request that has none.</summary>
    internal static readonly string UserAgent = "Founderizer/" + Version() + " (Windows)";

    public ProviderHttp(HttpMessageHandler handler)
    {
        client = new HttpClient(handler, disposeHandler: false) { Timeout = TimeSpan.FromSeconds(60) };
        client.DefaultRequestHeaders.UserAgent.ParseAdd(UserAgent);
    }

    /// <summary>This build's version as its assembly says it, without the commit that the build adds after a "+", and
    /// "1.0" when it says none of the plain form.</summary>
    private static string Version()
    {
        var said = typeof(ProviderHttp).Assembly.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion ?? "";
        var version = said.Split('+')[0];
        return version.Length is > 0 and <= 40 && version.All(c => char.IsAsciiLetterOrDigit(c) || c is '.' or '-') ? version : "1.0";
    }

    /// <summary>Sends one request. <paramref name="headers"/> are set as they are given (each value is a token, a media
    /// type or a version tag that this library checked has no line end). A request that the caller cancels throws
    /// <see cref="OperationCanceledException"/>; any other that gets no answer throws
    /// <see cref="ProviderUnreachableException"/>, as does an answer from another address than the request's (a handler
    /// that followed a redirect).</summary>
    public async Task<ProviderAnswer> SendAsync(string method, Uri url, IReadOnlyList<(string Name, string Value)> headers,
                                                byte[]? body, string? contentType, CancellationToken cancel)
    {
        using var request = new HttpRequestMessage(new HttpMethod(method), url);
        foreach (var (name, value) in headers)
        {
            if (value.Contains('\r') || value.Contains('\n')) throw new ArgumentException("a header value with a line end", nameof(headers));
            request.Headers.TryAddWithoutValidation(name, value);
        }
        if (body is not null)
        {
            request.Content = new ByteArrayContent(body);
            if (contentType is not null) request.Content.Headers.ContentType = new MediaTypeHeaderValue(contentType);
        }
        try
        {
            using var response = await client.SendAsync(request, HttpCompletionOption.ResponseContentRead, cancel).ConfigureAwait(false);
            if (response.RequestMessage?.RequestUri is { } answered && answered != url)
                throw new ProviderUnreachableException("the answer came from another address");
            var data = await response.Content.ReadAsByteArrayAsync(cancel).ConfigureAwait(false);
            var etag = response.Headers.TryGetValues("ETag", out var tags) ? string.Join(",", tags) : null;
            return new ProviderAnswer((int)response.StatusCode, data, etag);
        }
        catch (OperationCanceledException) when (cancel.IsCancellationRequested) { throw; }
        catch (ProviderUnreachableException) { throw; }
        catch (Exception e) when (e is HttpRequestException or OperationCanceledException or System.IO.IOException)
        {
            throw new ProviderUnreachableException("the provider could not be reached", e);
        }
    }
}

/// <summary>Reads of a JSON answer as the Mac's <c>JSONSerialization</c> and its casts read them: a value of another
/// kind is no value.</summary>
internal static class Json
{
    /// <summary>The answer as a JSON node, or null when it is not JSON, read as the Mac's <c>JSONSerialization</c> reads
    /// it: a member that an object names twice is the last one (a node of .NET's own would throw at its first read), and
    /// a comma before a closing bracket is taken.</summary>
    public static JsonNode? Parse(byte[] data)
    {
        if (data.Length == 0) return null;
        try
        {
            using var document = JsonDocument.Parse(data, new JsonDocumentOptions { AllowTrailingCommas = true });
            return Node(document.RootElement);
        }
        catch (JsonException) { return null; }
    }

    public static JsonNode? Parse(string text) => Parse(System.Text.Encoding.UTF8.GetBytes(text));

    private static JsonNode? Node(JsonElement element)
    {
        switch (element.ValueKind)
        {
            case JsonValueKind.Object:
                var members = new JsonObject();
                foreach (var member in element.EnumerateObject()) members[member.Name] = Node(member.Value);
                return members;
            case JsonValueKind.Array:
                var list = new JsonArray();
                foreach (var item in element.EnumerateArray()) list.Add(Node(item));
                return list;
            case JsonValueKind.Null:
                return null;
            default:
                return JsonValue.Create(element.Clone());
        }
    }

    public static JsonObject? Object(JsonNode? node) => node as JsonObject;
    public static JsonArray? Array(JsonNode? node) => node as JsonArray;

    /// <summary>A member of an object, or null.</summary>
    public static JsonNode? At(JsonNode? node, string name) => node is JsonObject o && o.TryGetPropertyValue(name, out var v) ? v : null;

    /// <summary>Whether an object has the member at all, null included (Swift's <c>object[name] != nil</c>).</summary>
    public static bool Has(JsonNode? node, string name) => node is JsonObject o && o.ContainsKey(name);

    /// <summary>A member that is there and is not null (the Mac's <c>isSet</c>).</summary>
    public static bool IsSet(JsonNode? node, string name) => At(node, name) is not null;

    public static string? String(JsonNode? node) =>
        node is JsonValue v && v.GetValueKind() == JsonValueKind.String ? v.GetValue<string>() : null;

    public static bool? Bool(JsonNode? node) => node is JsonValue v ? v.GetValueKind() switch
    {
        JsonValueKind.True => true,
        JsonValueKind.False => false,
        _ => null,
    } : null;

    /// <summary>A whole number that fits an int, as Swift's <c>as? Int</c> takes one (4.0 is 4; 4.5 is none): a count, a
    /// size, a page's length. **Never an id**: a provider's ids pass 32 bits (Hetzner's since September 2023), and Swift's
    /// Int has 64; an id, a page number and a count of pages are <see cref="Long"/>.</summary>
    public static int? Int(JsonNode? node)
    {
        if (Decimal(node) is not { } value || value != Math.Truncate(value) || value < int.MinValue || value > int.MaxValue) return null;
        return (int)value;
    }

    public static long? Long(JsonNode? node)
    {
        if (Decimal(node) is not { } value || value != Math.Truncate(value) || value < long.MinValue || value > long.MaxValue) return null;
        return (long)value;
    }

    public static double? Double(JsonNode? node) =>
        node is JsonValue v && v.GetValueKind() == JsonValueKind.Number && v.TryGetValue<double>(out var d) ? d : null;

    /// <summary>A number as the decimal that its text writes (the Mac's <c>Decimal(string: number.stringValue)</c>).</summary>
    public static decimal? Decimal(JsonNode? node)
    {
        if (node is not JsonValue v || v.GetValueKind() != JsonValueKind.Number) return null;
        if (v.TryGetValue<decimal>(out var exact)) return exact;
        return v.TryGetValue<double>(out var d) && !double.IsInfinity(d) && Math.Abs(d) < 7.9e28 ? (decimal)d : null;
    }

    /// <summary>A list of objects (others in it left out), as <c>as? [[String: Any]]</c> with a compactMap.</summary>
    public static IEnumerable<JsonObject> Objects(JsonNode? node)
    {
        if (node is not JsonArray list) yield break;
        foreach (var item in list) if (item is JsonObject o) yield return o;
    }

    /// <summary>A list of strings (others in it left out).</summary>
    public static List<string> Strings(JsonNode? node)
    {
        var found = new List<string>();
        if (node is JsonArray list)
            foreach (var item in list)
                if (String(item) is { } s) found.Add(s);
        return found;
    }

    /// <summary>A list in which every item is a string, or null (Swift's <c>as? [String]</c>).</summary>
    public static List<string>? AllStrings(JsonNode? node)
    {
        if (node is not JsonArray list) return null;
        var found = new List<string>();
        foreach (var item in list)
        {
            if (String(item) is not { } s) return null;
            found.Add(s);
        }
        return found;
    }

    /// <summary>The body of a request, as one line of JSON.</summary>
    public static byte[] Write(JsonNode node)
    {
        using var stream = new System.IO.MemoryStream();
        using (var writer = new Utf8JsonWriter(stream)) node.WriteTo(writer);
        return stream.ToArray();
    }

    /// <summary>A Double as Swift writes it in a string: "1.0", "0.5", "1.5".</summary>
    public static string SwiftDouble(double value) =>
        value == Math.Truncate(value) && Math.Abs(value) < 1e16
            ? ((long)value).ToString(CultureInfo.InvariantCulture) + ".0"
            : value.ToString("R", CultureInfo.InvariantCulture);
}
