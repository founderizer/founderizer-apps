using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using Founderizer.Core;

namespace Founderizer.Owner.Vault;

/// <summary>The shapes of the vault's ids, each the Mac's rule (<c>LoginSecret.isReference</c>,
/// <c>CentralVault.isFleet</c>, <c>isMachine</c>, <c>program</c>, the agent of <c>SecretCommand.grant</c>).</summary>
public static partial class VaultIds
{
    /// <summary>A login reference in the hub's one spelling: <c>bws://&lt;uuid&gt;</c> in small letters.</summary>
    public static bool IsReference(string? text) => text is not null && Reference().IsMatch(text);

    /// <summary>A new reference, as the Mac's <c>bws://\(UUID().uuidString.lowercased())</c>.</summary>
    public static string NewReference() => "bws://" + Guid.NewGuid().ToString("D");

    /// <summary>A fleet's id, as the hub's <c>fleet_id()</c> writes it: 16 small hex characters.</summary>
    public static bool IsFleet(string? text) => text is not null && Fleet().IsMatch(text);

    /// <summary>A machine name that a pin can carry, which is the vault's own rule.</summary>
    public static bool IsMachine(string? text) => text is not null && Machine().IsMatch(text);

    /// <summary>The SHA-256 of a program, as the hub and the vault write it: 64 small hex characters.</summary>
    public static bool IsProgram(string? text) => text is not null && Program().IsMatch(text);

    /// <summary>An agent's name as a grant names it.</summary>
    public static bool IsAgent(string? text) => text is not null && Agent().IsMatch(text);

    /// <summary>An owner device's name (the Mac's <c>OwnerDevices.isName</c>): the shape of an agent's.</summary>
    public static bool IsDevice(string? text) => IsAgent(text);

    [GeneratedRegex(@"\Abws://[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}\z", RegexOptions.CultureInvariant)]
    private static partial Regex Reference();
    [GeneratedRegex(@"\A[0-9a-f]{16}\z", RegexOptions.CultureInvariant)]
    private static partial Regex Fleet();
    [GeneratedRegex(@"\A[a-z][a-z0-9-]{0,62}\z", RegexOptions.CultureInvariant)]
    private static partial Regex Machine();
    [GeneratedRegex(@"\A[0-9a-f]{64}\z", RegexOptions.CultureInvariant)]
    private static partial Regex Program();
    [GeneratedRegex(@"\A[a-z][a-z0-9-]{1,30}\z", RegexOptions.CultureInvariant)]
    private static partial Regex Agent();
}

/// <summary>Foundation's two sets that the Mac trims a field by, measured on macOS (vault-seal.json, <c>trims</c>):
/// <c>whitespacesAndNewlines</c> and <c>whitespaces</c>. Both hold U+200B, which .NET's own Trim leaves and which a copied
/// text can carry at its end.</summary>
internal static class FoundationText
{
    public static bool IsBlank(char c) =>
        c is '\t' or ' ' or '\u00A0' or '\u1680' or (>= '\u2000' and <= '\u200B') or '\u202F' or '\u205F' or '\u3000';

    /// <summary>A character that ends a line for Swift's <c>Character.isNewline</c>.</summary>
    public static bool IsNewline(char c) => c is (>= '\n' and <= '\r') or '\u0085' or '\u2028' or '\u2029';

    /// <summary><c>trimmingCharacters(in: .whitespacesAndNewlines)</c>.</summary>
    public static string Trim(string text) => Trim(text, c => IsBlank(c) || IsNewline(c));

    /// <summary><c>trimmingCharacters(in: .whitespaces)</c>.</summary>
    public static string TrimBlanks(string text) => Trim(text, IsBlank);

    private static string Trim(string text, Func<char, bool> goes)
    {
        int start = 0, end = text.Length;
        while (start < end && goes(text[start])) start++;
        while (end > start && goes(text[end - 1])) end--;
        return text[start..end];
    }
}

/// <summary>The parts of a web address that the vault's rules read, as Foundation's <c>URLComponents</c> gives them
/// (measured on macOS, vault-seal.json, <c>addresses</c>): the scheme as written, whether it has a user part, the host,
/// and the port. A character that no host can have makes no address; the path, the query and the fragment take any
/// character, which Foundation encodes by itself. Null for a text that is no address. **Stricter than Foundation**, so
/// that the form refuses the address: a bracketed host that is no IPv6 address, a port beyond 64 bits, and a host with a
/// character that Punycode's tables map away.</summary>
internal sealed partial record WebAddress(string? Scheme, bool HasUser, string? Host, string? AsciiHost, string? Port)
{
    public static WebAddress? Parse(string text)
    {
        string? scheme = null;
        var rest = text;
        var colon = text.IndexOf(':');
        if (colon > 0 && SchemeShape().IsMatch(text[..colon]))
        {
            scheme = text[..colon];
            rest = text[(colon + 1)..];
        }
        if (!rest.StartsWith("//", StringComparison.Ordinal)) return new WebAddress(scheme, false, null, null, null);
        var end = rest.AsSpan(2).IndexOfAny('/', '?', '#');
        var authority = end < 0 ? rest[2..] : rest.Substring(2, end);
        var at = authority.LastIndexOf('@');
        if (at >= 0) authority = authority[(at + 1)..];
        string host, port;
        if (authority.StartsWith('['))
        {
            var close = authority.IndexOf(']');
            if (close < 0 || !LiteralShape().IsMatch(authority[1..close])) return null;
            host = authority[..(close + 1)];
            if (authority.Length > close + 1 && authority[close + 1] != ':') return null;
            port = authority.Length > close + 1 ? authority[(close + 2)..] : "";
        }
        else
        {
            var mark = authority.IndexOf(':');
            host = mark < 0 ? authority : authority[..mark];
            port = mark < 0 ? "" : authority[(mark + 1)..];
            if (!IsHost(host)) return null;
        }
        if (port.AsSpan().IndexOfAnyExcept("0123456789") >= 0) return null;
        if (port.Length > 0)
        {
            if (!long.TryParse(port, NumberStyles.None, CultureInfo.InvariantCulture, out var number)) return null;
            port = number.ToString(CultureInfo.InvariantCulture);       // Foundation reads the port as a number
        }
        return new WebAddress(scheme, at >= 0, host.Contains('%') ? Uri.UnescapeDataString(host) : host,
                              host.All(char.IsAscii) ? host : null, port.Length > 0 ? port : null);
    }

