using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using Founderizer.Core;
using Founderizer.Remote;
using Founderizer.Setup.Install;
using Founderizer.Setup.Network;

namespace Founderizer.Setup.RootJobs;

/// <summary>One server whose vault key the owner's computer reads and pins: its name in the fleet, the key that the hub
/// reports for it, how the PC reaches it (<see cref="ServerRecords.Target"/> with <c>rootOnly</c> false: the trust step
/// decides the user itself), the server's <c>kind</c> in the hub's list, and whether the connection is one that this PC
/// keeps from its own install (not the hub's record).</summary>
public sealed record PinAsk(string Machine, string Reported, InstallTarget Target, string? Kind = "linux", bool Kept = false);

/// <summary>How the trust step reads one server's vault key (the Mac's <c>CentralVaultRemote.TrustRead</c>).</summary>
public enum TrustRead
{
    /// <summary>As root, through <c>sudo -n</c> for a kept user that is not root: a Linux server's broker key file.</summary>
    Root,
    /// <summary>As the connection's own user, with no <c>sudo</c>: a Mac's Founderizer Vault, which serves the agents' user.</summary>
    Agents,
}

/// <summary>What the trust of one server gave: the signed pin, or the one reason that it stopped.</summary>
public abstract record PinOutcome
{
    private PinOutcome() { }

    /// <summary>The statement and the owner key's signature of it, for <c>POST /ui/vault/pin</c>, and the key it
    /// pins.</summary>
    public sealed record Signed(string Statement, string Signature, string Recipient) : PinOutcome;
    /// <summary>Why this server got no pin, in the owner's words.</summary>
    public sealed record Stop(string Says) : PinOutcome;
}

/// <summary>**The pin of one server's vault key, read over the owner's own SSH connection** (the Mac's
/// CentralVaultRemote.readBrokerKey and CentralVaultModel.trust): a Linux server's key is read as root from its broker's
/// configuration, and only the line that is its public key can leave the machine; a Mac's is Founderizer Vault's own
/// <c>status</c>, asked as the user it serves, with no <c>sudo</c>. It takes plain values (an address, a key's text, the
/// owner key's signer) and names nothing of the vault's other pieces.
///
/// **The key is read and pinned only where this PC's own Tailscale says that the connection's address is that server**: the
/// address can come from the hub's record, and the host key must be one that the PC knows already
/// (<see cref="HostKeyRule.Known"/>), because a pin is only as good as the machine it was read from.</summary>
public static class VaultPins
{
    /// <summary>The read of one server's vault key, as root: the path that its configuration names, and the one line of that
    /// file that is its public key. Only that line can leave the machine (the Mac's, byte for byte).</summary>
    public const string ReadBrokerKey =
        "k=$(python3 -c 'import json; print(json.load(open(\"/etc/fleet-vault/vault.json\"))[\"age_key\"])')"
        + " && grep -m1 -E '^# public key: age1[0-9a-z]{58}$' \"$k\"";

    /// <summary>The read of a Mac's vault key: Founderizer Vault's own <c>status</c>, asked through its socket by the user it
    /// serves, with no <c>sudo</c> (the Mac's, byte for byte).</summary>
    public const string ReadMacVaultKey =
        "python3 -c 'import json, os, socket; s = socket.socket(socket.AF_UNIX); s.settimeout(10); "
        + "s.connect(os.path.expanduser(\"~/Library/Application Support/AgentFleet/vault.sock\")); "
        + "s.sendall(b\"{\\\"v\\\": 2, \\\"op\\\": \\\"status\\\"}\\n\"); "
        + "print(\"# public key: \" + str(json.loads(s.makefile().readline()).get(\"recipient\")))'";

    /// <summary>The time limit of one read (the Mac's <c>timeout: 120</c>).</summary>
    public static readonly TimeSpan ReadLimit = TimeSpan.FromSeconds(120);

    /// <summary>The vault key in what the read printed, or null when it printed none or more than one.</summary>
    public static string? BrokerKey(string output)
    {
        const string word = "# public key: ";
        var keys = output.Split('\n', StringSplitOptions.RemoveEmptyEntries).Select(RootJob.Trimmed)
                         .Where(l => l.StartsWith(word, StringComparison.Ordinal)).Select(l => l[word.Length..])
                         .Where(AgeRecipient.IsValid).Distinct(StringComparer.Ordinal).ToList();
        return keys.Count == 1 ? keys[0] : null;
    }

