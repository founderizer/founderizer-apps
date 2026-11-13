using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.Json;
using Org.BouncyCastle.Math.EC.Rfc8032;

namespace Founderizer.Core;

/// <summary>A release that this app will not act on, with the one line that it says to the owner.</summary>
public sealed class ReleaseUntrusted(string says) : Exception(says);

/// <summary>Ed25519 as releases.verify_signature checks it: a 32-byte key of the prime-order subgroup that is not the
/// identity, a 64-byte signature with S below L, and the RFC 8032 equation. BouncyCastle does the arithmetic (.NET 10
/// has no Ed25519, windows-app-plan.md section 4).</summary>
public static class Ed25519Check
{
    public static bool Verify(ReadOnlySpan<byte> publicKey, ReadOnlySpan<byte> message, ReadOnlySpan<byte> signature)
    {
        if (publicKey.Length != Ed25519.PublicKeySize || signature.Length != Ed25519.SignatureSize) return false;
        // The full check of the key: on the curve, in the prime-order subgroup and not of small order, which
        // releases._usable_key asks and RFC 8032 does not.
        if (!Ed25519.ValidatePublicKeyFull(publicKey)) return false;
        return Ed25519.Verify(signature, publicKey, message);
    }

    /// <summary>True when one of <paramref name="keys"/> signed <paramref name="message"/> (releases.signed_by_any).</summary>
    public static bool SignedByAny(IEnumerable<byte[]> keys, ReadOnlySpan<byte> message, ReadOnlySpan<byte> signature)
    {
        foreach (var key in keys) if (Verify(key, message, signature)) return true;
        return false;
    }
}

/// <summary>The release keys of one key file's text, as releases.parse_keys and AppUpdate.keys read it: lines that start
/// with # are for the reader, one to four keys, and one line that is not a 32-byte key makes the whole text carry none,
/// because a key file that is half read is a mistake.</summary>
public static class ReleaseKeys
{
    public const int Most = 4;

    public static IReadOnlyList<byte[]> Parse(string? text)
    {
        var lines = new List<string>();
        foreach (var line in (text ?? "").Split('\n'))
        {
            var trimmed = line.Trim();
            if (trimmed.Length > 0 && !trimmed.StartsWith('#')) lines.Add(trimmed);
        }
        if (lines.Count is 0 or > Most) return [];
        var keys = new List<byte[]>();
        foreach (var line in lines)
        {
            if (!TryBase64(line, out var key) || key.Length != 32) return [];
            keys.Add(key);
        }
        return keys;
    }

    private static bool TryBase64(string text, out byte[] bytes)
    {
        bytes = [];
        if (text.Length % 4 != 0) return false;
        foreach (var c in text)
            if (!(c is >= 'A' and <= 'Z' or >= 'a' and <= 'z' or >= '0' and <= '9' or '+' or '/' or '=')) return false;
        try { bytes = Convert.FromBase64String(text); return true; }
        catch (FormatException) { return false; }
    }
}