    /// <summary>A host's characters: RFC 3986's, a percent escape, and letters, digits and marks beyond ASCII (a name that
    /// Foundation writes as Punycode).</summary>
    private static bool IsHost(string host)
    {
        for (var i = 0; i < host.Length;)
        {
            if (!Rune.TryGetRuneAt(host, i, out var rune)) return false;
            i += rune.Utf16SequenceLength;
            if (!rune.IsAscii)
            {
                if (!Rune.IsLetterOrDigit(rune) && Rune.GetUnicodeCategory(rune) is not
                        (UnicodeCategory.NonSpacingMark or UnicodeCategory.SpacingCombiningMark)) return false;
            }
            else if (rune.Value == '%')
            {
                if (i + 1 >= host.Length || !char.IsAsciiHexDigit(host[i]) || !char.IsAsciiHexDigit(host[i + 1])) return false;
            }
            else if (!Rune.IsLetterOrDigit(rune) && !"-._~!$&'()*+,;=".Contains((char)rune.Value))
            {
                return false;
            }
        }
        return true;
    }

    [GeneratedRegex(@"\A[A-Za-z][A-Za-z0-9+\-.]*\z", RegexOptions.CultureInvariant)]
    private static partial Regex SchemeShape();
    [GeneratedRegex(@"\A[0-9A-Fa-f:.]+(%25[A-Za-z0-9\-._~]+)?\z", RegexOptions.CultureInvariant)]
    private static partial Regex LiteralShape();
}

/// <summary>The two kinds of a secret, with the hub's words.</summary>
public enum SecretKind { Login, ApiKey }

public static class SecretKinds
{
    public static string Word(this SecretKind kind) => kind == SecretKind.ApiKey ? "api_key" : "login";
}

/// <summary>**One secret that the owner adds to the vault** (the Mac's <c>LoginSecret</c>, owner feature
/// <c>secrets</c>), of one of two kinds and without a name to type. A login: the address of its sign-in page, a user
/// name, a password and an optional authenticator seed; Fleet shows it as "host · user name". An API key: a variable name,
/// the key and an optional service address; Fleet shows it by its variable name. The vault item is the value that every
/// Fleet vault reads, <c>{username, password, url[, totp]}</c>. The rules are those of the vaults and no others: a password
/// has no length rule and no character rule, and it is kept exactly as typed. **It has no JSON form and prints as its
/// type's name on purpose**: a value must not reach a draft, the outbox or a log through a general encoder.
/// <see cref="Value"/> gives the item value for the seal, and nothing else reads the secret fields.</summary>
public sealed partial class LoginSecret
{
    public SecretKind Kind { get; set; } = SecretKind.Login;
    /// <summary>A login's sign-in page; an API key's service address, which it can be without.</summary>
    public string Url { get; set; } = "";
    /// <summary>A login's user name. An API key has none.</summary>
    public string Username { get; set; } = "";
    /// <summary>A login's password, or the API key.</summary>
    public string Password { get; set; } = "";
    /// <summary>An authenticator seed (base32) or an <c>otpauth://</c> address; empty for none. An API key has none.</summary>
    public string Totp { get; set; } = "";
    /// <summary>An API key's variable name, for example OPENAI_API_KEY. Fleet writes it in capital letters.</summary>
    public string Env { get; set; } = "";

    /// <summary>The longest item value this form takes: what still seals into a copy the hub carries.</summary>
    public static readonly int MaxValueBytes = AgeSeal.LongestSealed(AgeSeal.MaxCopy);
    /// <summary>The longest title of a login in the hub's catalog.</summary>
    public const int MaxLabel = 60;
    /// <summary>The most titles that the hub's catalog holds.</summary>
    public const int MaxCatalog = 256;

