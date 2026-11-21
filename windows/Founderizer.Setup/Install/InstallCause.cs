using System;
using System.Collections.Generic;
using System.Linq;

namespace Founderizer.Setup.Install;

/// <summary>**Why an installer stopped, as a fixed name** (the Mac's InstallCause): an installer that stops itself
/// prints one sentence of ours after its stop mark, which is read here and dropped, so that only the name is kept.
/// <see cref="InstallCauses.Name"/> gives each name as the Mac writes it.</summary>
public enum InstallCause
{
    NeedsRoot, SystemNotSupported, NoSystemd, HubNoAnswer, CodeNotFetched, JoinCodeRefused, JoinCodeExpired,
    ServerNameRefused, ServerNameUnread, HubBusy, PrivateNetwork, Firewall, AgentUsers, Vault, Updates, Packages,
    Service, HubClaim, AgentProgram, Homebrew, WrongMacUser, Other,
}

/// <summary>The rows that read a stop sentence (the Mac's InstallCause.rows), and the names.</summary>
public static class InstallCauses
{
    private static readonly (InstallCause Cause, string Name)[] Names =
    [
        (InstallCause.NeedsRoot, "needs_root"), (InstallCause.SystemNotSupported, "system_not_supported"),
        (InstallCause.NoSystemd, "no_systemd"), (InstallCause.HubNoAnswer, "hub_no_answer"),
        (InstallCause.CodeNotFetched, "code_not_fetched"), (InstallCause.JoinCodeRefused, "join_code_refused"),
        (InstallCause.JoinCodeExpired, "join_code_expired"), (InstallCause.ServerNameRefused, "server_name_refused"),
        (InstallCause.ServerNameUnread, "server_name_unread"), (InstallCause.HubBusy, "hub_busy"),
        (InstallCause.PrivateNetwork, "private_network"), (InstallCause.Firewall, "firewall"),
        (InstallCause.AgentUsers, "agent_users"), (InstallCause.Vault, "vault"), (InstallCause.Updates, "updates"),
        (InstallCause.Packages, "packages"), (InstallCause.Service, "service"), (InstallCause.HubClaim, "hub_claim"),
        (InstallCause.AgentProgram, "agent_program"), (InstallCause.Homebrew, "homebrew"),
        (InstallCause.WrongMacUser, "wrong_mac_user"), (InstallCause.Other, "other"),
    ];

    /// <summary>The name as the Mac writes it ("hub_busy").</summary>
    public static string Name(this InstallCause cause) => Names.First(n => n.Cause == cause).Name;

    /// <summary>A name that a later version wrote reads as <see cref="InstallCause.Other"/>.</summary>
    public static InstallCause Named(string name) => Names.FirstOrDefault(n => n.Name == name) is { Name: not null } found
        ? found.Cause : InstallCause.Other;

    /// <summary>One row: a stable part of a stop sentence, in small letters, and its cause. <c>Whole</c>: the sentence is
    /// that part and nothing else.</summary>
    internal sealed record Row(string Part, InstallCause Cause, bool Whole = false);

