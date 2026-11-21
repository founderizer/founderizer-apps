using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Net.Http;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using Founderizer.Core;

namespace Founderizer.Setup.Network;

/// <summary>**The fleet's own lasting key to the owner's private network (Tailscale)**, made from one access token that
/// the owner pastes once, so that every server joins the network later with no approval to press (the Mac's
/// <c>TailscaleFleetKey</c>; windows-app-plan-v2.md, piece L2).
///
/// The PC makes what the fleet keeps out of the token, in three steps, and keeps nothing of the token itself: the tag
/// <c>tag:founderizer</c> in the policy file's <c>tagOwners</c> (only a missing tag in a file that this app may not write
/// is asked of the owner, as one line); the file changed only where no other tool keeps it, against the version that was
/// read; and the fleet key, an OAuth client of the owner's tailnet that never expires and can only make keys for that
/// tag. Its id and secret stay in the secret box (<see cref="ClientName"/>).
///
/// After that, <see cref="AuthKeyAsync"/> makes one key for one machine: single-use, pre-authorized, tagged, not
/// ephemeral, and worthless after its life. All HTTP goes through the handler that the caller gives.</summary>
public sealed partial class TailscaleApi
{
    /// <summary>The tag every machine of a fleet carries.</summary>
    public const string Tag = "tag:founderizer";
    /// <summary>The page where the owner makes the access token, once.</summary>
    public static readonly Uri KeysPage = new("https://login.tailscale.com/admin/settings/keys");
    /// <summary>Tailscale's own API. <c>-</c> is "the tailnet of this token", so no tailnet name is ever asked for.</summary>
    internal const string Api = "https://api.tailscale.com/api/v2";
    /// <summary>What the owner's devices use of a fleet's machines: SSH, the hub's port, and the port of the fleet's code.</summary>
    public static readonly IReadOnlyList<string> Ports = ["tcp:22", "tcp:8765", "tcp:9418"];
    /// <summary>What a machine of the fleet uses of the hub: its own port, and the port of the fleet's code.</summary>
    public static readonly IReadOnlyList<string> HubPorts = ["tcp:8765", "tcp:9418"];
    /// <summary>The owner's devices, as the policy names them: the people who run the tailnet.</summary>
    public static readonly IReadOnlyList<string> Owners = ["autogroup:owner", "autogroup:admin"];
    /// <summary>What the fleet key may do: make keys for machines, and read and change the machines it made.</summary>
    internal static readonly IReadOnlyList<string> Scopes = ["auth_keys", "devices:core"];
    /// <summary>The fleet key's name in Tailscale's list of credentials.</summary>
    internal const string ClientDescription = "Founderizer fleet";
    /// <summary>How long a minted key may be used before it is worthless, unless the caller says otherwise.</summary>
    public const int KeyLifeSeconds = 900;
    /// <summary>The fleet key's name in the secret box (5.4: the Mac's Keychain item
    /// <c>com.founderizer.tailscale.fleet-client</c>).</summary>
    public const string ClientName = "tailscale/fleet-client";

    private readonly ProviderHttp http;
    private readonly ISecretBox box;

    public TailscaleApi(HttpMessageHandler handler, ISecretBox box)
    {
        http = new ProviderHttp(handler);
        this.box = box;
    }

    /// <summary>Whether this PC holds a fleet key.</summary>
    public bool IsHeld => HeldClient() is not null;

    /// <summary>The fleet key in the box, or null; a value that does not open is none.</summary>
    private FleetClient? HeldClient()
    {
        try { return box.Read(ClientName) is { } stored ? FleetClient.Of(stored) : null; }
        catch (CryptographicException) { return null; }
    }

    // Once: the token, the policy file, the fleet key