    // The Mac's sentences of the form, word for word (vault-seal.json holds them to FleetCore's English).
    public const string NoUserName = "Give the user name.";
    public const string NoPassword = "Give the password.";
    public const string NoAddress = "Give an address that starts with http:// or https://, with a host and no user name.";
    public const string NoSeed = "The authenticator seed can have only the letters A to Z and the digits 2 to 7, or be an otpauth:// address with such a secret.";
    public const string NoKey = "Give the key.";
    public const string NoServiceAddress = "Give a service address that starts with http:// or https://, with a host and no user name, or no address.";
    public const string NoFingerprint = "The central vault takes a value only with a fingerprint, and this one has none: it has fewer than 8 characters or holds white space. Nothing was sent.";
    public const string ProviderLogin = "This address is an AI provider's own sign-in site, and Founderizer Vault keeps no login for it: you sign in there with your own account. Nothing was sent.";
    public const string ProviderKey = "This service address is an AI provider's own sign-in site, and Founderizer Vault takes no key with it. Give the address of the service's API, or no service address. Nothing was sent.";
    public static string NoVariable(int most) => $"Give a variable name of 1 to {most} characters: the letters A to Z, the digits and _, with a letter first.";
    public static string ReservedName(string name) => $"{name} is a name that a session sets itself. Give another name.";
    public static string TooLong(int most) => $"This secret is too long: a vault's sealed copy takes at most {most} bytes.";

    private (string Username, string Url, string Totp, string Env) Trimmed =>
        (FoundationText.Trim(Username), FoundationText.Trim(Url), FoundationText.Trim(Totp), FoundationText.Trim(Env).ToUpperInvariant());

    /// <summary>The title: "host · user name" for a login, cut to the catalog's length; the variable name for an API key.</summary>
    public string Title
    {
        get
        {
            var fields = Trimmed;
            if (Kind != SecretKind.Login) return fields.Env;
            var full = $"{WebAddress.Parse(fields.Url)?.Host?.ToLowerInvariant() ?? fields.Url} · {fields.Username}";
            var runes = full.EnumerateRunes().ToList();
            return runes.Count <= MaxLabel ? full : string.Concat(runes.Take(MaxLabel - 1).Select(r => r.ToString())) + "…";
        }
    }

    /// <summary>The variable name of an API key, for the catalog; null for a login.</summary>
    public string? Variable => Kind == SecretKind.ApiKey ? Trimmed.Env : null;

    /// <summary>An API key's service address as the hub's table of well-known services reads it (owner feature
    /// <c>key_table</c>): only the scheme, the host and the port of an https address, because a path can be a secret.
    /// Null for a login, for a key with no address, and for an address that is not https. Null also for a host beyond
    /// ASCII, which the Mac sends as Punycode: no row of the table has one, so the hub reads both as no row.</summary>
    public string? TableAddress
    {
        get
        {
            var address = Trimmed.Url;
            if (Kind != SecretKind.ApiKey || !IsAddress(address) ||
                WebAddress.Parse(address) is not { Scheme: "https", AsciiHost: { } host } parts) return null;
            return "https://" + host + (parts.Port is { } port ? ":" + port : "");
        }
    }

    /// <summary>Why a vault cannot read this secret, or null, in the Mac's words. No text repeats a value.</summary>
    public string? Problem
    {
        get
        {
            var fields = Trimmed;
            switch (Kind)
            {
                case SecretKind.Login:
                    if (fields.Username.Length == 0) return NoUserName;
                    if (Password.Length == 0) return NoPassword;
                    if (!IsAddress(fields.Url)) return NoAddress;
                    if (fields.Totp.Length > 0 && !IsSeed(fields.Totp)) return NoSeed;
                    break;
                case SecretKind.ApiKey:
                    if (!IsVariable(fields.Env)) return NoVariable(MaxLabel);
                    if (IsReserved(fields.Env)) return ReservedName(fields.Env);
                    if (Password.Length == 0) return NoKey;
                    if (fields.Url.Length > 0 && !IsAddress(fields.Url)) return NoServiceAddress;
                    break;
            }
            byte[] line;
            try
            {
                line = Line(fields);
            }
            catch (ArgumentException)
            {
                return TooLong(MaxValueBytes);      // a lone surrogate: no UTF-8 holds it (the Mac's `try? line(fields)`)
            }
            try
            {
                return line.Length <= MaxValueBytes ? null : TooLong(MaxValueBytes);
            }
            finally
            {
                CryptographicOperations.ZeroMemory(line);
            }
        }
    }

    /// <summary>Why the central vault cannot take this secret although the form can make it, or null (the owner's choice
    /// C42): its value gets no fingerprint, so the hub registers none and refuses the intake; or its address is an AI
    /// provider's own sign-in site, which the vaults refuse. Null while <see cref="Problem"/> has a value.</summary>
    public string? VaultProblem
    {
        get
        {
            if (Problem is not null) return null;
            var value = Value();
            try
            {
                if (SecretFingerprint.Printable(value).Count == 0) return NoFingerprint;
            }
            finally
            {
                CryptographicOperations.ZeroMemory(value);
            }
            var address = Trimmed.Url;
            if (address.Length == 0 || WebAddress.Parse(address)?.Host is not { } host || !ProviderSites.Contains(host)) return null;
            return Kind == SecretKind.Login ? ProviderLogin : ProviderKey;
        }
    }

    /// <summary>The item value: one JSON object, for the seal only. The caller is its one holder, and clears it once it is
    /// sealed. Throws <see cref="InvalidOperationException"/> while <see cref="Problem"/> has a value.</summary>
    public byte[] Value() => Problem is null ? Line(Trimmed) : throw new InvalidOperationException("this secret has a problem");

