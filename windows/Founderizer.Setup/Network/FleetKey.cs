using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace Founderizer.Setup.Network;

/// <summary>The fleet key: the id and the secret of the OAuth client that this app made in the owner's tailnet (the
/// Mac's <c>FleetClient</c>). It is kept in the secret box as one line of each, and nothing that prints it shows the
/// secret.</summary>
public sealed partial class FleetClient
{
    public string Id { get; }
    internal string Secret { get; }

    private FleetClient(string id, string secret) { Id = id; Secret = secret; }

    /// <summary>The client, when both values have Tailscale's shapes.</summary>
    public static FleetClient? Of(string id, string secret) =>
        IsId(id) && secret.StartsWith("tskey-client-", StringComparison.Ordinal) && secret.Length <= 256 && Plain().IsMatch(secret)
            ? new FleetClient(id, secret) : null;

    /// <summary>The two values as one line each, for the box, and back.</summary>
    public static FleetClient? Of(byte[] stored)
    {
        var parts = Encoding.UTF8.GetString(stored).Split('\n');
        return parts.Length == 2 ? Of(parts[0], parts[1]) : null;
    }

    internal byte[] Stored => Encoding.UTF8.GetBytes(Id + "\n" + Secret);

    public static bool IsId(string id) => IdShape().IsMatch(id);

    public override string ToString() => $"FleetClient({Id}, secret not shown)";

    [GeneratedRegex(@"\A[A-Za-z0-9-]+\z", RegexOptions.CultureInvariant)]
    internal static partial Regex Plain();

    [GeneratedRegex(@"\A[A-Za-z0-9]{4,64}\z", RegexOptions.CultureInvariant)]
    private static partial Regex IdShape();
}

/// <summary>What <see cref="TailscaleApi.MakeFleetClientAsync"/> did, for the page that follows it (the Mac's
/// <c>FleetKeySetup</c>).</summary>
public sealed record FleetKeySetup(bool KeyMade, bool WrotePolicy, string? LinesToAdd, PolicyPlace Place)
{
    /// <summary>What the page says over <see cref="LinesToAdd"/>: what the file misses, and where the owner adds it.</summary>
    public string? Asks => LinesToAdd is null ? null : Place.TagAsk;
}

/// <summary>**Where the owner's Tailscale policy file is kept**, as Tailscale itself says it (the Mac's
/// <c>PolicyPlace</c>): Tailscale's Access controls page, or another tool, at an address when the tailnet names
/// one.</summary>
public sealed partial record PolicyPlace
{
    /// <summary>True when another tool keeps the file (GitOps, Terraform).</summary>
    public bool Tool { get; }
    /// <summary>The address of the other tool's file as the tailnet's settings name it (https only), or null.</summary>
    public Uri? Link { get; }

    private PolicyPlace(bool tool, Uri? link) { Tool = tool; Link = link; }

    public static readonly PolicyPlace Tailscale = new(false, null);
    public static PolicyPlace OfTool(Uri? link) => new(true, link is { Scheme: "https" } ? link : null);

    /// <summary>The other tool's address as the owner reads it: its host, port and path only, and none when it has
    /// anything but the plain characters of a host and a path, or is longer than 80 characters.</summary>
    public string? Address
    {
        get
        {
            if (!Tool || Link is null || string.IsNullOrEmpty(Link.Host)) return null;
            var path = Link.AbsolutePath;
            if (path.EndsWith('/')) path = path[..^1];
            var address = Link.Host + (Link.IsDefaultPort ? "" : ":" + Link.Port) + path;
            return address.Length <= 80 && AddressShape().IsMatch(address) ? address : null;
        }
    }

    /// <summary>The line over the tag's line on the key's page.</summary>
    public string TagAsk
    {
        get
        {
            const string tag = TailscaleApi.Tag;
            if (!Tool)
                return $"Your Tailscale policy has no {tag}. Add this line to tagOwners on the Access controls page of Tailscale, then paste a key again.";
            return Address is { } address
                ? $"Your Tailscale policy has no {tag}. Add this line to tagOwners in {address}, then paste a key again."
                : $"Your Tailscale policy has no {tag}. Add this line to tagOwners in the file of the tool that keeps your policy, then paste a key again.";
        }
    }

