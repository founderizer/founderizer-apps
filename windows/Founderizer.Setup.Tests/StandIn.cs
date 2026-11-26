using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using Founderizer.Core;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace Founderizer.Setup.Tests;

/// <summary>**A stand-in for a provider**, as the Swift tests' <c>ProviderStandIn</c> answers: answers by method and
/// path, in order, the last one again for each later request, 404 for a path that has none, and status -1 as a connection
/// that fails. It keeps each request, and nothing reaches the network.</summary>
internal sealed class StandIn : HttpMessageHandler
{
    public const int Dropped = -1;
    public sealed record Call(string Method, Uri Url, Dictionary<string, string> Headers, string Body);
    private sealed record Answer(int Status, string Body, Dictionary<string, string> Headers);

    private readonly Dictionary<string, List<Answer>> answers = new(StringComparer.Ordinal);
    private readonly Dictionary<string, int> given = new(StringComparer.Ordinal);
    private readonly List<Call> calls = [];
    private readonly object gate = new();

    public IReadOnlyList<Call> Calls { get { lock (gate) return calls.ToList(); } }

    public void Add(string method, string path, int status, string body = "{}", Dictionary<string, string>? headers = null)
    {
        lock (gate)
        {
            var key = method + " " + path;
            if (!answers.TryGetValue(key, out var list)) answers[key] = list = [];
            list.Add(new Answer(status, body, headers ?? []));
        }
    }

    /// <summary>A stand-in with the answers of one case of a vector file.</summary>
    public static StandIn From(JsonElement given)
    {
        var stand = new StandIn();
        foreach (var answer in given.EnumerateArray())
            stand.Add(answer.GetProperty("method").GetString()!, answer.GetProperty("path").GetString()!, answer.GetProperty("status").GetInt32(),
                      answer.GetProperty("body").GetString()!,
                      answer.GetProperty("headers").EnumerateObject().ToDictionary(h => h.Name, h => h.Value.GetString()!));
        return stand;
    }

    protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
    {
        var headers = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        // As the header goes on the wire: a User-Agent's product and comment with a space, other values with a comma.
        foreach (var header in request.Headers)
            headers[header.Key] = string.Join(header.Key.Equals("User-Agent", StringComparison.OrdinalIgnoreCase) ? " " : ",", header.Value);
        var body = "";
        if (request.Content is not null)
        {
            foreach (var header in request.Content.Headers)
                if (!header.Key.Equals("Content-Length", StringComparison.OrdinalIgnoreCase)) headers[header.Key] = string.Join(",", header.Value);
            body = Encoding.UTF8.GetString(await request.Content.ReadAsByteArrayAsync(cancellationToken));
        }
        Answer answer;
        lock (gate)
        {
            calls.Add(new Call(request.Method.Method, request.RequestUri!, headers, body));
            var key = request.Method.Method + " " + Uri.UnescapeDataString(request.RequestUri!.AbsolutePath);
            if (!answers.TryGetValue(key, out var queue) || queue.Count == 0)
                answer = new Answer(404, "{\"message\":\"no such thing\"}", []);
            else
            {
                var index = Math.Min(given.GetValueOrDefault(key), queue.Count - 1);
                given[key] = index + 1;
                answer = queue[index];
            }
        }
        if (answer.Status == Dropped) throw new HttpRequestException("the connection was lost");
        var response = new HttpResponseMessage((HttpStatusCode)answer.Status)
        {
            Content = new ByteArrayContent(Encoding.UTF8.GetBytes(answer.Body)),
            RequestMessage = request,
        };
        foreach (var (name, value) in answer.Headers) response.Headers.TryAddWithoutValidation(name, value);
        return response;
    }
}

/// <summary>**The reads that a cloud call starts after it ended** (<see cref="Founderizer.Setup.Cloud.CloudServers.For"/>'s
/// <c>follow</c>, the Swift tests' <c>Follows</c>): each a task that a test waits for with <see cref="DoneAsync"/>, so
/// that what they sent is in the stand-in's calls before the test reads them.</summary>
internal sealed class Follows
{
    private readonly List<Task> tasks = [];

    public void Follow(Func<Task> body)
    {
        lock (tasks) tasks.Add(Task.Run(body));
    }

    public Task DoneAsync()
    {
        lock (tasks) return Task.WhenAll(tasks.ToList());
    }
}

/// <summary>A box that will not keep anything, as a box whose protection fails.</summary>
internal sealed class RefusingBox(ISecretBox inner) : ISecretBox
{
    public byte[]? Read(string name) => inner.Read(name);
    public void Write(string name, byte[] value) => throw new CryptographicException("the box refuses");
    public void Remove(string name) => inner.Remove(name);
}