    /// <summary>The item as the Mac's JSONSerialization writes it (its escapes are Python's, measured): the keys sorted, no
    /// white space, no escaped "/".</summary>
    private byte[] Line((string Username, string Url, string Totp, string Env) fields)
    {
        var text = new StringBuilder("{\"password\":").Append(CanonicalJson.Quote(Password));
        if (Kind == SecretKind.Login && fields.Totp.Length > 0) text.Append(",\"totp\":").Append(CanonicalJson.Quote(fields.Totp));
        if (Kind == SecretKind.Login || fields.Url.Length > 0) text.Append(",\"url\":").Append(CanonicalJson.Quote(fields.Url));
        text.Append(",\"username\":").Append(CanonicalJson.Quote(Kind == SecretKind.Login ? fields.Username : "")).Append('}');
        return Encoding.UTF8.GetBytes(text.ToString());
    }

    /// <summary>The same reading as the Mac vault: the scheme in small letters, a host, and no user part.</summary>
    internal static bool IsAddress(string text) =>
        WebAddress.Parse(text) is { Scheme: "https" or "http", Host.Length: > 0, HasUser: false };

    /// <summary>A variable name as the hub takes it: A to Z, the digits and _, a letter first, at most 60 characters.</summary>
    public static bool IsVariable(string text) => VariableShape().IsMatch(text);

    /// <summary>A name that the start of a session sets or that its runtime reads itself. The hub refuses it for an API key.</summary>
    public static bool IsReserved(string text) => ReservedShape().IsMatch(text);

    /// <summary>A seed that the vaults can make a code from: base32 letters and digits after the vaults' own clean-up (no
    /// white space, "-" or "="), or an <c>otpauth://</c> address with such a <c>secret</c>.</summary>
    internal static bool IsSeed(string value)
    {
        var seed = value;
        if (value.StartsWith("otpauth://", StringComparison.Ordinal))
        {
            var head = value.Split('#', 2)[0];
            var mark = head.IndexOf('?');
            seed = "";
            foreach (var pair in mark < 0 ? Array.Empty<string>() : head[(mark + 1)..].Split('&'))
            {
                var parts = pair.Split('=', 2);
                if (Decoded(parts[0]) != "secret") continue;
                seed = parts.Length > 1 ? Decoded(parts[1]) : "";
                break;
            }
        }
        var clean = seed.ToUpperInvariant().EnumerateRunes()
                        .Where(r => !(SecretFingerprint.IsWhitespace(r) || r.Value is '-' or '=')).ToList();
        return clean.Count > 0 && clean.All(r => r.Value is >= 'A' and <= 'Z' or >= '2' and <= '7');
    }

    /// <summary>A part of a query as Foundation's <c>queryItems</c> reads it, with "+" read as a space, as the Mac does first.</summary>
    private static string Decoded(string part) => Uri.UnescapeDataString(part.Replace('+', ' '));

    [GeneratedRegex(@"\A[A-Z][A-Z0-9_]{0,59}\z", RegexOptions.CultureInvariant)]
    private static partial Regex VariableShape();

    [GeneratedRegex(@"\A(?:(?:FLEET|BWS|LD|DYLD|ANTHROPIC|CLAUDE|CODEX)_[A-Z0-9_]*|PATH|HOME|SHELL|USER|LOGNAME|TMPDIR|TERM|PWD|IFS|ENV|BASH_ENV|ZDOTDIR|NODE_OPTIONS|PYTHONPATH|PYTHONHOME)\z",
                    RegexOptions.CultureInvariant)]
    private static partial Regex ReservedShape();
}

/// <summary>**The AI providers' own sign-in sites**, with their subdomains, and the key sites under them that stay
/// allowed: the Mac's copy of <c>vault.py</c> <c>PROVIDER_SITES</c> and <c>PROVIDER_KEY_SITES</c>, because the central
/// vault decides what it takes. <c>vault-seal.json</c> holds it to the Mac's copy, and the maker to the vault's.</summary>
public static class ProviderSites
{
    internal static readonly string[] Sites = ["claude.ai", "claude.com", "chatgpt.com", "auth.openai.com", "x.ai"];
    internal static readonly string[] KeySites = ["platform.claude.com", "api.x.ai"];

    /// <summary>True for a host of the sign-in sites or under one, and not of the key sites or under one, by
    /// <c>vault.py</c> <c>provider_site</c>: in any case, and with no dot at its end.</summary>
    public static bool Contains(string host)
    {
        var name = host.ToLowerInvariant().TrimEnd('.');
        bool Under(string site) => name == site || name.EndsWith("." + site, StringComparison.Ordinal);
        return !KeySites.Any(Under) && Sites.Any(Under);
    }
}

/// <summary>One agent's grant of one secret (feature <c>secret_grants</c>). <c>use</c>: the agent's vault uses the secret
/// for the agent, and the agent never sees it. <c>read</c>: an API key that the agent also reads, by its variable name, in
/// the environment of its sessions.</summary>
public enum SecretGrant { Use, Read }