    /// <summary>The place as a line that a caller keeps (the Mac's <c>keep</c>): "tailscale", "tool" or "tool &lt;link&gt;".
    /// It is no secret: Tailscale shows the same address on its Access controls page.</summary>
    public string Kept => !Tool ? "tailscale" : Link is null ? "tool" : "tool " + Link.OriginalString;

    /// <summary>A kept line back; null for one of another form.</summary>
    public static PolicyPlace? FromKept(string? value)
    {
        if (value is null) return null;
        if (value == "tailscale") return Tailscale;
        if (value != "tool" && !value.StartsWith("tool ", StringComparison.Ordinal)) return null;
        return OfTool(value.Length > 5 && Uri.TryCreate(value[5..], UriKind.Absolute, out var link) ? link : null);
    }

    public override string ToString() => Kept;

    [GeneratedRegex(@"\A[A-Za-z0-9.-]+(:[0-9]+)?(/[A-Za-z0-9._~/-]*)?\z", RegexOptions.CultureInvariant)]
    private static partial Regex AddressShape();
}

/// <summary>One device of the owner's tailnet, as Tailscale's list of devices gives it (the Mac's
/// <c>FleetDevice</c>).</summary>
public sealed record FleetDevice(string Id, string Hostname, string Name, IReadOnlyList<string> Addresses,
                                 IReadOnlyList<string> Tags, DateTimeOffset? Created, bool Authorized, bool External,
                                 bool Connected);

/// <summary>A server of the fleet as the owner's tailnet lists it (the Mac's <c>JoinedDevice</c>): its full name there,
/// its addresses, and whether Tailnet Lock keeps it from its peers.</summary>
public sealed record JoinedDevice(string Name, IReadOnlyList<string> Addresses, bool Locked = false);

/// <summary>Why a step with Tailscale's API stopped (the Mac's <c>FleetKeyError</c>).</summary>
public enum FleetKeyFailure
{
    NotAnAccessToken, TokenNotAccepted, RoleCannotWrite, RateLimited, Unreachable, Refused, NotUnderstood,
    PolicyChangedMeanwhile, NoFleetKey, FleetKeyEnded,
}

/// <summary>A step with Tailscale's API that stopped, with the PC's words for it (the Mac's sentences with "PC" for
/// "Mac"). <see cref="Says"/> holds Tailscale's own words for a refusal, with every secret taken out.</summary>
public sealed class FleetKeyException(FleetKeyFailure failure, string? says = null)
    : Exception(Words(failure, says))
{
    public FleetKeyFailure Failure { get; } = failure;
    public string? Says { get; } = says;

    public static string Words(FleetKeyFailure failure, string? says) => failure switch
    {
        FleetKeyFailure.NotAnAccessToken => "This is not a Tailscale API access token. Make one on Tailscale's Keys page: it starts with tskey-api-.",
        FleetKeyFailure.TokenNotAccepted => "Tailscale did not accept this access token: it has expired or it was revoked. Make a new one on Tailscale's Keys page and paste it.",
        FleetKeyFailure.RoleCannotWrite => "Your role in Tailscale cannot make this change. Use an access token of an Owner or an Admin of the tailnet.",
        FleetKeyFailure.RateLimited => "Tailscale asks this PC to wait. Try again in a minute.",
        FleetKeyFailure.Unreachable => "Tailscale could not be reached. Check this PC's connection to the internet.",
        FleetKeyFailure.Refused => $"Tailscale refused: {says}",
        FleetKeyFailure.NotUnderstood => "Tailscale answered something this app does not understand.",
        FleetKeyFailure.PolicyChangedMeanwhile => "Your Tailscale policy file changed while this app was adding to it. Try again.",
        FleetKeyFailure.NoFleetKey => "This PC has no key to your Tailscale network yet. Connect Tailscale first.",
        FleetKeyFailure.FleetKeyEnded => "Tailscale no longer accepts this PC's key to your network: it was ended in Tailscale. Connect Tailscale again.",
        _ => "Tailscale answered something this app does not understand.",
    };
}