    /// <summary>Prepares the owner's tailnet and keeps the fleet key, from one access token that is used here and kept
    /// nowhere (the Mac's <c>connect</c>). **Only the tag, the token and Tailscale itself can stop it.** A policy file
    /// that another tool keeps is read and never written: when the tag is missing there, the answer carries that one
    /// line and the place of the file, and no key is made.</summary>
    public async Task<FleetKeySetup> MakeFleetClientAsync(string accessToken, CancellationToken cancel = default)
    {
        var token = CheckedToken(accessToken);
        var (managed, link) = await SettingsAsync(token, cancel).ConfigureAwait(false);
        var place = managed ? PolicyPlace.OfTool(link) : PolicyPlace.Tailscale;
        var asksForTag = new FleetKeySetup(false, false, FleetPolicy.TagLine + ",", place);
        var wrote = false;
        for (var attempt = 1; attempt <= 2; attempt++)
        {
            var (text, etag) = await PolicyAsync(token, cancel).ConfigureAwait(false);
            if (FleetPolicy.NeedsIn(text) is not { IsEmpty: false } needs) break;
            if (managed || etag is null)
            {
                if (needs.Tag) return asksForTag;
                break;
            }
            if (!needs.Tag)
            {
                // The tag stands, so the key needs nothing of this write: a check that refuses the grants, a role that
                // may not write the file and a file that changes twice meanwhile leave the file as it is.
                string? grantsWritten;
                bool set;
                try
                {
                    grantsWritten = await TakenAsync(needs, text, token, cancel).ConfigureAwait(false);
                    if (grantsWritten is null) break;
                    set = await SetAsync(grantsWritten, etag, token, cancel).ConfigureAwait(false);
                }
                catch (FleetKeyException) { break; }
                if (set) { wrote = true; break; }
                if (attempt == 1) continue;
                break;
            }
            if (await TakenAsync(needs, text, token, cancel).ConfigureAwait(false) is not { } written) return asksForTag;
            if (await SetAsync(written, etag, token, cancel).ConfigureAwait(false)) { wrote = true; break; }
            if (attempt != 1) throw new FleetKeyException(FleetKeyFailure.PolicyChangedMeanwhile);
        }
        await MakeKeyAsync(token, cancel).ConfigureAwait(false);
        return new FleetKeySetup(true, wrote, null, place);
    }

    /// <summary>The file with what it misses, as Tailscale's own check takes it; null when no line of it goes in. A file
    /// whose own check refuses the grants gets the tag alone.</summary>
    private async Task<string?> TakenAsync(FleetPolicy.Needs needs, string text, string token, CancellationToken cancel)
    {
        if (FleetPolicy.Writing(needs, text) is { } whole)
        {
            if (await CheckAsync(whole, token, cancel).ConfigureAwait(false) is not { } refusal) return whole;
            if (needs.Grants.Count == 0) throw new FleetKeyException(FleetKeyFailure.Refused, refusal);
        }
        if (!needs.Tag || needs.Grants.Count == 0 || FleetPolicy.Writing(new FleetPolicy.Needs(true, []), text) is not { } tagged) return null;
        if (await CheckAsync(tagged, token, cancel).ConfigureAwait(false) is { } refused) throw new FleetKeyException(FleetKeyFailure.Refused, refused);
        return tagged;
    }

    /// <summary>The token as Tailscale makes one, or the reason it is not one. Nothing goes to Tailscale before this.</summary>
    public static string CheckedToken(string given)
    {
        var token = given.Trim();
        if (!token.StartsWith("tskey-api-", StringComparison.Ordinal) || token.Length > 256 || !FleetClient.Plain().IsMatch(token))
            throw new FleetKeyException(FleetKeyFailure.NotAnAccessToken);
        return token;
    }

    /// <summary>Whether another tool keeps the policy file, and where, as Tailscale names it.</summary>
    private async Task<(bool Managed, Uri? Link)> SettingsAsync(string token, CancellationToken cancel)
    {
        var data = await SendAsync("GET", "tailnet/-/settings", token, null, cancel).ConfigureAwait(false);
        if (Json.Parse(data) is not JsonObject settings) throw new FleetKeyException(FleetKeyFailure.NotUnderstood);
        var managed = Json.Bool(Json.At(settings, "aclsExternallyManagedOn")) ?? false;
        Uri? link = null;
        if (Json.String(Json.At(settings, "aclsExternalLink")) is { } written && Uri.TryCreate(written, UriKind.Absolute, out var parsed) &&
            parsed.Scheme == "https") link = parsed;
        return (managed, managed ? link : null);
    }

    /// <summary>The policy file as it stands, as the HuJSON the owner wrote, with the tag of the version that was read.</summary>
    private async Task<(string Text, string? ETag)> PolicyAsync(string token, CancellationToken cancel)
    {
        var answer = await ReachAsync("GET", Api + "/tailnet/-/acl", token, "application/hujson", null, null, null, cancel).ConfigureAwait(false);
        if (!answer.Ok) throw Failure(answer, token);
        return (answer.Text, answer.ETag);
    }