public static class SecretGrants
{
    public static string Word(this SecretGrant grant) => grant == SecretGrant.Read ? "read" : "use";

    /// <summary>A level of the catalog's grants, or null for none and for a word that the app does not know.</summary>
    public static SecretGrant? Of(string? word) => word switch { "use" => SecretGrant.Use, "read" => SecretGrant.Read, _ => null };
}

/// <summary>One secret of the hub's catalog (<c>GET /ui/team</c> <c>logins</c>, the Mac's <c>TeamLogin</c>): its title,
/// its kind, an API key's variable name, and the agents that the owner gave it. A title gives no access.
/// <see cref="HasStore"/>: the key has a record in a cluster's store (the door's stage B). The PC has no door, so no form
/// here changes its value: a value that only the vault gets is not the value that the cluster's store has.</summary>
public sealed record CatalogEntry(string Title, string? Kind = null, string? Env = null,
                                  IReadOnlyDictionary<string, string>? Grants = null, string? Note = null, bool HasStore = false)
{
    public bool IsApiKey => Kind == "api_key";
    /// <summary>What Fleet shows: an API key by its variable name, a login by its title ("host · user name").</summary>
    public string Name => IsApiKey ? Env ?? Title : Title;

    /// <summary>The catalog of a <c>GET /ui/team</c> answer, by reference, or null when it gives none (a <c>logins</c> that is
    /// not there or null). A catalog that does not read as the Mac's fails as the Mac's read does: an entry that is no
    /// object with a title, or a field of another type.</summary>
    internal static Dictionary<string, CatalogEntry>? Read(JsonElement team)
    {
        if (Lossy.Field(team, "logins") is not { } logins) return null;
        if (logins.ValueKind != JsonValueKind.Object) throw new FormatException("the logins are not an object");
        var catalog = new Dictionary<string, CatalogEntry>(StringComparer.Ordinal);
        foreach (var entry in logins.EnumerateObject())
        {
            var value = entry.Value;
            var title = Text(value, "title") ?? throw new FormatException("an entry of the catalog has no title");
            if (Lossy.Field(value, "protected") is { ValueKind: not (JsonValueKind.True or JsonValueKind.False) })
                throw new FormatException("an entry's protected is not true or false");
            Dictionary<string, string>? grants = null;
            if (Lossy.Field(value, "grants") is { } given)
            {
                if (given.ValueKind != JsonValueKind.Object) throw new FormatException("an entry's grants are not an object");
                grants = new Dictionary<string, string>(StringComparer.Ordinal);
                foreach (var grant in given.EnumerateObject())
                    grants[grant.Name] = grant.Value.ValueKind == JsonValueKind.String
                        ? grant.Value.GetString()! : throw new FormatException("a grant is not a text");
            }
            catalog[entry.Name] = new CatalogEntry(title, Text(value, "kind"), Text(value, "env"), grants, Text(value, "note"),
                                                   Lossy.Field(value, "store") is not null);
        }
        return catalog;
    }

    private static string? Text(JsonElement value, string name) =>
        Lossy.Field(value, name) is not { } field ? null
        : field.ValueKind == JsonValueKind.String ? field.GetString()
        : throw new FormatException($"an entry's {name} is not a text");
}

/// <summary>**What the hub's catalog has under the name of a secret that a form saves** (the Mac's
/// <c>SecretNameHeld</c>). An API key is known by its variable name, among the API keys only: the list takes no second key
/// of one name (the owner, 13 November 2026: "having 2 keys named the same should not be possible"), so the one that is
/// there is the key whose value the save replaces. A login is known by its title, among all entries, and can stand two
/// times.</summary>
public abstract record SecretNameHeld
{
    /// <summary>Nothing of that name: a new secret.</summary>
    public sealed record None : SecretNameHeld;
    /// <summary>One API key of that variable name: the save replaces its value, under its own reference.</summary>
    public sealed record Key(string Reference, CatalogEntry Entry) : SecretNameHeld;
    /// <summary>Two or more API keys of that name, from before the list refused a second one.</summary>
    public sealed record Twice : SecretNameHeld;
    /// <summary>A login, and the list has that title: a second one.</summary>
    public sealed record Second : SecretNameHeld;

    /// <summary><paramref name="but"/>: the reference of the form's own save that the hub did not confirm, which is no
    /// other secret.</summary>
    public static SecretNameHeld Of(string title, SecretKind kind, IReadOnlyDictionary<string, CatalogEntry> catalog, string? but = null)
    {
        if (kind == SecretKind.ApiKey)
        {
            var keys = catalog.Where(e => e.Value.IsApiKey && e.Value.Name == title && e.Key != but)
                              .OrderBy(e => e.Key, StringComparer.Ordinal).ToList();
            return keys.Count == 0 ? new None() : keys.Count == 1 ? new Key(keys[0].Key, keys[0].Value) : new Twice();
        }
        return catalog.Any(e => e.Value.Name == title && e.Key != but) ? new Second() : new None();
    }
}