/// <summary>**The two connections that a server of a fleet needs on the owner's private network, and the line for one
/// that the policy does not let through** (the Mac's <c>FleetReach</c>): proved by the connections themselves, never by
/// a reading of the policy file.</summary>
public static class FleetReach
{
    /// <summary>**Whether the policy keeps this server from this PC**: the tailnet lists the server, and this PC's own
    /// Tailscale (its <c>tailscale status --json</c>) runs in that same tailnet, is online, and shows no device with
    /// the server's name or one of its addresses. Each other reason why this PC does not see it is not the
    /// policy's.</summary>
    public static bool Keeps(JoinedDevice device, string status)
    {
        if (device.Locked || device.Name.Length == 0) return false;
        var root = Json.Parse(status) as JsonObject;
        if (root is null || Json.String(Json.At(root, "BackendState")) != "Running" || Json.At(root, "Self") is not JsonObject own ||
            Json.Bool(Json.At(own, "Online")) != true) return false;
        static string Full(JsonNode node) => (Json.String(Json.At(node, "DNSName")) ?? "").ToLowerInvariant().Trim('.');
        static string Tailnet(string name) => name.IndexOf('.') is var dot and >= 0 ? name[(dot + 1)..] : "";
        if (Tailnet(device.Name).Length == 0 || Tailnet(Full(own)) != Tailnet(device.Name)) return false;
        var peers = Json.At(root, "Peer") is JsonObject peer ? peer.Select(p => p.Value).OfType<JsonObject>() : [];
        return !peers.Any(p => Full(p) == device.Name || Json.Strings(Json.At(p, "TailscaleIPs")).Intersect(device.Addresses).Any());
    }

    /// <summary>The server joined, and the policy keeps it from this PC (<see cref="Keeps"/>). A hub's line asks for the
    /// hub's port with SSH.</summary>
    public static string Hidden(string server, bool hub, PolicyPlace? place)
    {
        const string tag = TailscaleApi.Tag;
        var ports = hub ? "tcp:22, tcp:8765" : "tcp:22";
        if (place?.Address is { } address)
            return $"{server} is on your Tailscale network, but this PC cannot reach it. Change your Tailscale policy in {address} so that this PC reaches {tag} on {ports}.";
        if (place is { Tool: true })
            return $"{server} is on your Tailscale network, but this PC cannot reach it. Change your Tailscale policy, which another tool keeps, so that this PC reaches {tag} on {ports}.";
        return $"{server} is on your Tailscale network, but this PC cannot reach it. Change your Tailscale policy so that this PC reaches {tag} on {ports}.";
    }

    /// <summary>The server joined, and this PC's Tailscale does not show it online for another reason than the
    /// policy.</summary>
    public static string Unseen(string server) =>
        $"{server} is on your Tailscale network, but Tailscale on this PC does not show it online. Check that Tailscale on this PC is connected to the same network.";

    /// <summary>A server did not answer SSH at its address on the private network, on which the policy decides what
    /// arrives (the words of the Mac's <c>unreached</c>; the PC knows it from <c>RemoteFailure.NoAnswer</c>, not from
    /// the words of <c>ssh</c>).</summary>
    public static string Unreached(string server, string port, PolicyPlace? place)
    {
        var ports = "tcp:" + port;
        if (place?.Address is { } address)
            return $"{server} did not answer SSH on port {port}. Check that the server is on, and that your Tailscale policy in {address} lets this PC reach it on {ports}.";
        if (place is { Tool: true })
            return $"{server} did not answer SSH on port {port}. Check that the server is on, and that your Tailscale policy, which another tool keeps, lets this PC reach it on {ports}.";
        return $"{server} did not answer SSH on port {port}. Check that the server is on, and that your Tailscale policy lets this PC reach it on {ports}.";
    }
}

/// <summary>**The tailnet policy file, as far as the fleet needs it** (the Mac's <c>FleetPolicy</c>): what it misses,
/// and the same file with those lines in it, for a file that this app may write. The file is HuJSON (JSON with comments
/// and trailing commas) and holds the owner's own rules, so it is read whole only to understand it, and changed only by
/// inserting bytes into it: every byte the owner wrote stays where it was.</summary>
public static class FleetPolicy
{
    /// <summary>One grant the fleet needs.</summary>
    public sealed record Grant(IReadOnlyList<string> Src, IReadOnlyList<string> Dst, IReadOnlyList<string> Ip)
    {
        /// <summary>As it stands in the file, on one line.</summary>
        public string Text
        {
            get
            {
                static string List(IReadOnlyList<string> values) => "[" + string.Join(", ", values.Select(v => "\"" + v + "\"")) + "]";
                return "{\"src\": " + List(Src) + ", \"dst\": " + List(Dst) + ", \"ip\": " + List(Ip) + "}";
            }
        }
    }

