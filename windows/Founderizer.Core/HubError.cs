using System;
using System.Collections.Generic;

namespace Founderizer.Core;

/// <summary>What failed in one call to the hub. The kinds are the iPhone's (`MobileError` in
/// app/ios/Sources/MobileClient.swift): an owner device has two locks, and each failure asks for another step.</summary>
public enum HubErrorKind
{
    /// <summary>The address is not an HTTP or HTTPS hub address without a path or a login.</summary>
    InvalidAddress,
    /// <summary>The hub's answer does not match the device's API: a decoder refused it.</summary>
    InvalidResponse,
    /// <summary>The hub refused. <see cref="HubException.Auth"/> is its reason when the refusal is about the key.</summary>
    Refusal,
    /// <summary>The hub answers nothing at GET /ui/mobile: it is from before the phone's routes.</summary>
    NoPhoneRoutes,
    /// <summary>No answer came: no route to the hub, a refused connection, or a timeout.</summary>
    NoAnswer,
}

/// <summary>One failed call to the hub, with the owner's words for it.</summary>
public sealed class HubException : Exception
{
    public HubErrorKind Kind { get; }
    /// <summary>The HTTP status of a refusal, else 0.</summary>
    public int Status { get; }
    /// <summary>The hub's `auth` value of a refusal of this device's key, else null.</summary>
    public string? Auth { get; }
    /// <summary>The hub's own words of a refusal (at most 500 characters), else null.</summary>
    public string? HubWords { get; }
    /// <summary>The read whose decoder refused the answer, for an <see cref="HubErrorKind.InvalidResponse"/>.</summary>
    public string? Read { get; }

    private HubException(HubErrorKind kind, string message, int status = 0, string? auth = null, string? words = null,
                         string? read = null, Exception? inner = null) : base(message, inner)
    {
        Kind = kind;
        Status = status;
        Auth = auth;
        HubWords = words;
        Read = read;
    }

    public static HubException InvalidAddress() =>
        new(HubErrorKind.InvalidAddress, "Enter an HTTP or HTTPS hub address without a path or login.");

    /// <summary>A decoder refused the answer of <paramref name="read"/>; <paramref name="why"/> says which rule.</summary>
    public static HubException InvalidResponse(string read, string why, Exception? inner = null) =>
        new(HubErrorKind.InvalidResponse, "The hub's answer does not match the phone's API.", read: read,
            words: why, inner: inner);

    public static HubException Refusal(int status, string? auth, string message) =>
        new(HubErrorKind.Refusal, auth is null ? "The hub refused it: " + Sentence(message) : AuthWords(auth),
            status, auth, message);

    public static HubException NoPhoneRoutes() =>
        new(HubErrorKind.NoPhoneRoutes, "This hub does not have the phone's routes yet. The Mac app still works with it.");

    public static HubException NoAnswer(Exception? inner = null) =>
        new(HubErrorKind.NoAnswer, "Your hub did not answer. Check that its server is on.", inner: inner);

    /// <summary>The hub decided, so the same request again changes nothing. A request that waits for an answer that may
    /// still come is never definitive: it keeps its number and can go again.</summary>
    public bool IsDefinitive =>
        Kind == HubErrorKind.NoPhoneRoutes ||
        (Kind == HubErrorKind.Refusal && DefinitiveStatuses.Contains(Status));

    private static readonly HashSet<int> DefinitiveStatuses = [400, 403, 404, 409, 413, 415, 422, 429, 503];

    /// <summary>A write that the hub refused, in a few words that say what failed: "Not sent: Atlas is in setup." A
    /// refusal of the device's key keeps its own words, which say what to do.</summary>
    public string NotSentWords =>
        Kind == HubErrorKind.Refusal && Auth is null ? "Not sent: " + Sentence(HubWords ?? "") : Message;

    /// <summary>The hub's words as a sentence: the first letter in upper case and a full stop at the end.</summary>
    public static string Sentence(string words)
    {
        var trimmed = words.Trim();
        if (trimmed.Length == 0) return trimmed;
        var first = char.ToUpperInvariant(trimmed[0]) + trimmed[1..];
        return ".!?".Contains(trimmed[^1]) ? first : first + ".";
    }

    /// <summary>What a refusal of this device means and what the owner does next (the iPhone's words, with "phone").
    /// The screens of the Windows app say "PC" where the iPhone says "phone"; that choice is theirs.</summary>
    public static string AuthWords(string auth) => auth switch
    {
        "device_not_enrolled" => "This phone is not enrolled. On your Mac press New code, then add this phone in Settings.",
        "device_key_required" => "The hub wants this phone's key and the phone sent none. Add this phone again with a new code.",
        "device_key_mismatch" => "This phone's key is not the one the hub keeps. Add this phone again with a new code.",
        "device_not_allowed" => "The phone may not use that part of the hub. That setup work stays in the Mac app.",
        "key_not_expected" => "This address is the owner's own Mac, which needs no key. Forget this phone's key in Settings.",
        _ => $"The hub refused this phone ({auth}).",
    };

    /// <summary>What a refusal of the enrollment means. The hub answers 403 for two things here (the address is not one
    /// of its devices, or the code did not work), and they ask for different steps.</summary>
    public static string EnrollWords(HubException error) => error switch
    {
        { Kind: HubErrorKind.Refusal, Status: 429 } => "Too many wrong codes. Wait an hour, or make a new code.",
        { Kind: HubErrorKind.Refusal, Status: 403 } when (error.HubWords ?? "").Contains("owner device", StringComparison.OrdinalIgnoreCase)
            => "Your hub does not know this phone. Add it on your Mac.",
        { Kind: HubErrorKind.Refusal, Status: 403 } => "This code did not work. Make a new one on your Mac.",
        _ => error.Message,
    };
}

/// <summary>A file that the hub or this device would not take, with the owner's words (FleetCore's AttachmentError).</summary>
public sealed class AttachmentException(AttachmentException.Problem problem) : Exception(problem switch
{
    Problem.Metadata => "The hub described this file in a way this app does not take.",
    Problem.Bytes => "The file that came back is not the file that the hub named.",
    Problem.TooLarge => "A file is at most 25 MB.",
    _ => "This hub takes images, PDF, ZIP, text, Markdown, CSV and JSON.",
})
{
    public enum Problem { Metadata, Bytes, TooLarge, Type }
    public Problem Kind { get; } = problem;
}