    /// <summary>**The rows, in their order**: the first row that a sentence holds decides.</summary>
    internal static readonly IReadOnlyList<Row> Rows =
    [
        new("the server service did not start", InstallCause.Service),
        new("did not answer, so the owner claim", InstallCause.HubClaim),
        new("as the mac user that will run the agents", InstallCause.WrongMacUser),
        new("run the line as root", InstallCause.NeedsRoot),
        new("this system is ", InstallCause.SystemNotSupported),
        new("this system has no /etc/os-release", InstallCause.SystemNotSupported),
        new(" is too old. use macos", InstallCause.SystemNotSupported),
        new("systemd is required", InstallCause.NoSystemd),
        new("homebrew is not installed", InstallCause.Homebrew),
        new("homebrew could not install", InstallCause.Homebrew),
        new("homebrew could not be downloaded", InstallCause.Homebrew),
        new("homebrew's package has no valid signature", InstallCause.Homebrew),
        new("homebrew did not install", InstallCause.Homebrew),
        new("the owner claim did not finish", InstallCause.HubClaim),
        new("before the option --manager-name", InstallCause.HubClaim),
        new("cannot reach the founderizer hub at", InstallCause.HubNoAnswer),
        new("hub did not answer", InstallCause.HubNoAnswer),
        new("urlopen error", InstallCause.HubNoAnswer),
        new("remote end closed connection", InstallCause.HubNoAnswer),
        new("timed out", InstallCause.HubNoAnswer, Whole: true),
        new("could not get the founderizer repository", InstallCause.CodeNotFetched),
        new("could not clone the founderizer repository", InstallCause.CodeNotFetched),
        new("could not be cloned from git://", InstallCause.CodeNotFetched),
        new("join code is not valid", InstallCause.JoinCodeRefused),
        new("join code was already used", InstallCause.JoinCodeRefused),
        new("a newer join code replaced", InstallCause.JoinCodeRefused),
        new("join code expired", InstallCause.JoinCodeExpired),
        new("too many wrong join codes", InstallCause.JoinCodeRefused),
        new("this server is in your fleet already", InstallCause.ServerNameRefused),
        new("could not read this server's name in tailscale", InstallCause.ServerNameUnread),
        new("and a server's name in fleet has", InstallCause.ServerNameRefused),
        new("your fleet has a server named", InstallCause.ServerNameRefused),
        new("keeps that name for itself", InstallCause.ServerNameRefused),
        new("the hub cannot save the new server now", InstallCause.HubBusy),
        new("could not install tailscale", InstallCause.PrivateNetwork),
        new("no tailscale auth key", InstallCause.PrivateNetwork),
        new("tailscale did not join", InstallCause.PrivateNetwork),
        new("tailscale gave no address", InstallCause.PrivateNetwork),
        new("tailscale's service did not start", InstallCause.PrivateNetwork),
        new("this mac is not on your private network", InstallCause.PrivateNetwork),
        new("package lists could not be updated", InstallCause.Packages),
        new("the packages of this system could not be installed", InstallCause.Packages),
        new("firewall of this", InstallCause.Firewall),
        new("the firewall did not turn on", InstallCause.Firewall),
        new("the root helpers of this machine's agent users", InstallCause.AgentUsers),
        new("os users of this machine's agents", InstallCause.AgentUsers),
        new("the os user ", InstallCause.AgentUsers),
        new("the user services of ", InstallCause.AgentUsers),
        new("the agents of this machine could not be read", InstallCause.AgentUsers),
        new("vault of this", InstallCause.Vault),
        new("its vault did not install", InstallCause.Vault),
        new("fleet patch policy could not be written", InstallCause.Updates),
        new("the server service of this server could not be made", InstallCause.Service),
        new("could not write the fleet-", InstallCause.Service),
        new("did not start. look at", InstallCause.Service),
        new("fleet-hub is not running", InstallCause.Service),
        new("the hub is installed but it does not answer", InstallCause.Service),
        new("did not install for ", InstallCause.AgentProgram),
        new("claude code did not install", InstallCause.AgentProgram),
        new("codex did not install", InstallCause.AgentProgram),
    ];

    /// <summary>The cause of one stop sentence, without its mark: the first row that it holds, else
    /// <see cref="InstallCause.Other"/>.</summary>
    public static InstallCause Of(string sentence)
    {
        var said = sentence.Trim().ToLowerInvariant();
        return Rows.FirstOrDefault(row => row.Whole ? said == row.Part : said.Contains(row.Part, StringComparison.Ordinal))?.Cause
               ?? InstallCause.Other;
    }

    /// <summary>**The cause of the error that ended an install**: the installer's own stop sentence, read by the rows;
    /// null for every other stop.</summary>
    public static InstallCause? Of(Exception error)
    {
        if (error is not InstallError { Kind: InstallErrorKind.Step, Says: { } says } stopped ||
            InstallStops.Of(stopped) != InstallStop.InstallerStopped) return null;
        var mark = InstallPlan.StopMarks.FirstOrDefault(m => says.Contains(m, StringComparison.Ordinal));
        return mark is null ? null : Of(says[(says.LastIndexOf(mark, StringComparison.Ordinal) + mark.Length)..]);
    }
}