/// <summary>**"Who can use it" when a save replaces the value of a key** (the Mac's <c>SecretReplaceAccess</c>). The key
/// has its agents already, so the rows show each agent's level of now, and a level that the owner does not touch stays as
/// it is: only a row that he set himself, or that a request proposes, makes a step. A row that he sets to no access takes
/// the key back from that agent.</summary>
public static class SecretReplaceAccess
{
    /// <summary>The higher of two levels: reads it is more than uses it, and each is more than none.</summary>
    internal static SecretGrant? Higher(SecretGrant? one, SecretGrant? other) =>
        one == SecretGrant.Read || other == SecretGrant.Read ? SecretGrant.Read : one ?? other;

    private static SecretGrant? Held(IReadOnlyDictionary<string, string>? now, string agent) =>
        now is not null && now.TryGetValue(agent, out var word) ? SecretGrants.Of(word) : null;

    private static SecretGrant? At(IReadOnlyDictionary<string, SecretGrant> rows, string agent) =>
        rows.TryGetValue(agent, out var grant) ? grant : null;

    private static void Put(Dictionary<string, SecretGrant> rows, string agent, SecretGrant? grant)
    {
        if (grant is { } level) rows[agent] = level;
        else rows.Remove(agent);
    }

    /// <summary>The rows of the form at the Save that shows the line, and the agents whose row counts as set by the owner
    /// from then on. What was set before the levels were shown never takes a level down; <c>Raised</c> has his own pick for
    /// each row of his that shows a higher level than he picked, and it comes back (<see cref="Own"/>) when the name names
    /// this key no more.</summary>
    public static (Dictionary<string, SecretGrant> Rows, HashSet<string> Touched, Dictionary<string, SecretGrant> Raised) Rows(
        IReadOnlyDictionary<string, string>? now, IReadOnlyList<string> holders, IReadOnlyDictionary<string, SecretGrant> set,
        IReadOnlySet<string> touched, IReadOnlySet<string> proposed)
    {
        var rows = new Dictionary<string, SecretGrant>(set, StringComparer.Ordinal);
        var raised = new Dictionary<string, SecretGrant>(StringComparer.Ordinal);
        var kept = touched.Where(set.ContainsKey).ToHashSet(StringComparer.Ordinal);
        foreach (var agent in holders)
        {
            var held = Held(now, agent);
            Put(rows, agent, kept.Contains(agent) || proposed.Contains(agent) ? Higher(At(set, agent), held) : held);
            if (kept.Contains(agent) && At(set, agent) is { } pick && At(rows, agent) != pick) raised[agent] = pick;
        }
        return (rows, kept, raised);
    }

    /// <summary>The rows as the owner and the request set them, when the name is no longer the key's whose levels the rows
    /// show.</summary>
    public static Dictionary<string, SecretGrant> Own(IReadOnlyDictionary<string, SecretGrant> rows, IReadOnlyList<string> holders,
                                                      IReadOnlySet<string> touched, IReadOnlyDictionary<string, SecretGrant> raised,
                                                      IReadOnlyDictionary<string, SecretGrant> proposal, IReadOnlySet<string> proposed)
    {
        var own = new Dictionary<string, SecretGrant>(rows, StringComparer.Ordinal);
        foreach (var agent in holders)
        {
            if (!touched.Contains(agent)) Put(own, agent, proposed.Contains(agent) ? At(proposal, agent) : null);
            else if (At(raised, agent) is { } pick) own[agent] = pick;
        }
        return own;
    }

    /// <summary>The steps of the Save that replaces: one for each agent whose row is set to another level than its level of
    /// now, in the order of <paramref name="holders"/>; a null level takes the key back. A row that is not set makes no
    /// step, a proposal takes no level down, and a row of his that the form raised gives at most what he picked.</summary>
    public static IReadOnlyList<(string Agent, SecretGrant? Grant)> Changes(
        IReadOnlyDictionary<string, string>? now, IReadOnlyList<string> holders, IReadOnlyDictionary<string, SecretGrant> rows,
        IReadOnlySet<string> set, IReadOnlySet<string> proposed, IReadOnlyDictionary<string, SecretGrant> raised)
    {
        var steps = new List<(string, SecretGrant?)>();
        foreach (var agent in holders)
        {
            var held = Held(now, agent);
            if (set.Contains(agent) && !raised.ContainsKey(agent))
            {
                if (At(rows, agent) != held) steps.Add((agent, At(rows, agent)));
                continue;
            }
            if (!set.Contains(agent) && !proposed.Contains(agent)) continue;
            var wanted = Higher(At(raised, agent) ?? At(rows, agent), held);
            if (wanted != held) steps.Add((agent, wanted));
        }
        return steps;
    }
}

/// <summary>What one press of Replace does (<see cref="SecretValueReplace.Plan"/>).</summary>
public enum ReplacePlan
{
    /// <summary>The new value goes under the reference, with the entry's title and variable name, and no grant changes.</summary>
    Replace,
    /// <summary>The list has no API key of that reference and variable name any more: nothing is sent.</summary>
    Gone,
    /// <summary>The central vault does not replace a value yet, or this PC cannot sign the replace: nothing is sent.</summary>
    NotYet,
    /// <summary>The key has a record in a cluster's store, which this PC does not write: nothing is sent.</summary>
    InStore,
}