    /// <summary>**The trust of one server: its key read over SSH, and its pin signed when it is the key the hub reports.**
    /// <paramref name="tailscaleStatus"/>: this PC's own <c>tailscale status --json</c>, or null when Tailscale does not
    /// answer. <paramref name="clockProblem"/>: why no pin is signed now (the PC's clock and the hub's differ by more than an
    /// hour), or null. <paramref name="run"/> runs one program on the server as root, with its time limit, and gives its
    /// answer, or throws when the call could not start. <paramref name="at"/>: the time of the statement, in seconds since
    /// 1970. The key is read only for a server that the PC's own Tailscale names, and a statement is signed only for a key
    /// that was read there.</summary>
    public static async Task<PinOutcome> TrustAsync(PinAsk ask, string fleet, string? tailscaleStatus, string? clockProblem,
                                                    IOwnerKey key, long at,
                                                    Func<InstallTarget, string, TimeSpan, Task<RootCall.Answer>> run)
    {
        if (clockProblem is not null) return new PinOutcome.Stop(clockProblem);
        if (TailnetNodes.Peer(ask.Target.Host, tailscaleStatus) is not { } peer || peer.Name != ask.Machine)
            return new PinOutcome.Stop(TailscaleSaysOther(ask.Target.Host, ask.Machine));
        if (ReadOf(ask.Kind, peer.Os, ask.Target.User, ask.Kept) is not { } read) return new PinOutcome.Stop(NoConnection(ask.Machine));
        // A Mac's agents run as a person's own user: its vault is asked as that user, with no sudo.
        var mac = read == TrustRead.Agents;
        var target = mac ? ask.Target with { BecomeRoot = false } : ask.Target;
        var answer = await run(target, mac ? ReadMacVaultKey : ReadBrokerKey, ReadLimit).ConfigureAwait(false);
        if (BrokerKey(answer.Output) is not { } found) return new PinOutcome.Stop(Unread(answer.Failure, ask.Machine));
        if (found != ask.Reported)
            return new PinOutcome.Stop(OtherVaultKey(ask.Machine));
        var statement = OwnerStatement.Pin(fleet, ask.Machine, found, at);
        return new PinOutcome.Signed(statement, key.Sign(statement), found);
    }

    /// <summary>**How the trust step reads a server's vault key, or null when it reads nothing there** (the Mac's
    /// <c>CentralVaultRemote.trustRead</c>, R2-M1 of the validation of 23 November 2026). A server is a Mac for this step
    /// only when the hub's list says so (<paramref name="kind"/>) and this PC's own Tailscale says so too
    /// (<paramref name="os"/>: the <c>OS</c> of the node, which on a Linux server comes from root's <c>tailscaled</c>, so that
    /// neither an agent nor the hub sets it); then the read is the agents' user's. Each other server is read as root, and a
    /// user of the fleet's record that is not root (<paramref name="kept"/> false) is no connection: a hub that is broken
    /// into calls a Linux server a Mac and names an agent's OS user, whose forced command prints the agent's key. A Mac that
    /// the hub calls Linux reads as root, and stops.</summary>
    public static TrustRead? ReadOf(string? kind, IReadOnlySet<string> os, string user, bool kept)
    {
        if (kind == "mac" && os.Count == 1 && os.Contains("macOS")) return TrustRead.Agents;
        return kept || user == "root" ? TrustRead.Root : null;
    }

    /// <summary>What an answer over SSH says when it lacks the vault key: the host key that the PC does not know (the vault's
    /// steps check it strictly), or the plain words. The PC has no console, so it names no <c>ssh</c>: for an unknown or a
    /// changed host key the words of <see cref="ServerCheck"/> stand.</summary>
    internal static string Unread(RemoteFailure? failure, string machine) => failure switch
    {
        RemoteFailure.HostKeyUnknown => ServerCheck.HostKeyUnknown(machine, firstRun: false),
        RemoteFailure.HostKeyChanged => ServerCheck.HostKeyChanged(machine, firstRun: false),
        _ => CannotRead(ItsVaultKey, machine),
    };

    /// <summary>The Mac's words, with "PC" (rule 14): a view file of the Mac holds them, so a test holds each one to the
    /// Mac's string catalog.</summary>
    internal const string ItsVaultKey = "its vault key";
    internal static string CannotRead(string what, string machine) => $"Founderizer could not read {what} on {machine}.";
    internal static string TailscaleSaysOther(string host, string machine) =>
        $"This PC's Tailscale does not say that {host} is {machine}. Founderizer pinned nothing.";
    internal static string OtherVaultKey(string machine) =>
        $"The vault key on {machine} is not the one the hub reports for it. Founderizer pinned nothing.";
    internal static string NoConnection(string machine) =>
        $"The fleet has no SSH connection to {machine} on record. Record one on its page in Servers.";
}