    /// <summary>What one file misses of what the fleet needs: the tag in <c>tagOwners</c>, and the grants that no grant
    /// of the file covers.</summary>
    public sealed record Needs(bool Tag, IReadOnlyList<Grant> Grants)
    {
        public bool IsEmpty => !Tag && Grants.Count == 0;
    }

    /// <summary>The tag, owned by the tailnet's admins, who are the people that can make the fleet key.</summary>
    public static readonly string TagLine = "\"" + TailscaleApi.Tag + "\": [\"autogroup:admin\"]";

    /// <summary>What the fleet uses, and no more: the owner's devices reach its machines on SSH, the hub's port and the
    /// port of the fleet's code; its machines reach the hub on its port and on the port of the code.</summary>
    public static readonly IReadOnlyList<Grant> Grants =
    [
        new(TailscaleApi.Owners, [TailscaleApi.Tag], TailscaleApi.Ports),
        new([TailscaleApi.Tag], [TailscaleApi.Tag], TailscaleApi.HubPorts),
    ];

    /// <summary>What the file misses, or null when this app cannot read it (also a file that names <c>tagOwners</c>
    /// twice).</summary>
    public static Needs? NeedsIn(string text)
    {
        var bytes = Encoding.UTF8.GetBytes(text);
        if (Scan(bytes) is { } found && found.Twice.Contains("tagowners")) return null;
        return Parsed(bytes) is { } policy ? NeedsOf(policy) : null;
    }

    /// <summary>Keys of the policy are read as Tailscale reads them, whatever their case.</summary>
    internal static Needs NeedsOf(Dictionary<string, JsonNode?> policy)
    {
        var members = Lowered(policy);
        var owners = members.TryGetValue("tagowners", out var o) && o is JsonObject ownersObject ? ownersObject : null;
        var tag = owners is null || !owners.Any(p => p.Key.ToLowerInvariant() == TailscaleApi.Tag);
        if (AllowsAll(members)) return new Needs(tag, []);
        var existing = Objects(members.GetValueOrDefault("grants"));
        return new Needs(tag, Grants.Where(grant => !existing.Any(e => Covers(e, grant))).ToList());
    }

    /// <summary>Whether the file lets every device reach every other on every port: a file with neither <c>acls</c> nor
    /// <c>grants</c>, an accept from <c>*</c> to <c>*:*</c>, or a grant from <c>*</c> to <c>*</c> on <c>*</c>. A rule
    /// narrowed by a protocol, a posture or a route is not all.</summary>
    internal static bool AllowsAll(Dictionary<string, JsonNode?> members)
    {
        var acls = members.GetValueOrDefault("acls");
        var granted = members.GetValueOrDefault("grants");
        if (acls is null && granted is null) return true;
        if (Objects(acls).Any(rule =>
                Json.String(rule.GetValueOrDefault("action"))?.ToLowerInvariant() == "accept" && !rule.ContainsKey("proto") &&
                !rule.ContainsKey("srcposture") &&
                Strings(rule.GetValueOrDefault("src")).Concat(Strings(rule.GetValueOrDefault("users"))).Contains("*") &&
                Strings(rule.GetValueOrDefault("dst")).Concat(Strings(rule.GetValueOrDefault("ports"))).Contains("*:*")))
            return true;
        return Objects(granted).Any(grant =>
            !grant.ContainsKey("srcposture") && !grant.ContainsKey("via") && Strings(grant.GetValueOrDefault("src")).Contains("*") &&
            Strings(grant.GetValueOrDefault("dst")).Contains("*") && Strings(grant.GetValueOrDefault("ip")).Contains("*"));
    }

