using System;
using System.Collections.Generic;
using Founderizer.Owner.Reads;

namespace Founderizer.Setup.Agents;

/// <summary>The one line that a machine's sign-in row says, and whether it says it in orange (the Mac's SignInLine):
/// a failure to act on is orange; progress is not.</summary>
public sealed record SignInLine(string Says, bool Warn);

/// <summary>**What the sign-in page of an agent's setup shows** (the Mac's <c>AgentSetupWizard.signIn</c>), from the
/// server's job and the machine's sign-in: a wait with its moving title until the provider printed its link and from the
/// code's send until the machine reports; else the provider's own steps over the code field (Claude Code: a code to paste
/// back) or over the code to enter there with its Copy (Codex). <see cref="Link"/> is only ever a link of the provider's
/// own hosts (<see cref="JobPrompt.SignInUrl"/>, <see cref="MachineLogin.SignInUrl"/>): the window opens nothing else.</summary>
public sealed record SignInPage(string Title, bool Waits, Uri? Link, IReadOnlyList<string> Steps, bool AsksCode, string? ShownCode,
                                string? Refusal)
{
    /// <summary>The placeholder of the code field (the Mac's <c>CodeField</c>).</summary>
    public const string CodePlaceholder = "Paste the code";

    /// <summary>Its text names no link and no code: a link holds the provider's state of one sign-in, and a code is the
    /// owner's.</summary>
    public override string ToString() =>
        $"SignInPage {{ Title = {Title}, Waits = {Waits}, Link = {(Link is null ? "none" : "(not shown)")}, AsksCode = {AsksCode}, " +
        $"ShownCode = {(ShownCode is null ? "none" : "(not shown)")} }}";
}

/// <summary>The sign-in of an agent's machine, in the Mac's words (FleetCore/MachineSignin.swift and the sign-in page of
/// Founderizer/AgentSetupWizard.swift).</summary>
public static class SignIn
{
    /// <summary>A provider by its product's name (the Mac's <c>providerName</c>).</summary>
    public static string ProviderName(string runtime) => runtime switch
    {
        "claude" => "Claude Code",
        "codex" => "Codex",
        "grok" => "Grok Build",
        _ => runtime.Length == 0 ? runtime : char.ToUpperInvariant(runtime[0]) + runtime[1..].ToLowerInvariant(),
    };

    /// <summary>A sign-in that gives a code to paste back (Claude Code's): its page, which the link opens, and the code
    /// that it shows after the sign-in. A step's link is written as the Mac writes it, <c>[words](address)</c>.</summary>
    public static IReadOnlyList<string> PasteSteps(Uri page) =>
        [$"Open [the sign-in page]({page.OriginalString})", "Sign in, then copy the code it shows"];

    /// <summary>A sign-in that shows a code to enter on its page (Codex's device code).</summary>
    public static IReadOnlyList<string> DeviceCodeSteps(Uri page) =>
        [$"Open [the sign-in page]({page.OriginalString})", "Sign in, then enter this code"];

    /// <summary>**What the Sign-in row says, in one line and never two** (the Mac's <c>signInLine</c>): the machine's own
    /// reading is the truth, and a sign-in attempt goes stale against it. <paramref name="alreadySaid"/>: the page said
    /// already that this machine is not signed in. <paramref name="provider"/>: the row of a provider that is not the
    /// machine's own choice.</summary>
    public static SignInLine? Line(MachineStatus machine, bool working, bool alreadySaid = false, string? provider = null)
    {
        if (working) return new SignInLine("Working…", false);
        if ((provider ?? machine.SignInRuntime) is not { } name) return null;
        var attempt = machine.LoginOf(name);
        if (attempt is { IsOpen: true }) return new SignInLine(attempt.Summary, false);
        if (!machine.SignedOut(name)) return null;
        if (attempt is { IsFailure: true }) return new SignInLine(attempt.Summary, true);
        return alreadySaid ? null : new SignInLine("Not signed in on this server.", false);
    }

    /// <summary>**The sign-in page of the setup of <paramref name="provider"/>**: the job's prompt while the job waits for
    /// the owner, else the machine's open sign-in. <paramref name="sentFrom"/>: the sign-in's <c>updated_at</c> when the
    /// owner sent the code, null before.</summary>
    public static SignInPage Page(string provider, ServerJob? job, MachineStatus? machine, double? sentFrom, string? refusal)
    {
        var name = ProviderName(provider);
        var prompt = job?.State == "needs_owner" ? job.Prompt : null;
        var login = machine?.Login is { IsOpen: true } open ? open : null;
        var link = prompt?.SignInUrl ?? login?.SignInUrl;
        var shown = prompt?.DeviceCode ?? login?.DeviceCode;
        if (login?.CodeOnItsWay(sentFrom) == true || login?.State == "signing_in")
            return new SignInPage($"Signing in to {name}", true, null, [], false, null, refusal);
        if (link is not null)
        {
            var paste = login?.WaitsForCode == true;
            return new SignInPage($"Sign in to {name}", false, link, paste ? PasteSteps(link) : DeviceCodeSteps(link), paste,
                                  paste ? null : shown, refusal);
        }
        return new SignInPage(login?.IsSigningOut == true ? $"Signing out of {name}" : "Starting the sign-in", true, null, [], false,
                              null, refusal);
    }
}