    /// <summary>Tailscale's own check of a file, which changes nothing: null for a file that it takes, else its words for
    /// why it would refuse it. Warnings alone are no refusal.</summary>
    private async Task<string?> CheckAsync(string text, string token, CancellationToken cancel)
    {
        var answer = await ReachAsync("POST", Api + "/tailnet/-/acl/validate", token, "application/json", Encoding.UTF8.GetBytes(text),
                                      "application/hujson", null, cancel).ConfigureAwait(false);
        if (!answer.Ok) throw Failure(answer, token);
        if (Json.Parse(answer.Body) is not JsonObject found || Json.String(Json.At(found, "message")) is not { Length: > 0 } message) return null;
        var data = AllObjects(Json.At(found, "data"));
        var errors = data.SelectMany(d => Json.AllStrings(Json.At(d, "errors")) ?? []).ToList();
        if (errors.Count == 0 && data.Any(d => Json.Has(d, "warnings"))) return null;
        return OneLine(Hidden(string.Join(": ", new[] { message }.Concat(errors.Take(1))), token));
    }

    /// <summary>Sets the file against the version that was read. False when somebody changed it since (412).</summary>
    private async Task<bool> SetAsync(string text, string etag, string token, CancellationToken cancel)
    {
        var answer = await ReachAsync("POST", Api + "/tailnet/-/acl", token, "application/json", Encoding.UTF8.GetBytes(text),
                                      "application/hujson", etag, cancel).ConfigureAwait(false);
        if (answer.Status == 412) return false;
        if (!answer.Ok) throw Failure(answer, token);
        return true;
    }

    /// <summary>Makes the fleet key and keeps it. A key this PC held before is replaced, and ended in Tailscale too; a
    /// key that the box will not keep is ended at once.</summary>
    private async Task MakeKeyAsync(string token, CancellationToken cancel)
    {
        var before = HeldClient();
        var body = new JsonObject
        {
            ["description"] = ClientDescription,
            ["keyType"] = "client",
            ["scopes"] = new JsonArray(Scopes.Select(s => (JsonNode?)s).ToArray()),
            ["tags"] = new JsonArray(Tag),
        };
        var data = await SendAsync("POST", "tailnet/-/keys", token, body, cancel).ConfigureAwait(false);
        var made = Json.Parse(data) as JsonObject;
        var id = Json.String(Json.At(made, "id")) ?? "";
        if (FleetClient.Of(id, Json.String(Json.At(made, "key")) ?? "") is not { } client)
        {
            if (FleetClient.IsId(id)) await EndAsync(id, token).ConfigureAwait(false);
            throw new FleetKeyException(FleetKeyFailure.NotUnderstood);
        }
        var stored = client.Stored;
        try { box.Write(ClientName, stored); }
        catch
        {
            await EndAsync(client.Id, token).ConfigureAwait(false);
            throw;
        }
        finally { CryptographicOperations.ZeroMemory(stored); }
        if (before is not null && before.Id != client.Id) await EndAsync(before.Id, token).ConfigureAwait(false);
    }

    /// <summary>Ends one credential in Tailscale. It is tidying, so a failure of it is no failure of the step it follows,
    /// and it runs to its end also when the step was cancelled.</summary>
    private async Task EndAsync(string id, string token)
    {
        try { await ReachAsync("DELETE", Api + "/tailnet/-/keys/" + id, token, "application/json", null, null, null, CancellationToken.None).ConfigureAwait(false); }
        catch (FleetKeyException) { }
    }

    // Each time: one key for one machine

