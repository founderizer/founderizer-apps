using System;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;

namespace Founderizer.Core;

/// <summary>**The key of the owner's PC for one hub** (windows-app-plan-v2.md, section 5.2): the Mac's rule of
/// FleetCore/OwnerMacKey.swift, with the PC's storage, the secret box.
///
/// The hub knows the owner's computer by its address **and** a key: 32 random bytes that the PC makes itself, as
/// base64url with no padding, of which the hub keeps only the SHA-256 (64 lower-case hex characters). The PC keeps the
/// key in its secret box under <c>owner-keys/&lt;address&gt;_&lt;port&gt;</c>. While a claim's answer is not read, the key
/// stands under the same name with <c>.pending</c>, so that an answer that is lost loses no key: a claim made again
/// sends the same key, and the store's first read that the hub takes with it makes it the key.
///
/// **One hub, one number.** The name has the hub's numeric address in it, and a hub that is written as a name has no
/// key place at all (<see cref="Name"/> gives null): the claim always gives a number, so the key never goes where a
/// lookup of a name points (the Mac's <c>signing</c> rule, without its lookup).</summary>
public static partial class OwnerPcKey
{
    /// <summary>The hub's feature name: a hub that lists it takes a key and has POST /ui/owner/key.</summary>
    public const string Feature = "owner_key";
    /// <summary>The header of a claim that carries the key's SHA-256 beside the code (hubsetup.py OWNER_KEY_HEADER).</summary>
    public const string ClaimHeader = "X-Fleet-Owner-Key-Sha256";
    /// <summary>The header of the claim's answer, which says "kept" when the installer keeps the SHA-256.</summary>
    public const string ClaimKept = "X-Fleet-Owner-Key";
    /// <summary>The hub's three refusals that are about this key (<c>auth</c> in a 403).</summary>
    public const string Required = "owner_key_required", Mismatch = "owner_key_mismatch", NotExpected = "key_not_expected";

    /// <summary>The claim's one refusal of this PC's own: the address is not on the owner's private network, so nothing
    /// is sent (the Mac's MachineInstaller.notOnYourNetwork).</summary>
    public const string NotOnYourNetwork = "The installer printed an address that is not on your own network.";
    /// <summary>A claim that the listener refused with no words of its own.</summary>
    public const string CodeRefused = "The hub refused the link code.";

    // ------------------------------------------------------------ the key

    /// <summary>A new key: 32 bytes of the system's random source as base64url with no padding, 43 letters.</summary>
    public static string Make()
    {
        var bytes = RandomNumberGenerator.GetBytes(32);
        try { return Convert.ToBase64String(bytes).Replace('+', '-').Replace('/', '_').TrimEnd('='); }
        finally { CryptographicOperations.ZeroMemory(bytes); }
    }