/// <summary>What the channel says the newest build of the app is (FleetCore's AppManifest), after its signature was
/// checked. Every field is checked before the signature is computed over it, because the signed text is built from these
/// bytes: a field with a newline could otherwise be split into two fields on the way.</summary>
public sealed record AppManifest(string Version, long Build, string Url, string Sha256, long Size, string? MinimumSystem,
                                 string? Notes, bool Hold, string Signature)
{
    /// <summary>The first line of a build's signed text. A fleet release is `founderizer-release-1`, so neither message
    /// can be replayed as the other.</summary>
    public const string SignedPrefix = "founderizer-app-1";
    public const long MaximumDownload = 600L * 1024 * 1024;
    public const int AnswerLimit = 64 * 1024;

    /// <summary>The exact bytes that a build's signature covers (AppUpdate.signedText, autopublish.app_text).</summary>
    public byte[] SignedText() => Encoding.UTF8.GetBytes(string.Join('\n', [
        SignedPrefix, Version, Build.ToString(CultureInfo.InvariantCulture), Url, Sha256,
        Size.ToString(CultureInfo.InvariantCulture), MinimumSystem ?? "", Notes ?? "", Hold ? "true" : "false",
    ]) + "\n");

    /// <summary>The manifest of the channel's answer, field by field (AppUpdate.readManifest). It trusts no character of
    /// what it reads. Stricter than the Swift reader in two places: `hold` must be JSON true or false (Swift also takes
    /// the numbers 0 and 1), and `build` and `size` must be JSON whole numbers (Swift also reads true as 1).</summary>
    public static AppManifest Read(ReadOnlySpan<byte> data, string channel)
    {
        if (data.Length > AnswerLimit) throw new ReleaseUntrusted("The channel did not answer with a build this app could read.");
        JsonDocument document;
        try
        {
            document = JsonDocument.Parse(data.ToArray());
        }
        catch (JsonException)
        {
            throw new ReleaseUntrusted("The channel did not answer with a build this app could read.");
        }
        using (document)
        {
            var raw = document.RootElement;
            if (raw.ValueKind != JsonValueKind.Object)
                throw new ReleaseUntrusted("The channel did not answer with a build this app could read.");
            var version = Text(raw, "version");
            if (version is null || !Patterns.Version().IsMatch(version))
                throw new ReleaseUntrusted("The channel's answer has no version name.");
            if (Whole(raw, "build") is not { } build || build is < 1 or > 2_000_000_000)
                throw new ReleaseUntrusted("The channel's answer has no build number.");
            var url = Text(raw, "url");
            if (url is null || Encoding.UTF8.GetByteCount(url) > 400 || !IsOurs(url, channel) ||
                !Path.GetExtension(new Uri(url).AbsolutePath).Equals(".zip", StringComparison.OrdinalIgnoreCase))
                throw new ReleaseUntrusted("The channel's answer points the download somewhere that is not ours.");
            var sha256 = Text(raw, "sha256");
            if (sha256 is null || !Patterns.Sha256Hex().IsMatch(sha256))
                throw new ReleaseUntrusted("The channel's answer carries no checksum for the download.");
            if (Whole(raw, "size") is not { } size || size is < 1 or > MaximumDownload)
                throw new ReleaseUntrusted("The channel's answer gives the download no believable size.");
            var minimum = Text(raw, "minimum");
            if (!string.IsNullOrEmpty(minimum) && !Patterns.SystemVersion().IsMatch(minimum))
                throw new ReleaseUntrusted("The channel's answer names a system version this app cannot read.");
            var notes = Text(raw, "notes");
            if (!string.IsNullOrEmpty(notes) && !IsOurs(notes, channel))
                throw new ReleaseUntrusted("The channel's answer points its notes somewhere that is not ours.");
            var hold = false;
            if (raw.TryGetProperty("hold", out var held))
            {
                if (held.ValueKind is not (JsonValueKind.True or JsonValueKind.False))
                    throw new ReleaseUntrusted("The channel's answer does not say whether this build is held.");
                hold = held.GetBoolean();
            }
            var signature = Text(raw, "signature");
            if (signature is null || Encoding.UTF8.GetByteCount(signature) is < 1 or > 200)
                throw new ReleaseUntrusted("The channel's answer carries no signature.");
            return new AppManifest(version, build, url, sha256, size, string.IsNullOrEmpty(minimum) ? null : minimum,
                                   string.IsNullOrEmpty(notes) ? null : notes, hold, signature);
        }
    }

    /// <summary>The manifest that this app may act on, or <see cref="ReleaseUntrusted"/> (AppUpdate.check). Nothing else
    /// here reads an unchecked manifest.</summary>
    public static AppManifest Check(ReadOnlySpan<byte> data, IReadOnlyList<byte[]> keys, string channel)
    {
        var manifest = Read(data, channel);
        if (keys.Count == 0)
            throw new ReleaseUntrusted("This build of Founderizer carries no release key, so it refuses every update. " +
                                       "That is the safe state: an app that cannot check an update takes none.");
        if (!Base64Strict.TryDecode(manifest.Signature, out var signature) || signature.Length != 64)
            throw new ReleaseUntrusted("The channel's signature is not a signature.");
        if (!Ed25519Check.SignedByAny(keys, manifest.SignedText(), signature))
            throw new ReleaseUntrusted("This build is not signed by the release key Founderizer ships with. " +
                                       "Nothing was downloaded.");
        return manifest;
    }

    /// <summary>An address of ours: HTTPS, the channel's own host, and no credentials in it.</summary>
    public static bool IsOurs(string link, string channel) =>
        Uri.TryCreate(link, UriKind.Absolute, out var uri) && uri.Scheme == "https" && uri.UserInfo.Length == 0 &&
        Uri.TryCreate(channel, UriKind.Absolute, out var site) &&
        string.Equals(uri.Host, site.Host, StringComparison.OrdinalIgnoreCase) && uri.Host.Length > 0;

    internal static string? Text(JsonElement raw, string name) =>
        raw.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String ? value.GetString() : null;

    /// <summary>A JSON whole number, and nothing that merely looks like one: a text, a fraction or an exponent is
    /// refused, because the signed text writes the number itself.</summary>
    internal static long? Whole(JsonElement raw, string name)
    {
        if (!raw.TryGetProperty(name, out var value) || value.ValueKind != JsonValueKind.Number) return null;
        var text = value.GetRawText();
        if (text.AsSpan().IndexOfAny('.', 'e', 'E') >= 0) return null;
        return value.TryGetInt64(out var whole) ? whole : null;
    }
}