/// <summary>Holds what the C# gives equal to what a vector holds, and says each difference.</summary>
internal static class Same
{
    /// <summary>The Mac's words with this PC in place of this Mac.</summary>
    public static string OnPc(string words) =>
        words.Replace("this Mac", "this PC", StringComparison.Ordinal).Replace("This Mac", "This PC", StringComparison.Ordinal);

    /// <summary>An enum's name as the vectors write a case: NotAToken is not_a_token.</summary>
    public static string Snake<T>(T value) where T : struct, Enum =>
        Regex.Replace(value.ToString(), "(?<!^)([A-Z])", "_$1").ToLowerInvariant();

    /// <summary>A text with each secret by its name, the longest first, and each part made of chance by its name.</summary>
    public static string Shown(string text, JsonElement secrets, IReadOnlyList<(string Pattern, string Name)> chance)
    {
        var shown = text;
        foreach (var secret in secrets.EnumerateObject().OrderByDescending(s => s.Value.GetString()!.Length))
            if (secret.Value.GetString() is { Length: > 0 } value) shown = shown.Replace(value, secret.Name, StringComparison.Ordinal);
        foreach (var (pattern, name) in chance) shown = Regex.Replace(shown, pattern, name);
        return shown;
    }

    /// <summary>The chance patterns of a vector file, with .NET's way of naming a group in a replacement.</summary>
    public static List<(string, string)> Chance(JsonElement file) =>
        file.TryGetProperty("chance", out var chance)
            ? chance.EnumerateArray().Select(c => (c.GetProperty("pattern").GetString()!, c.GetProperty("name").GetString()!)).ToList()
            : [];

    /// <summary>Each request that the stand-in got, held equal to the vector's: method, address, headers and body, with
    /// the secrets and the chance shown by name. A JSON body is compared as JSON (each string with its secrets and chance
    /// by name, and Akamai's root password by its shape); any other body byte for byte.</summary>
    public static void Requests(JsonElement expected, IReadOnlyList<StandIn.Call> calls, JsonElement secrets,
                                IReadOnlyList<(string, string)> chance, List<string> problems, string name)
    {
        var want = expected.EnumerateArray().ToList();
        if (want.Count != calls.Count)
        {
            problems.Add($"{name}: {calls.Count} requests, the vector has {want.Count}: " +
                         string.Join(" | ", calls.Select(c => c.Method + " " + c.Url.AbsoluteUri)));
            return;
        }
        for (var i = 0; i < want.Count; i++)
        {
            var call = calls[i];
            var w = want[i];
            var where = $"{name}, request {i + 1}";
            if (call.Method != w.GetProperty("method").GetString()) problems.Add($"{where}: method {call.Method}");
            var url = Shown(call.Url.AbsoluteUri, secrets, chance);
            if (url != w.GetProperty("url").GetString()) problems.Add($"{where}: address {url}, the vector {w.GetProperty("url").GetString()}");
            var headers = w.GetProperty("headers").EnumerateObject().ToDictionary(h => h.Name, h => h.Value.GetString()!, StringComparer.OrdinalIgnoreCase);
            // The Mac's session adds its own User-Agent under the stand-in, so no vector holds one: the PC's is its own
            // fixed one, on every request.
            if (!call.Headers.TryGetValue("User-Agent", out var agent) || agent != Founderizer.Setup.Network.ProviderHttp.UserAgent)
                problems.Add($"{where}: User-Agent {agent ?? "none"}, not {Founderizer.Setup.Network.ProviderHttp.UserAgent}");
            foreach (var (header, value) in call.Headers)
            {
                if (header.Equals("User-Agent", StringComparison.OrdinalIgnoreCase)) continue;
                var shown = Shown(value, secrets, chance);
                if (!headers.TryGetValue(header, out var wanted)) problems.Add($"{where}: a header {header} that the Mac does not send");
                else if (wanted != shown) problems.Add($"{where}: {header} is {shown}, the vector {wanted}");
            }
            foreach (var header in headers.Keys)
                if (!call.Headers.ContainsKey(header)) problems.Add($"{where}: no header {header}");
            var body = w.GetProperty("body").GetString()!;
            if (headers.TryGetValue("Content-Type", out var type) && type == "application/json" && body.Length > 0)
            {
                JsonNode? sent;
                try { sent = JsonNode.Parse(call.Body); }
                catch (JsonException) { problems.Add($"{where}: a body that is not JSON: {call.Body}"); continue; }
                var shown = ShownStrings(sent, secrets, chance);
                Json(JsonDocument.Parse(body).RootElement, shown, $"{where}, body", problems);
            }
            else if (Shown(call.Body, secrets, chance) != body) problems.Add($"{where}: body\n{Shown(call.Body, secrets, chance)}\nthe vector\n{body}");
        }
    }