    /// <summary>Whether a grant of the file already gives all of what <paramref name="grant"/> gives.</summary>
    internal static bool Covers(Dictionary<string, JsonNode?> other, Grant grant)
    {
        var src = Strings(other.GetValueOrDefault("src"));
        var dst = Strings(other.GetValueOrDefault("dst"));
        var ip = Strings(other.GetValueOrDefault("ip"));
        return !other.ContainsKey("srcposture") && !other.ContainsKey("via")
            && (src.Contains("*") || grant.Src.All(src.Contains))
            && (dst.Contains("*") || grant.Dst.All(dst.Contains))
            && grant.Ip.All(port => ip.Contains("*") || ip.Contains("tcp:*") || ip.Contains(port) || ip.Contains(port[4..]));
    }

    /// <summary>The file with what it misses inserted, and every byte it had still in it, in order; null when this app
    /// cannot see where the lines belong, when a section that it writes into is named twice, or when the result read
    /// again still misses a line of <paramref name="needs"/>.</summary>
    public static string? Writing(Needs needs, string text)
    {
        var bytes = new List<byte>(Encoding.UTF8.GetBytes(text));
        if (needs.IsEmpty || Scan(bytes.ToArray()) is not { } found) return null;
        if ((needs.Tag && found.Twice.Contains("tagowners")) || (needs.Grants.Count > 0 && found.Twice.Contains("grants"))) return null;
        var inserts = new List<(int At, string Text)>();
        var atRoot = "";
        if (needs.Tag)
        {
            var line = "\n\t\t" + TagLine + ",";
            if (!found.Members.TryGetValue("tagowners", out var member)) atRoot += "\n\t\"tagOwners\": {" + line + "\n\t},";
            else if (member.Opener == (byte)'{') inserts.Add((member.At, line));
            else return null;
        }
        if (needs.Grants.Count > 0)
        {
            var lines = string.Concat(needs.Grants.Select(g => "\n\t\t" + g.Text + ","));
            if (!found.Members.TryGetValue("grants", out var member)) atRoot += "\n\t\"grants\": [" + lines + "\n\t],";
            else if (member.Opener == (byte)'[') inserts.Add((member.At, lines));
            else return null;
        }
        if (atRoot.Length > 0) inserts.Add((found.Root, atRoot));
        foreach (var insert in inserts.OrderByDescending(i => i.At))
            bytes.InsertRange(insert.At, Encoding.UTF8.GetBytes(insert.Text));
        var written = bytes.ToArray();
        if (Parsed(written) is not { } policy) return null;
        var left = NeedsOf(policy);
        if ((needs.Tag && left.Tag) || needs.Grants.Any(left.Grants.Contains)) return null;
        return Encoding.UTF8.GetString(written);
    }

    // Reading HuJSON

    /// <summary>The file as one object, read the way Tailscale reads it, or null.</summary>
    internal static Dictionary<string, JsonNode?>? Parsed(byte[] text)
    {
        if (Standardized(text) is not { } json) return null;
        if (Json.Parse(json) is not JsonObject root) return null;
        var members = new Dictionary<string, JsonNode?>(StringComparer.Ordinal);
        foreach (var (key, value) in root) members[key] = value;
        return members;
    }

    /// <summary>The file as plain JSON, for reading only: comments out, and a comma that only a closing bracket follows
    /// out. Null when a string or a block comment never ends.</summary>
    internal static byte[]? Standardized(byte[] bytes)
    {
        var output = new List<byte>(bytes.Length);
        var comma = false;
        var ended = Walk(bytes, token =>
        {
            switch (token.Kind)
            {
                case TokenKind.Comment: break;
                case TokenKind.String:
                    if (comma) { output.Add((byte)','); comma = false; }
                    for (var i = token.Start; i < token.End; i++) output.Add(bytes[i]);
                    break;
                default:
                    var b = bytes[token.Start];
                    if (b == (byte)',')
                    {
                        if (comma) output.Add(b);
                        comma = true;
                    }
                    else if (b is (byte)']' or (byte)'}')
                    {
                        comma = false;
                        output.Add(b);
                    }
                    else if (IsSpace(b)) output.Add(b);
                    else
                    {
                        if (comma) { output.Add((byte)','); comma = false; }
                        output.Add(b);
                    }
                    break;
            }
        });
        if (comma) output.Add((byte)',');
        return ended ? output.ToArray() : null;
    }

    internal sealed record Found(int Root, Dictionary<string, (int At, byte Opener)> Members, HashSet<string> Twice);