/// <summary>What the channel says the newest build of Founderizer for Windows is for one arch (`GET
/// /releases/windows?arch=…`), after its signature was checked: the Mac's build manifest with the arch, in a third kind
/// of signed text (windows-app-release-design.md, section 2). Its first line and its ten lines make other bytes than a
/// Mac build's and a fleet release's, so a signature of one verifies as none of the others.</summary>
public sealed record WindowsManifest(string Version, long Build, string Arch, string Url, string Sha256, long Size,
                                     string? MinimumSystem, string? Notes, bool Hold, string Signature)
{
    public const string SignedPrefix = "founderizer-windows-1";
    /// <summary>The two kinds of PC (D6). A PC asks for its own, and takes no other.</summary>
    public static readonly IReadOnlyList<string> Arches = ["x64", "arm64"];

    /// <summary>The exact bytes that a build's signature covers.</summary>
    public byte[] SignedText() => Encoding.UTF8.GetBytes(string.Join('\n', [
        SignedPrefix, Version, Build.ToString(CultureInfo.InvariantCulture), Arch, Url, Sha256,
        Size.ToString(CultureInfo.InvariantCulture), MinimumSystem ?? "", Notes ?? "", Hold ? "true" : "false",
    ]) + "\n");

    /// <summary>The manifest of the channel's answer, field by field, with the Mac's rules and words
    /// (<see cref="AppManifest.Read"/>), and the arch that this PC asked for.</summary>
    public static WindowsManifest Read(ReadOnlySpan<byte> data, string channel, string arch)
    {
        if (data.Length > AppManifest.AnswerLimit) throw new ReleaseUntrusted("The channel did not answer with a build this app could read.");
        JsonDocument document;
        try
        {
            document = JsonDocument.Parse(data.ToArray());
        }
        catch (JsonException)
        {
            throw new ReleaseUntrusted("The channel did not answer with a build this app could read.");
        }
        using (document)
        {
            var raw = document.RootElement;
            if (raw.ValueKind != JsonValueKind.Object)
                throw new ReleaseUntrusted("The channel did not answer with a build this app could read.");
            var version = AppManifest.Text(raw, "version");
            if (version is null || !Patterns.Version().IsMatch(version))
                throw new ReleaseUntrusted("The channel's answer has no version name.");
            if (AppManifest.Whole(raw, "build") is not { } build || build is < 1 or > 2_000_000_000)
                throw new ReleaseUntrusted("The channel's answer has no build number.");
            var kind = AppManifest.Text(raw, "arch");
            if (kind is null || !Arches.Contains(kind) || kind != arch)
                throw new ReleaseUntrusted("The channel's answer is a build for another kind of PC.");
            var url = AppManifest.Text(raw, "url");
            if (url is null || Encoding.UTF8.GetByteCount(url) > 400 || !AppManifest.IsOurs(url, channel) ||
                !Path.GetExtension(new Uri(url).AbsolutePath).Equals(".zip", StringComparison.OrdinalIgnoreCase))
                throw new ReleaseUntrusted("The channel's answer points the download somewhere that is not ours.");
            var sha256 = AppManifest.Text(raw, "sha256");
            if (sha256 is null || !Patterns.Sha256Hex().IsMatch(sha256))
                throw new ReleaseUntrusted("The channel's answer carries no checksum for the download.");
            if (AppManifest.Whole(raw, "size") is not { } size || size is < 1 or > AppManifest.MaximumDownload)
                throw new ReleaseUntrusted("The channel's answer gives the download no believable size.");
            var minimum = AppManifest.Text(raw, "minimum");
            if (!string.IsNullOrEmpty(minimum) && !Patterns.WindowsVersion().IsMatch(minimum))
                throw new ReleaseUntrusted("The channel's answer names a Windows version this app cannot read.");
            var notes = AppManifest.Text(raw, "notes");
            if (!string.IsNullOrEmpty(notes) && !AppManifest.IsOurs(notes, channel))
                throw new ReleaseUntrusted("The channel's answer points its notes somewhere that is not ours.");
            var hold = false;
            if (raw.TryGetProperty("hold", out var held))
            {
                if (held.ValueKind is not (JsonValueKind.True or JsonValueKind.False))
                    throw new ReleaseUntrusted("The channel's answer does not say whether this build is held.");
                hold = held.GetBoolean();
            }
            var signature = AppManifest.Text(raw, "signature");
            if (signature is null || Encoding.UTF8.GetByteCount(signature) is < 1 or > 200)
                throw new ReleaseUntrusted("The channel's answer carries no signature.");
            return new WindowsManifest(version, build, kind, url, sha256, size, string.IsNullOrEmpty(minimum) ? null : minimum,
                                       string.IsNullOrEmpty(notes) ? null : notes, hold, signature);
        }
    }

    /// <summary>The manifest that this PC may act on, or <see cref="ReleaseUntrusted"/>. Nothing else reads an unchecked
    /// one.</summary>
    public static WindowsManifest Check(ReadOnlySpan<byte> data, IReadOnlyList<byte[]> keys, string channel, string arch)
    {
        var manifest = Read(data, channel, arch);
        if (keys.Count == 0)
            throw new ReleaseUntrusted("This build of Founderizer carries no release key, so it refuses every update. " +
                                       "That is the safe state: an app that cannot check an update takes none.");
        if (!Base64Strict.TryDecode(manifest.Signature, out var signature) || signature.Length != 64)
            throw new ReleaseUntrusted("The channel's signature is not a signature.");
        if (!Ed25519Check.SignedByAny(keys, manifest.SignedText(), signature))
            throw new ReleaseUntrusted("This build is not signed by the release key Founderizer ships with. " +
                                       "Nothing was downloaded.");
        return manifest;
    }
}