    /// <summary>The SHA-256 of a key's text in lower-case hex: all that a hub ever gets of it.</summary>
    public static string Digest(string key) => Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(key)));

    /// <summary>A key as the PC and the hub's other clients write one: 32 to 128 letters of base64url.</summary>
    public static bool IsKey(string text) => Shape().IsMatch(text);

    [GeneratedRegex(@"\A[A-Za-z0-9_-]{32,128}\z", RegexOptions.CultureInvariant)]
    private static partial Regex Shape();

    // ------------------------------------------------------------ where the key is

    /// <summary>The box's name of the key for <paramref name="hub"/>: <c>owner-keys/&lt;address&gt;_&lt;port&gt;</c>, with
    /// the address as the system writes it (IPv6 compressed, in small letters) and each letter that a name may not have
    /// as "-" (the Mac's <c>name(host:port:)</c>). Null for a hub that is written as a name.</summary>
    public static string? Name(Uri hub)
    {
        if (!hub.IsAbsoluteUri || !IPAddress.TryParse(hub.Host.Trim('[', ']'), out var address)) return null;
        if (address.AddressFamily == AddressFamily.InterNetworkV6) address.ScopeId = 0;
        var letters = new StringBuilder();
        foreach (var c in address.ToString().ToLowerInvariant())
            letters.Append(c is >= 'a' and <= 'z' or >= '0' and <= '9' or '.' or '-' ? c : '-');
        return "owner-keys/" + letters + "_" + hub.Port.ToString(System.Globalization.CultureInfo.InvariantCulture);
    }

    /// <summary>The key that the PC has for <paramref name="hub"/>, or null: none, a hub written as a name, or a kept
    /// value that is no key.</summary>
    public static string? Read(ISecretBox box, Uri hub) => Name(hub) is { } name ? KeyIn(box, name) : null;

    /// <summary>The key that waits for the answer of the hub at <paramref name="hub"/>, or null.</summary>
    public static string? Waiting(ISecretBox box, Uri hub) => Name(hub) is { } name ? KeyIn(box, name + ".pending") : null;

    private static string? KeyIn(ISecretBox box, string name)
    {
        var bytes = box.Read(name);
        if (bytes is null) return null;
        try
        {
            var text = Encoding.UTF8.GetString(bytes);
            return IsKey(text) ? text : null;
        }
        finally
        {
            CryptographicOperations.ZeroMemory(bytes);
        }
    }

    private static void Write(ISecretBox box, string name, string key)
    {
        var bytes = Encoding.UTF8.GetBytes(key);
        try { box.Write(name, bytes); }
        finally { CryptographicOperations.ZeroMemory(bytes); }
    }

    /// <summary>Keeps <paramref name="key"/> as the key that waits for the hub's answer: written **before** the call that
    /// tells the hub its SHA-256, so that the hub never holds the SHA-256 of a key that this PC does not have.</summary>
    public static void KeepWaiting(ISecretBox box, Uri hub, string key)
    {
        if (!IsKey(key) || Name(hub) is not { } name) throw new ArgumentException("no key, or no place for it");
        Write(box, name + ".pending", key);
    }

    /// <summary>**The hub took <paramref name="key"/>: it is this PC's key now**, whatever was kept before. The key that
    /// waited goes when it is that key. A key that cannot be written stays where it was, and the one that waits stays
    /// with it.</summary>
    public static void Promote(ISecretBox box, Uri hub, string key)
    {
        if (Name(hub) is not { } name) return;
        try
        {
            // A kept value that does not open is no key of this hub's: the key that the hub took goes in its place.
            if (Opened(box, name) != key) Write(box, name, key);
            if (Opened(box, name + ".pending") == key) box.Remove(name + ".pending");
        }
        catch (Exception e) when (e is not OutOfMemoryException) { }
    }

    /// <summary>The key that waited for the hub goes, when it is <paramref name="key"/>: the hub answered, and it keeps
    /// no such key. The kept key stays, and so does a value that does not open.</summary>
    public static void ForgetWaiting(ISecretBox box, Uri hub, string key)
    {
        if (Name(hub) is not { } name) return;
        try
        {
            if (Opened(box, name + ".pending") == key) box.Remove(name + ".pending");
        }
        catch (Exception e) when (e is not OutOfMemoryException) { }
    }

    /// <summary>The key under <paramref name="name"/>, or null: none there, or a value that does not open.</summary>
    private static string? Opened(ISecretBox box, string name)
    {
        try { return KeyIn(box, name); }
        catch (Exception e) when (e is not OutOfMemoryException) { return null; }
    }

    // ------------------------------------------------------------ the claim of a new hub

    /// <summary>An address of the fleet's private network that a claim may go to: IPv4 in 100.64.0.0/10 (the Mac's
    /// ClaimCode.isPrivateAddress).</summary>
    public static bool IsClaimAddress(string host) =>
        IPAddress.TryParse(host, out var address) && address.AddressFamily == AddressFamily.InterNetwork &&
        address.ToString() == host && address.GetAddressBytes() is [100, >= 64 and <= 127, _, _];

    /// <summary>**The claim of a new hub, from this PC and from nowhere else** (the Mac's MachineInstaller.sendClaim):
    /// POST <c>http://&lt;address&gt;:&lt;port&gt;/claim</c> with the code as text, to the address that the installer
    /// printed, which must be one of 100.64.0.0/10. The installer takes the address that the call comes from as the
    /// owner's own.
    ///
    /// The same call carries the SHA-256 of this PC's key for that hub, made here and never sent. The key waits in the
    /// box from before the call, so an answer that is lost loses no key: a claim made again sends the key that waits,
    /// and a claim that the listener refused takes none away. The key becomes this PC's when the installer says that it
    /// kept the SHA-256; an installer from before the key says nothing, and the key that waited then goes. **A key that
    /// the PC kept for that hub before stays until then.** A PC that cannot write its box claims with no key: its hub
    /// then knows it by its address alone.
    ///
    /// Null when the hub took the claim; else the owner's words: the listener's own, or the PC's.</summary>
    public static Task<string?> ClaimAsync(HubClient client, ISecretBox box, Uri claim, string code,
                                           CancellationToken cancel = default)
    {
        if (!claim.IsAbsoluteUri || claim.Scheme != "http" || !IsClaimAddress(claim.Host) || claim.AbsolutePath != "/claim" ||
            claim.Query.Length > 0 || claim.Fragment.Length > 0 || claim.UserInfo.Length > 0)
            return Task.FromResult<string?>(NotOnYourNetwork);
        return SendClaimAsync(client, box, claim, code, cancel);
    }

    /// <summary>The claim after its address check: the tests send it to a hub on 127.0.0.1.</summary>
    internal static async Task<string?> SendClaimAsync(HubClient client, ISecretBox box, Uri claim, string code,
                                                       CancellationToken cancel)
    {
        var hub = new Uri(claim.GetLeftPart(UriPartial.Authority) + "/");
        string? key = null;
        try
        {
            // A key that waits and does not open is none: a new one takes its place, so the claim carries a key.
            var made = Opened(box, Name(hub)! + ".pending") ?? Make();
            KeepWaiting(box, hub, made);
            key = made;
        }
        catch (Exception e) when (e is not OutOfMemoryException) { }
        ClaimAnswer answer;
        try
        {
            answer = await client.ClaimAsync(claim, code, key is null ? null : Digest(key), cancel);
        }
        catch (HubException e)
        {
            return e.Message;
        }
        if (answer.Status != 200) return answer.Said.Length > 0 ? answer.Said : CodeRefused;
        if (key is null) return null;
        if (answer.Kept) Promote(box, hub, key);
        else ForgetWaiting(box, hub, key);
        return null;
    }
}

/// <summary>What the claim's listener answered: its status, whether it kept the key's SHA-256, and its first words.</summary>
public sealed record ClaimAnswer(int Status, bool Kept, string Said);