/// <summary>**A new value of a key that the list has, in one press** (the Mac's <c>SecretValueReplace</c>): Replace puts
/// the new value under the key's own reference, with the key's own title and variable name, and gives and takes no access,
/// so the same agents keep it.</summary>
public static partial class SecretValueReplace
{
    /// <summary>What one press of Replace does for the key of <paramref name="reference"/>, which the card shows as
    /// <paramref name="variable"/>, against the catalog that the press read. <paramref name="canReplace"/>: the hub has
    /// <c>secret_replace</c>, and this PC signs.</summary>
    public static (ReplacePlan Plan, CatalogEntry? Entry) Plan(string reference, string variable,
                                                               IReadOnlyDictionary<string, CatalogEntry> catalog, bool canReplace)
    {
        if (!catalog.TryGetValue(reference, out var entry) || !entry.IsApiKey || entry.Env != variable) return (ReplacePlan.Gone, null);
        if (entry.HasStore) return (ReplacePlan.InStore, null);
        return canReplace ? (ReplacePlan.Replace, entry) : (ReplacePlan.NotYet, null);
    }

    /// <summary>**The part "Value" stands for this secret**: an API key that he types. Never a GitHub App's key, which the
    /// app makes with GitHub, never an app's setting that the door keeps, and never a key of a cluster's store.</summary>
    public static bool Offered(CatalogEntry entry) =>
        entry.IsApiKey && !entry.HasStore && entry.Env is { } env && !GitHubAppKey().IsMatch(env) &&
        !env.StartsWith("DOOR_APP_", StringComparison.Ordinal);

    /// <summary>**A request for a new value sends no address**: the central vault puts the address of a new value in the
    /// place of the key's stored one, and keeps the stored one when the new value names none. So the request's
    /// <c>site</c>, an agent's word, would change where the key goes.</summary>
    public static string FormAddress(SecretRequest asked) => asked.Replaces is null ? asked.Site ?? "" : "";

    /// <summary>The item value of a new value in one press: the key, with no address, whatever the form holds.</summary>
    public static byte[] Value(LoginSecret login) =>
        new LoginSecret { Kind = login.Kind, Username = login.Username, Password = login.Password, Totp = login.Totp, Env = login.Env }.Value();

    /// <summary>**The requests that a new value of a key answers**: the form's own request first, then each other open
    /// request of an API key whose <c>replaces</c> names this key, in the hub's order. A null
    /// <paramref name="reference"/>: a save that replaces no key, which answers its own request alone.</summary>
    public static IReadOnlyList<long> Answers(long? own, string? reference, IReadOnlyList<OwnerNeed> needs)
    {
        var all = new List<long>();
        if (own is { } first) all.Add(first);
        if (reference is not null)
            all.AddRange(needs.Where(n => n.IsOpen && n.AsksForSecret && n.Id != own && SecretRequest.Of(n) is { } asked &&
                                          asked.Kind == SecretKind.ApiKey && asked.Replaces == reference).Select(n => n.Id));
        return all;
    }

    [GeneratedRegex(@"\AGITHUB_APP_[A-Z0-9_]{1,45}_KEY\z", RegexOptions.CultureInvariant)]
    private static partial Regex GitHubAppKey();
}

