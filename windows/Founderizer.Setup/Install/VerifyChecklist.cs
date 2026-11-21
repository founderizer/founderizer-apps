using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;
using Founderizer.Core;

namespace Founderizer.Setup.Install;

/// <summary>One answer of <c>python3 fleet.py verify</c> on one machine of a fleet (PRODUCT.md 4.1; the Mac's
/// VerifyCheck): <c>Says</c> is the check's line for a person, <c>Fix</c> the one thing that puts it right, and
/// <c>Command</c> the exact command of that fix, which no page shows.</summary>
public sealed partial record VerifyCheck(string Check, string State, string Says, string? Fix = null, string? Command = null)
{
    public bool Failed => State == "fail";
    public bool Warned => State == "warn";
    public bool Passed => State == "ok";

    /// <summary>The shape 4.1 freezes, and nothing else: an id of its own, one of the three states, one line of at most
    /// 300 characters, and a fix that an <c>ok</c> does not carry.</summary>
    public bool IsValid =>
        Id().IsMatch(Check) && State is "ok" or "warn" or "fail" && Says.Length > 0 && Characters(Says) <= 300 &&
        (Fix is null || (Fix.Length > 0 && Characters(Fix) <= 300)) && !(Passed && Fix is not null);

    /// <summary>The title of this check on the owner's checklist.</summary>
    public string Title => VerifyChecklist.Title(Check);

    /// <summary>Characters as Swift counts them: what a person reads as one.</summary>
    private static int Characters(string text) => new StringInfo(text).LengthInTextElements;

    [GeneratedRegex(@"\A[a-z][a-z0-9_]{0,30}\z", RegexOptions.CultureInvariant)]
    private static partial Regex Id();
}

/// <summary>**The checklist of one machine**: what <c>verify</c> answered there, as the app shows it (the Mac's
/// VerifyChecklist). A check that does not apply to a machine is absent, and a missing id is never a pass.</summary>
public sealed class VerifyChecklist
{
    /// <summary>The ids of this version, in the one order they come in (4.1).</summary>
    public static readonly IReadOnlyList<string> Ids =
        ["services", "hub_answers", "owner_claimed", "tailnet", "firewall", "clock", "disk", "runtime_installed",
         "runtime_signed_in", "desktop", "selftest", "version", "team"];
    private static readonly Dictionary<string, int> Place = Ids.Select((id, at) => (id, at)).ToDictionary(x => x.id, x => x.at);
    internal const int Limit = 32;
    /// <summary>The check that a machine fails until its owner signs it in to their provider.</summary>
    public const string SignInCheck = "runtime_signed_in";
    /// <summary>What both installers print as their last line: <c>READY</c>, or <c>NOT READY: &lt;ids&gt;</c>.</summary>
    public const string ReadyLine = "READY";

    /// <summary>The checks that are about the owner's machine, and not about our own installation of it.</summary>
    public static readonly IReadOnlyList<string> AboutHisMachine =
        ["services", "tailnet", "firewall", "clock", "disk", "runtime_installed", "runtime_signed_in"];

    public IReadOnlyList<VerifyCheck> Checks { get; }
    public double? ReadAt { get; }

    public VerifyChecklist(IEnumerable<VerifyCheck> checks, double? readAt = null)
    {
        var all = checks.ToList();
        Checks = all.Select((check, offset) => (check, offset))
                    .OrderBy(x => Place.TryGetValue(x.check.Check, out var at) ? at : Ids.Count + x.offset)
                    .Select(x => x.check).ToList();
        ReadAt = readAt;
    }

    /// <summary><c>READY</c> when nothing failed; an empty answer is not a pass.</summary>
    public bool IsReady => Checks.Count > 0 && !Checks.Any(c => c.Failed);
    public IReadOnlyList<VerifyCheck> Failing => Checks.Where(c => c.Failed).ToList();
    /// <summary>Nothing failed but the sign-in, which is the owner's own next step.</summary>
    public bool OnlyNeedsSignIn => Failing.Count > 0 && Failing.All(c => c.Check == SignInCheck);
    public IReadOnlyList<VerifyCheck> Warning => Checks.Where(c => c.Warned).ToList();

    /// <summary>What a closer look says, in order: everything that is not a pass, then the passes about his machine.</summary>
    public IReadOnlyList<VerifyCheck> Said =>
        Checks.Where(c => !c.Passed).Concat(Checks.Where(c => c.Passed && AboutHisMachine.Contains(c.Check))).ToList();

    /// <summary>How many passing checks of our own installation this look folded into one line.</summary>
    public int OurOwnPassed => Checks.Count(c => c.Passed && !AboutHisMachine.Contains(c.Check));

    /// <summary>The last line the installers print, and the one line a row of machines carries.</summary>
    public string Line =>
        Checks.Count == 0 ? "Not checked" : IsReady ? "READY" : "NOT READY: " + string.Join(", ", Failing.Select(c => c.Check));