    private const string RootAlphabet = "abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789!#%+-.:=@^_~";

    private static JsonNode? ShownStrings(JsonNode? node, JsonElement secrets, IReadOnlyList<(string, string)> chance, string? key = null)
    {
        switch (node)
        {
            case JsonObject o:
                var copy = new JsonObject();
                foreach (var (k, v) in o) copy[k] = ShownStrings(v, secrets, chance, k);
                return copy;
            case JsonArray a:
                return new JsonArray(a.Select(v => ShownStrings(v, secrets, chance)).ToArray());
            case JsonValue v when v.GetValueKind() == JsonValueKind.String:
                var text = v.GetValue<string>();
                if (key == "root_pass" && text.Length == 32 && text.All(RootAlphabet.Contains)) return "{root password}";
                return Shown(text, secrets, chance);
            default:
                return node?.DeepClone();
        }
    }

    /// <summary>Holds a JSON value equal to the vector's: objects by their members, lists in order, numbers by value, and a
    /// price by the amount its text writes.</summary>
    public static void Json(JsonElement expected, JsonNode? actual, string where, List<string> problems, string? key = null, bool onPc = false)
    {
        switch (expected.ValueKind)
        {
            case JsonValueKind.Null:
                if (actual is not null) problems.Add($"{where}: {actual.ToJsonString()}, the vector null");
                return;
            case JsonValueKind.Object:
                if (actual is not JsonObject o) { problems.Add($"{where}: {actual?.ToJsonString() ?? "null"}, the vector an object"); return; }
                foreach (var member in expected.EnumerateObject())
                    Json(member.Value, o.TryGetPropertyValue(member.Name, out var v) ? v : null, where + "." + member.Name, problems, member.Name, onPc);
                foreach (var (k, _) in o)
                    if (!expected.TryGetProperty(k, out _)) problems.Add($"{where}: a member {k} that the vector does not have");
                return;
            case JsonValueKind.Array:
                if (actual is not JsonArray a) { problems.Add($"{where}: {actual?.ToJsonString() ?? "null"}, the vector a list"); return; }
                var items = expected.EnumerateArray().ToList();
                if (items.Count != a.Count) { problems.Add($"{where}: {a.Count} items, the vector {items.Count}: {a.ToJsonString()}"); return; }
                for (var i = 0; i < items.Count; i++) Json(items[i], a[i], $"{where}[{i}]", problems, null, onPc);
                return;
            case JsonValueKind.Number:
                if (actual is not JsonValue n || n.GetValueKind() != JsonValueKind.Number ||
                    Math.Abs(double.Parse(n.ToJsonString(), CultureInfo.InvariantCulture) - expected.GetDouble()) > 1e-3)
                    problems.Add($"{where}: {actual?.ToJsonString() ?? "null"}, the vector {expected.GetRawText()}");
                return;
            case JsonValueKind.String:
                var wanted = onPc ? OnPc(expected.GetString()!) : expected.GetString()!;
                var given = actual is JsonValue s && s.GetValueKind() == JsonValueKind.String ? s.GetValue<string>() : null;
                if (key == "price" && given is not null &&
                    decimal.Parse(given, CultureInfo.InvariantCulture) == decimal.Parse(wanted, CultureInfo.InvariantCulture)) return;
                if (given != wanted) problems.Add($"{where}: {actual?.ToJsonString() ?? "null"}, the vector \"{wanted}\"");
                return;
            default:
                var flag = expected.ValueKind == JsonValueKind.True;
                if (actual is not JsonValue b || b.GetValueKind() is not (JsonValueKind.True or JsonValueKind.False) || b.GetValue<bool>() != flag)
                    problems.Add($"{where}: {actual?.ToJsonString() ?? "null"}, the vector {flag}");
                return;
        }
    }

    /// <summary>Fails with every difference at once, so one run says them all.</summary>
    public static void None(List<string> problems, int checkedCount)
    {
        Assert.IsTrue(checkedCount > 0, "no case was checked");
        if (problems.Count > 0) Assert.Fail($"{problems.Count} differences:\n" + string.Join("\n", problems.Take(60)));
    }

    public static JsonNode? Strings(IEnumerable<string> values) => new JsonArray(values.Select(v => (JsonNode?)v).ToArray());
}