/// <summary>**What one secret request asks for**, with each field that the secure form takes (the Mac's
/// <c>NeedSecret</c>): an API key by its variable name, or a login for a sign-in page, the agents that the asker proposes,
/// the note and the account of a login, and the key whose value no longer works. It names a secret and never holds a
/// value. A field that does not read is left out rather than failing. (Step 1's <see cref="NeedSecret"/> of the device
/// routes reads what its card shows; this one reads the rest from the same item.)</summary>
public sealed record SecretRequest(SecretKind Kind, string? Env = null, string? Site = null,
                                   IReadOnlyDictionary<string, SecretGrant>? Give = null, string? Saved = null, string? Note = null,
                                   string? Account = null, string? Replaces = null, bool GivesNoForm = false)
{
    /// <summary>The hub's most for a note, for an account and for the owner's words about a request.</summary>
    public const int NoteMost = 200, AccountMost = 100, ClarifyMost = 2000;

    public IReadOnlyDictionary<string, SecretGrant> Proposal => Give ?? new Dictionary<string, SecretGrant>();

    /// <summary>The request of an item, or null for an item that asks for no secret. <see cref="GivesNoForm"/>: the request
    /// is for a key of a cluster's store or for a store's writer, which this PC does not set up (no door in step 2). Its card
    /// shows no field to fill, and never the form of a plain key, which no store would get.</summary>
    public static SecretRequest? Of(OwnerNeed need) =>
        need.AsksForSecret && need.RawSecret is { ValueKind: JsonValueKind.Object } value ? Read(value) : null;

    internal static SecretRequest Read(JsonElement value)
    {
        // The hub's own default: a request that names no kind asks for an API key.
        var kind = Lossy.Text(value, "kind") == "login" ? SecretKind.Login : SecretKind.ApiKey;
        var give = new Dictionary<string, SecretGrant>(StringComparer.Ordinal);
        if (Lossy.Field(value, "give") is { ValueKind: JsonValueKind.Object } given &&
            given.EnumerateObject().All(g => g.Value.ValueKind == JsonValueKind.String))
            foreach (var grant in given.EnumerateObject())
                if (SecretGrants.Of(grant.Value.GetString()) is { } level) give[grant.Name] = level;
        string? Kept(string name, Func<string, bool> holds) => Lossy.Text(value, name) is { } text && holds(text) ? text : null;
        return new SecretRequest(kind, Kept("env", LoginSecret.IsVariable), Kept("site", LoginSecret.IsAddress), give,
                                 Kept("saved", VaultIds.IsReference),
                                 Lossy.Text(value, "note") is { } note ? Line(note, NoteMost) : null,
                                 Lossy.Text(value, "account") is { } account ? Line(account, AccountMost) : null,
                                 kind == SecretKind.ApiKey ? Kept("replaces", VaultIds.IsReference) : null,
                                 Lossy.Field(value, "store") is not null || Lossy.Field(value, "store_writer") is not null);
    }

    /// <summary>One line of text of at most <paramref name="most"/> characters, or null.</summary>
    private static string? Line(string text, int most)
    {
        var words = FoundationText.TrimBlanks(text);
        return words.Length == 0 || NoteLength(words) > most || words.Any(FoundationText.IsNewline) ? null : words;
    }

    /// <summary>The length of a text as the hub counts it: its code points.</summary>
    public static int CodePoints(string text) => text.EnumerateRunes().Count();

    /// <summary>The length of a note, never less than the hub's count of it: the hub folds the wide and joined forms first
    /// (NFKC), which makes more code points of some characters, and then only takes characters away.</summary>
    public static int NoteLength(string text) => CodePoints(Normal(text, NormalizationForm.FormKC));

    /// <summary><paramref name="text"/> as one line of at most <paramref name="most"/> by the note's count: its line breaks
    /// are spaces, and what is over the most is cut at a whole character. What the card's Note field holds, and what goes to
    /// the hub.</summary>
    public static string OneLine(string text, int most)
    {
        var line = string.Join(' ', text.Split(['\n', '\v', '\f', '\r', '\u0085', '\u2028', '\u2029'], StringSplitOptions.RemoveEmptyEntries));
        return FoundationText.TrimBlanks(Cut(FoundationText.TrimBlanks(line), most, note: true));
    }

    /// <summary><paramref name="text"/> up to the last whole character that keeps it within <paramref name="most"/>, by the
    /// note's count or by code points.</summary>
    public static string Cut(string text, int most, bool note = false)
    {
        int count = 0, end = 0;
        var elements = StringInfo.GetTextElementEnumerator(text);
        while (elements.MoveNext())
        {
            var one = elements.GetTextElement();
            count += note ? NoteLength(one) : CodePoints(one);
            if (count > most) break;
            end = elements.ElementIndex + one.Length;
        }
        return text[..end];
    }

    /// <summary>**Whether <paramref name="words"/> hold <paramref name="value"/> as a word of its own**: a value of 8
    /// characters or more, with no letter or digit before or after it. What the form's Key or Password field holds must not
    /// go in a note or in a message; a short or common password inside a longer word is no such find.</summary>
    public static bool Holds(string value, string words)
    {
        value = Normal(FoundationText.Trim(value), NormalizationForm.FormC);      // as the vault keeps it, with no blank at an end
        words = Normal(words, NormalizationForm.FormC);
        if (new StringInfo(value).LengthInTextElements < 8) return false;
        for (var at = words.IndexOf(value, StringComparison.Ordinal); at >= 0; at = words.IndexOf(value, at + 1, StringComparison.Ordinal))
        {
            var before = at > 0 && Rune.DecodeLastFromUtf16(words.AsSpan(0, at), out var last, out _) == System.Buffers.OperationStatus.Done &&
                         (Rune.IsLetter(last) || Rune.IsNumber(last));
            var end = at + value.Length;
            var after = end < words.Length && Rune.DecodeFromUtf16(words.AsSpan(end), out var next, out _) == System.Buffers.OperationStatus.Done &&
                        (Rune.IsLetter(next) || Rune.IsNumber(next));
            if (!before && !after) return true;
        }
        return false;
    }

    private static string Normal(string text, NormalizationForm form)
    {
        try
        {
            return text.Normalize(form);
        }
        catch (ArgumentException)
        {
            return text;                // a lone surrogate: no form of it is any other text
        }
    }

    /// <summary>**Whether the request's note goes to a secret of the list that answers it**: only to one with no note of
    /// its own, and only to one of the account that the request names, by the user name in its title.</summary>
    public bool NoteGoes(CatalogEntry entry)
    {
        if (Note is null || !string.IsNullOrEmpty(entry.Note)) return false;
        if (string.IsNullOrEmpty(Account)) return true;
        var mark = entry.Title.IndexOf(" · ", StringComparison.Ordinal);
        return mark >= 0 && string.Equals(FoundationText.TrimBlanks(entry.Title[(mark + 3)..]), Account, StringComparison.OrdinalIgnoreCase);
    }

    /// <summary>Whether a saved secret's title fits this request: an API key by its variable name, a login by its host. A
    /// save that does not fit is never offered as its answer.</summary>
    public bool Fits(string title)
    {
        if (Kind == SecretKind.ApiKey) return Env is not null && title == Env;
        return Site is { } site && WebAddress.Parse(site)?.Host?.ToLowerInvariant() is { } host
            ? title.StartsWith(host + " · ", StringComparison.Ordinal) : title.Contains(" · ", StringComparison.Ordinal);
    }
}