    /// <summary>What a machine's page says above the list.</summary>
    public string Summary
    {
        get
        {
            if (Checks.Count == 0) return "This server has not been checked yet.";
            if (OnlyNeedsSignIn)
                return "This server is in your fleet. It is not signed in to your provider yet, which is your own next step: no installer can do it for you.";
            var failing = Failing;
            if (failing.Count > 0)
            {
                var names = string.Join(", ", failing.Select(c => c.Title));
                return failing.Count == 1 ? $"{names} failed. Its fix is below." : $"{failing.Count} checks failed: {names}.";
            }
            var warning = Warning;
            if (warning.Count > 0) return warning.Count == 1 ? "Ready, with 1 warning." : $"Ready, with {warning.Count} warnings.";
            return "Ready. Every check of this server passed.";
        }
    }

    /// <summary>The answers of <c>verify --json</c> as the command wrote them; null for a body that is not that array, or
    /// that carries an answer outside the frozen shape.</summary>
    public static VerifyChecklist? Decode(byte[] data, double? readAt = null)
    {
        if (data.Length > 65_536) return null;
        List<VerifyCheck>? answers;
        try
        {
            answers = JsonSerializer.Deserialize(data, InstallJson.Default.ListVerifyCheck);
        }
        catch (JsonException)
        {
            return null;
        }
        if (answers is null || answers.Count > Limit || answers.Select(a => a.Check).Distinct().Count() != answers.Count ||
            !answers.All(a => a.IsValid)) return null;
        return new VerifyChecklist(answers, readAt);
    }

    /// <summary>**Output that has what can be a list of checks**: the word "check" in quotes, or a list with nothing in
    /// it, and a "[" before a "{" or a "]" with a "]" after it. An install tells by it a server that printed its checks
    /// in a shape that this app does not read from a program that printed its own error.</summary>
    public static bool HoldsList(string output)
    {
        if (!(output.Contains("\"check\"", StringComparison.Ordinal) || string.Concat(output.Where(c => !char.IsWhiteSpace(c))) == "[]"))
            return false;
        var end = output.LastIndexOf(']');
        if (end < 0) return false;
        for (var at = output.IndexOf('['); at >= 0 && at < end; at = output.IndexOf('[', at + 1))
            if (FirstAfterSpace(output, at + 1) is '{' or ']') return true;
        return false;
    }

    /// <summary>The same array out of output that carries other lines around it, which is what an install over SSH
    /// gives: each candidate from the last to the first, until one decodes to the frozen shape.</summary>
    public static VerifyChecklist? Read(string output, double? readAt = null)
    {
        if (output.Length > 262_144) return null;
        var end = output.LastIndexOf(']');
        if (end < 0) return null;
        var starts = new List<int>();
        for (var at = output.IndexOf('['); at >= 0; at = at + 1 < output.Length ? output.IndexOf('[', at + 1) : -1)
            if (FirstAfterSpace(output, at + 1) is '{' or ']') starts.Add(at);
        for (var i = starts.Count - 1; i >= 0; i--)
        {
            if (starts[i] >= end) continue;
            if (Decode(Encoding.UTF8.GetBytes(output[starts[i]..(end + 1)]), readAt) is { } found) return found;
        }
        return null;
    }

    private static char? FirstAfterSpace(string text, int from)
    {
        for (var i = from; i < text.Length; i++)
            if (!char.IsWhiteSpace(text[i])) return text[i];
        return null;
    }

    /// <summary>The title of one check, as the owner reads it. "This Mac's desktop" stays: that check is of a Mac that
    /// joined the fleet, not of the owner's computer.</summary>
    public static string Title(string id) => id switch
    {
        "services" => "Services",
        "hub_answers" => "The hub answers",
        "owner_claimed" => "Your own address",
        "tailnet" => "Private network",
        "firewall" => "Firewall",
        "clock" => "Clock",
        "disk" => "Disk space",
        "runtime_installed" => "Provider installed",
        "runtime_signed_in" => "Signed in",
        "desktop" => "This Mac's desktop",
        "selftest" => "Self-test",
        "version" => "Revision",
        "team" => "The team file",
        _ => AgentBook.Capitalized(id.Replace('_', ' ')),
    };
}

/// <summary>The JSON of the install's own types: the checks of <c>verify</c> (its names are one word each). The file
/// form of the kept records comes with their store (piece L4).</summary>
[JsonSourceGenerationOptions(
    PropertyNamingPolicy = JsonKnownNamingPolicy.CamelCase,
    RespectNullableAnnotations = true,
    RespectRequiredConstructorParameters = true,
    NumberHandling = JsonNumberHandling.Strict)]
[JsonSerializable(typeof(List<VerifyCheck>))]
internal sealed partial class InstallJson : JsonSerializerContext;