    /// <summary>One pass outside every string and comment: where the file's object opens (just after its <c>{</c>),
    /// and where the value of each of that object's own members starts (just after its first byte), by the member's
    /// name in lower case; the members named more than once.</summary>
    internal static Found? Scan(byte[] bytes)
    {
        var depth = 0;
        int? root = null;
        var members = new Dictionary<string, (int At, byte Opener)>(StringComparer.Ordinal);
        var twice = new HashSet<string>(StringComparer.Ordinal);
        string? key = null;
        string? named = null;
        var ended = Walk(bytes, token =>
        {
            switch (token.Kind)
            {
                case TokenKind.Comment: break;
                case TokenKind.String:
                    if (named is { } name)
                    {
                        if (!members.ContainsKey(name)) members[name] = (token.Start + 1, (byte)'"');
                        else twice.Add(name);
                        named = null;
                        key = null;
                    }
                    else
                    {
                        key = depth == 1
                            ? Encoding.UTF8.GetString(bytes, token.Start + 1, token.End - token.Start - 2).ToLowerInvariant()
                            : null;
                    }
                    break;
                default:
                    var b = bytes[token.Start];
                    if (IsSpace(b)) return;
                    if (named is { } member)
                    {
                        if (!members.ContainsKey(member)) members[member] = (token.Start + 1, b);
                        else twice.Add(member);
                        named = null;
                    }
                    switch (b)
                    {
                        case (byte)':': named = depth == 1 ? key : null; break;
                        case (byte)'{' or (byte)'[':
                            depth += 1;
                            if (depth == 1 && b == (byte)'{' && root is null) root = token.Start + 1;
                            break;
                        case (byte)'}' or (byte)']': depth -= 1; break;
                    }
                    key = null;
                    break;
            }
        });
        return ended && depth == 0 && root is { } at ? new Found(at, members, twice) : null;
    }

    internal enum TokenKind { String, Comment, Byte }
    internal readonly record struct Token(TokenKind Kind, int Start, int End);

    /// <summary>Walks the file once: a string or a comment whole, everything else one byte at a time. False when a string
    /// or a block comment never ends.</summary>
    internal static bool Walk(byte[] bytes, Action<Token> visit)
    {
        var index = 0;
        while (index < bytes.Length)
        {
            var next = index + 1 < bytes.Length ? bytes[index + 1] : (byte)0;
            if (bytes[index] == (byte)'"')
            {
                var end = index + 1;
                while (end < bytes.Length && bytes[end] != (byte)'"') end += bytes[end] == (byte)'\\' ? 2 : 1;
                if (end >= bytes.Length) return false;
                visit(new Token(TokenKind.String, index, end + 1));
                index = end + 1;
            }
            else if (bytes[index] == (byte)'/' && next == (byte)'/')
            {
                while (index < bytes.Length && bytes[index] != (byte)'\n') index += 1;
                visit(new Token(TokenKind.Comment, index, index));
            }
            else if (bytes[index] == (byte)'/' && next == (byte)'*')
            {
                var end = index + 2;
                while (end + 1 < bytes.Length && !(bytes[end] == (byte)'*' && bytes[end + 1] == (byte)'/')) end += 1;
                if (end + 1 >= bytes.Length) return false;
                visit(new Token(TokenKind.Comment, index, end + 2));
                index = end + 2;
            }
            else
            {
                visit(new Token(TokenKind.Byte, index, index + 1));
                index += 1;
            }
        }
        return true;
    }

    internal static bool IsSpace(byte b) => b is (byte)' ' or (byte)'\t' or (byte)'\n' or (byte)'\r';

    internal static Dictionary<string, JsonNode?> Lowered(IEnumerable<KeyValuePair<string, JsonNode?>> members)
    {
        var lowered = new Dictionary<string, JsonNode?>(StringComparer.Ordinal);
        foreach (var (key, value) in members) lowered.TryAdd(key.ToLowerInvariant(), value);
        return lowered;
    }

    internal static List<Dictionary<string, JsonNode?>> Objects(JsonNode? value) =>
        Json.Objects(value).Select(o => Lowered(o)).ToList();

    internal static List<string> Strings(JsonNode? value) => Json.Strings(value).Select(s => s.ToLowerInvariant()).ToList();
}