    /// <summary>One key for one machine, from the fleet key (the Mac's <c>mintAuthKey</c>): single-use, pre-authorized,
    /// tagged with <see cref="Tag"/> (the only tag the fleet key may give), not ephemeral, and worthless after
    /// <paramref name="lifeSeconds"/>. The machine's name is in its description, so the owner reads in Tailscale what
    /// each key was for.</summary>
    public async Task<string> AuthKeyAsync(string hostname, int lifeSeconds = KeyLifeSeconds, CancellationToken cancel = default)
    {
        var client = HeldClient() ?? throw new FleetKeyException(FleetKeyFailure.NoFleetKey);
        var access = await AccessTokenAsync(client, cancel).ConfigureAwait(false);
        var body = new JsonObject
        {
            ["capabilities"] = new JsonObject
            {
                ["devices"] = new JsonObject
                {
                    ["create"] = new JsonObject
                    {
                        ["ephemeral"] = false, ["preauthorized"] = true, ["reusable"] = false, ["tags"] = new JsonArray(Tag),
                    },
                },
            },
            ["description"] = KeyDescription(hostname),
            ["expirySeconds"] = lifeSeconds,
        };
        var answer = await ReachAsync("POST", Api + "/tailnet/-/keys", access, "application/json", Json.Write(body), "application/json",
                                      null, cancel).ConfigureAwait(false);
        if (answer.Status == 401) throw new FleetKeyException(FleetKeyFailure.FleetKeyEnded);
        if (!answer.Ok) throw Refusal(answer, access);
        if (Json.String(Json.At(Json.Parse(answer.Body), "key")) is not { } key || !IsAuthKey(key))
            throw new FleetKeyException(FleetKeyFailure.NotUnderstood);
        return key;
    }

    /// <summary>**The machine that a server which this app made became in the owner's tailnet** (the Mac's
    /// <c>joined</c>): the newest authorized device that gave itself this name, carries the fleet's tag and was made
    /// since <paramref name="since"/> (five minutes of slack, for a clock that is off). Null when the list has none.</summary>
    public async Task<JoinedDevice?> JoinedAsync(string hostname, DateTimeOffset since, CancellationToken cancel = default)
    {
        var devices = await DeviceListAsync(cancel).ConfigureAwait(false);
        var wanted = hostname.ToLowerInvariant();
        if (wanted.Length == 0) return null;
        var found = new List<(DateTimeOffset Made, JoinedDevice Device)>();
        foreach (var device in devices)
        {
            if (Json.String(Json.At(device, "hostname"))?.ToLowerInvariant() != wanted || Json.Bool(Json.At(device, "authorized")) == false ||
                !(Json.AllStrings(Json.At(device, "tags")) ?? []).Contains(Tag) ||
                Time(Json.String(Json.At(device, "created"))) is not { } made || made < since.AddSeconds(-300)) continue;
            var name = (Json.String(Json.At(device, "name")) ?? "").ToLowerInvariant().Trim('.');
            var locked = (Json.String(Json.At(device, "tailnetLockError")) ?? "").Length > 0;
            found.Add((made, new JoinedDevice(name, Json.AllStrings(Json.At(device, "addresses")) ?? [], locked)));
        }
        return found.Count == 0 ? null : found.MaxBy(f => f.Made).Device;
    }

    /// <summary>**The devices of the owner's tailnet**, as Tailscale's own list gives them with the fleet key, for the one
    /// caller that removes a machine which this app made (Start again). A device with no id is left out.</summary>
    public async Task<IReadOnlyList<FleetDevice>> DevicesAsync(CancellationToken cancel = default)
    {
        var devices = await DeviceListAsync(cancel).ConfigureAwait(false);
        var found = new List<FleetDevice>();
        foreach (var device in devices)
        {
            // Tailscale prefers a device's nodeId in a path; its numeric id is the older form of the same.
            var id = new[] { Json.String(Json.At(device, "nodeId")), Json.String(Json.At(device, "id")) }
                .FirstOrDefault(i => i is not null && IsDeviceId(i));
            if (id is null) continue;
            found.Add(new FleetDevice(id, Json.String(Json.At(device, "hostname")) ?? "",
                                      (Json.String(Json.At(device, "name")) ?? "").ToLowerInvariant().Trim('.'),
                                      Json.AllStrings(Json.At(device, "addresses")) ?? [], Json.AllStrings(Json.At(device, "tags")) ?? [],
                                      Time(Json.String(Json.At(device, "created"))), Json.Bool(Json.At(device, "authorized")) != false,
                                      Json.Bool(Json.At(device, "isExternal")) == true,
                                      Json.Bool(Json.At(device, "connectedToControl")) == true));
        }
        return found;
    }