/// <summary>A fleet release (releases.read_manifest and releases.signed_text): what the hub takes from the channel. The
/// app reads it only to show what its fleet runs; its line format is here so that both formats are held by vectors.</summary>
public sealed record FleetRelease(string Revision, string Version, string? Notes, string? Minimum, bool Hold,
                                  string Signature)
{
    public const string SignedPrefix = "founderizer-release-1";

    public byte[] SignedText() => Encoding.UTF8.GetBytes(string.Join('\n', [
        SignedPrefix, Revision, Version, Notes ?? "", Minimum ?? "", Hold ? "true" : "false",
    ]) + "\n");

    public static FleetRelease Read(ReadOnlySpan<byte> data)
    {
        JsonDocument document;
        try { document = JsonDocument.Parse(data.ToArray()); }
        catch (JsonException) { throw new ReleaseUntrusted("the release channel did not answer with a manifest"); }
        using (document)
        {
            var raw = document.RootElement;
            if (raw.ValueKind != JsonValueKind.Object)
                throw new ReleaseUntrusted("the release channel did not answer with a manifest");
            var revision = AppManifest.Text(raw, "revision");
            if (revision is null || !Patterns.Revision().IsMatch(revision))
                throw new ReleaseUntrusted("the manifest names no revision");
            var version = AppManifest.Text(raw, "version");
            if (version is null || !Patterns.Version().IsMatch(version))
                throw new ReleaseUntrusted("the manifest has no version name");
            var notes = Optional(raw, "notes", "the manifest's notes are not an https address");
            if (!string.IsNullOrEmpty(notes) && !Patterns.NotesAddress().IsMatch(notes))
                throw new ReleaseUntrusted("the manifest's notes are not an https address");
            var minimum = Optional(raw, "minimum", "the manifest's minimum is not a commit");
            if (!string.IsNullOrEmpty(minimum) && !Patterns.Revision().IsMatch(minimum))
                throw new ReleaseUntrusted("the manifest's minimum is not a commit");
            var hold = false;
            if (raw.TryGetProperty("hold", out var held))
            {
                if (held.ValueKind is not (JsonValueKind.True or JsonValueKind.False))
                    throw new ReleaseUntrusted("the manifest's hold is not true or false");
                hold = held.GetBoolean();
            }
            var signature = AppManifest.Text(raw, "signature");
            if (signature is null || signature.Length is 0 or > 200)
                throw new ReleaseUntrusted("the manifest carries no signature");
            return new FleetRelease(revision, version, string.IsNullOrEmpty(notes) ? null : notes,
                                    string.IsNullOrEmpty(minimum) ? null : minimum, hold, signature);
        }
    }

    /// <summary>The release that a fleet may act on, or <see cref="ReleaseUntrusted"/> (releases.check).</summary>
    public static FleetRelease Check(ReadOnlySpan<byte> data, IReadOnlyList<byte[]> keys)
    {
        var release = Read(data);
        if (keys.Count == 0) throw new ReleaseUntrusted("this checkout carries no release key, so no release can be checked");
        var padded = release.Signature + new string('=', (4 - release.Signature.Length % 4) % 4);
        if (!Base64Strict.TryDecode(padded, out var signature))
            throw new ReleaseUntrusted("the manifest's signature is not base64");
        if (!Ed25519Check.SignedByAny(keys, release.SignedText(), signature))
            throw new ReleaseUntrusted("the manifest's signature is not a signature of it by a release key this checkout carries");
        return release;
    }

    /// <summary>A text field that may be absent or null; any other kind of value is refused, as releases.read_manifest
    /// refuses it.</summary>
    private static string? Optional(JsonElement raw, string name, string refusal)
    {
        if (!raw.TryGetProperty(name, out var value) || value.ValueKind == JsonValueKind.Null) return null;
        if (value.ValueKind != JsonValueKind.String) throw new ReleaseUntrusted(refusal);
        return value.GetString();
    }
}