    /// <summary>**Removes one device from the tailnet by Tailscale's own id of it**, and nothing else: never a device by
    /// its name or its address. A device that Tailscale no longer has (404) is removed already.</summary>
    public async Task DeleteDeviceAsync(string id, CancellationToken cancel = default)
    {
        if (!IsDeviceId(id)) throw new FleetKeyException(FleetKeyFailure.NotUnderstood);
        var client = HeldClient() ?? throw new FleetKeyException(FleetKeyFailure.NoFleetKey);
        var access = await AccessTokenAsync(client, cancel).ConfigureAwait(false);
        var answer = await ReachAsync("DELETE", Api + "/device/" + id, access, "application/json", null, null, null, cancel).ConfigureAwait(false);
        if (answer.Status == 401) throw new FleetKeyException(FleetKeyFailure.FleetKeyEnded);
        if (!answer.Ok && answer.Status != 404) throw Refusal(answer, access);
    }

    private async Task<List<JsonObject>> DeviceListAsync(CancellationToken cancel)
    {
        var client = HeldClient() ?? throw new FleetKeyException(FleetKeyFailure.NoFleetKey);
        var access = await AccessTokenAsync(client, cancel).ConfigureAwait(false);
        var answer = await ReachAsync("GET", Api + "/tailnet/-/devices", access, "application/json", null, null, null, cancel).ConfigureAwait(false);
        if (answer.Status == 401) throw new FleetKeyException(FleetKeyFailure.FleetKeyEnded);
        if (!answer.Ok) throw Refusal(answer, access);
        if (Json.At(Json.Parse(answer.Body), "devices") is not JsonArray list || list.Any(d => d is not JsonObject))
            throw new FleetKeyException(FleetKeyFailure.NotUnderstood);
        return list.OfType<JsonObject>().ToList();
    }

    /// <summary>A device's id as it may stand in a path: ASCII letters and digits only, 1 to 64 of them.</summary>
    public static bool IsDeviceId(string id) => id.Length is >= 1 and <= 64 && id.All(char.IsAsciiLetterOrDigit);

    /// <summary>A time as Tailscale's API writes one ("2026-11-13T21:04:05Z", with or without fractions of a second).</summary>
    internal static DateTimeOffset? Time(string? text)
    {
        if (text is null || !TimeShape().IsMatch(text)) return null;
        return DateTimeOffset.TryParse(text, CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out var time) ? time : null;
    }

    /// <summary>A one-hour access token from the fleet key, by OAuth's client-credentials grant. Only the two statuses that
    /// OAuth gives a client that is no more (400 and 401) are read as that.</summary>
    private async Task<string> AccessTokenAsync(FleetClient client, CancellationToken cancel)
    {
        var form = "grant_type=client_credentials&client_id=" + FormValue(client.Id) + "&client_secret=" + FormValue(client.Secret);
        var body = Encoding.UTF8.GetBytes(form);
        ProviderAnswer answer;
        try
        {
            answer = await ExchangeAsync("POST", Api + "/oauth/token", [("Accept", "application/json")], body,
                                         "application/x-www-form-urlencoded", cancel).ConfigureAwait(false);
        }
        finally { CryptographicOperations.ZeroMemory(body); }
        if (answer.Status is 400 or 401) throw new FleetKeyException(FleetKeyFailure.FleetKeyEnded);
        if (!answer.Ok) throw Refusal(answer, client.Secret);
        if (Json.String(Json.At(Json.Parse(answer.Body), "access_token")) is not { Length: > 0 and <= 512 } token ||
            token.Contains('\n') || token.Contains('\r')) throw new FleetKeyException(FleetKeyFailure.NotUnderstood);
        return token;
    }

    /// <summary>The machine's name as Tailscale shows it beside the key: ASCII letters, digits and hyphens, in at most 50
    /// characters.</summary>
    public static string KeyDescription(string hostname)
    {
        var name = new string(hostname.Where(c => char.IsAsciiLetterOrDigit(c) || c == '-').ToArray());
        var said = "Founderizer " + (name.Length == 0 ? "server" : name);
        return said.Length <= 50 ? said : said[..50];
    }

    /// <summary>An auth key as Tailscale makes one: one line, and nothing of a shape this app would pass on by mistake.</summary>
    public static bool IsAuthKey(string key) =>
        key.StartsWith("tskey-auth-", StringComparison.Ordinal) && key.Length <= 512 && FleetClient.Plain().IsMatch(key);

    // The pieces

    private async Task<byte[]> SendAsync(string method, string path, string token, JsonObject? body, CancellationToken cancel)
    {
        var answer = await ReachAsync(method, Api + "/" + path, token, "application/json", body is null ? null : Json.Write(body),
                                      body is null ? null : "application/json", null, cancel).ConfigureAwait(false);
        if (!answer.Ok) throw Failure(answer, token);
        return answer.Body;
    }

    private Task<ProviderAnswer> ReachAsync(string method, string url, string token, string accept, byte[]? body, string? contentType,
                                            string? ifMatch, CancellationToken cancel)
    {
        var headers = new List<(string, string)> { ("Authorization", "Bearer " + token), ("Accept", accept) };
        if (ifMatch is not null) headers.Add(("If-Match", ifMatch));
        return ExchangeAsync(method, url, headers, body, contentType, cancel);
    }

    /// <summary>One exchange, with a connection that does not come up said as one. Every caller reads the status itself.</summary>
    private async Task<ProviderAnswer> ExchangeAsync(string method, string url, List<(string, string)> headers, byte[]? body,
                                                     string? contentType, CancellationToken cancel)
    {
        try { return await http.SendAsync(method, new Uri(url), headers, body, contentType, cancel).ConfigureAwait(false); }
        catch (ProviderUnreachableException) { throw new FleetKeyException(FleetKeyFailure.Unreachable); }
    }

    /// <summary>What a refusal of a request made with the owner's own token means: 401 is the token, 403 is the role.</summary>
    private static FleetKeyException Failure(ProviderAnswer answer, string secret) => answer.Status switch
    {
        401 => new FleetKeyException(FleetKeyFailure.TokenNotAccepted),
        403 => new FleetKeyException(FleetKeyFailure.RoleCannotWrite),
        _ => Refusal(answer, secret),
    };

    /// <summary>Any other refusal: 429 is Tailscale asking this PC to wait, and the rest is said in Tailscale's own words,
    /// in one line and with the secret taken out of them.</summary>
    private static FleetKeyException Refusal(ProviderAnswer answer, string secret)
    {
        if (answer.Status == 429) return new FleetKeyException(FleetKeyFailure.RateLimited);
        var says = answer.Text;
        if (Json.Parse(answer.Body) is JsonObject found)
            says = Json.String(Json.At(found, "message")) ?? Json.String(Json.At(found, "error_description")) ??
                   Json.String(Json.At(found, "error")) ?? says;
        says = OneLine(Hidden(says, secret));
        return new FleetKeyException(FleetKeyFailure.Refused,
                                     says.Length == 0 ? $"it answered {answer.Status} and said nothing." : says);
    }

    /// <summary>A text with a secret of at least eight characters taken out.</summary>
    internal static string Hidden(string text, string secret) =>
        secret.Length >= 8 ? text.Replace(secret, "(not shown)", StringComparison.Ordinal) : text;

    /// <summary>One line of at most 300 characters, as every refusal is said.</summary>
    internal static string OneLine(string text)
    {
        var says = text.Trim().Replace("\n", " ", StringComparison.Ordinal);
        var shown = new StringInfo(says);
        return shown.LengthInTextElements > 300 ? shown.SubstringByTextElements(0, 300) + "…" : says;
    }

    /// <summary>One form value: a credential has no character that needs escaping, and this makes sure of it.</summary>
    internal static string FormValue(string value)
    {
        var shown = new StringBuilder();
        foreach (var b in Encoding.UTF8.GetBytes(value))
        {
            if (b < 0x80 && (char.IsAsciiLetterOrDigit((char)b) || b is (byte)'-' or (byte)'.' or (byte)'_' or (byte)'~')) shown.Append((char)b);
            else shown.Append('%').Append(b.ToString("X2", CultureInfo.InvariantCulture));
        }
        return shown.ToString();
    }

    /// <summary>A list of objects, or none at all when one item is not an object (Swift's <c>as? [[String: Any]]</c>).</summary>
    private static List<JsonObject> AllObjects(JsonNode? node) =>
        node is JsonArray list && list.All(i => i is JsonObject) ? list.OfType<JsonObject>().ToList() : [];

    public override string ToString() => "TailscaleApi";

    [GeneratedRegex(@"\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})\z", RegexOptions.CultureInvariant)]
    private static partial Regex TimeShape();
}
