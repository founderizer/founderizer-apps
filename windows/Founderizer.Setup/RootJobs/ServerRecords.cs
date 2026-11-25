using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Net;
using System.Net.Sockets;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using Founderizer.Owner.Reads;
using Founderizer.Setup.Install;

namespace Founderizer.Setup.RootJobs;

/// <summary>**How the fleet itself says one machine is reached** (the Mac's MachineReach): its private address, and the
/// user and the port of its record. A machine whose record is none has an address and no user.</summary>
public sealed partial record MachineReach(string? Address, string? User = null, int? Port = null)
{
    /// <summary>A whole connection, or null while the fleet is missing any part of one. A port outside 1…65535 and a user
    /// that is not a user name are read as missing, because the hub's record is data and not an instruction.</summary>
    public (string Address, string User, int Port)? OnRecord =>
        Address is { Length: > 0 } address && User is { } user && UserShape().IsMatch(user) && Port is >= 1 and <= 65535
            ? (address, user, Port.Value)
            : null;

    /// <summary>**A kept connection, at an address that still answers**: the installers let SSH into a Linux machine of a
    /// fleet over the private network only, so a connection that the PC kept with a public address goes to the private
    /// address that the fleet reports, with its own user and port. A name, a LAN address and a private address stay.</summary>
    public InstallTarget Reaching(InstallTarget kept) =>
        Address is { } address && ClaimCode.IsPrivateAddress(address) && IsPublicAddress(kept.Host) ? kept with { Host = address } : kept;

    /// <summary>The fleet's record for one machine, out of the readings of the agents on it, or null while the hub has not
    /// reported that machine at all.</summary>
    public static MachineReach? Of(string machine, IEnumerable<MachineAccess> readings) =>
        readings.FirstOrDefault(r => r.Machine == machine)?.Reach;

    /// <summary>**What a server's own row of the list of servers says of the fleet's record of it** (owner API 1.173; the
    /// Mac's <c>ServerEntry.reach</c>), with the row's own address. A record that is none (the row's <c>ssh</c> is null) is a
    /// reach with no user. Null when the row says nothing: a row without the key (a hub before that version), and a row
    /// whose value the PC cannot use as a connection.</summary>
    public static MachineReach? Row(ServerEntry server)
    {
        if (server.Access is not { ValueKind: JsonValueKind.Object } access || !access.TryGetProperty("ssh", out var ssh)) return null;
        if (ssh.ValueKind == JsonValueKind.Null) return new MachineReach(server.Address);
        if (ssh.ValueKind != JsonValueKind.Object) return null;
        string? user = null;
        int? port = null;
        if (ssh.TryGetProperty("user", out var name) && name.ValueKind != JsonValueKind.Null)
        {
            if (name.ValueKind != JsonValueKind.String) return null;
            user = name.GetString();
        }
        if (ssh.TryGetProperty("port", out var number) && number.ValueKind != JsonValueKind.Null)
        {
            if (number.ValueKind != JsonValueKind.Number || !number.TryGetInt32(out var value)) return null;
            port = value;
        }
        var said = new MachineReach(server.Address, user, port);
        return said.OnRecord is { } whole && new InstallTarget(whole.Address, whole.User, whole.Port).IsValid ? said : null;
    }

    [GeneratedRegex(@"\A[a-z_][a-z0-9_-]{0,31}\z", RegexOptions.CultureInvariant)]
    private static partial Regex UserShape();

    /// <summary>A public address of the internet (the Mac's <c>InstallTarget.isPublicAddress</c>): a kept connection at one
    /// lets no SSH in once the machine's installer has run. A name is not one.</summary>
    internal static bool IsPublicAddress(string host)
    {
        if (!IPAddress.TryParse(host, out var address)) return false;
        var b = address.GetAddressBytes();
        if (address.AddressFamily == AddressFamily.InterNetwork)
        {
            // The Mac's own reader takes the plain four numbers only, and not a number in another form.
            if (address.ToString() != host) return false;
            return !(b[0] is 0 or 10 or 127 || b[0] >= 224 || (b[0] == 100 && b[1] is >= 64 and <= 127) || (b[0] == 169 && b[1] == 254) ||
                     (b[0] == 172 && b[1] is >= 16 and <= 31) || (b[0] == 192 && b[1] == 168));
        }
        return address.AddressFamily == AddressFamily.InterNetworkV6 && (b[0] & 0xe0) == 0x20;
    }
}

/// <summary>One machine's record as the list of machines names it (<c>GET /ui/machines</c>): its private address, and the
/// SSH user and port of its <c>access</c>, or null (the machine's own page has none).</summary>
public sealed record MachineAccess(string Machine, string? Address, string? SshUser = null, int? SshPort = null)
{
    public MachineReach Reach => new(Address, SshUser, SshPort);
}

/// <summary>The hub's record of its own server (<c>GET /ui/vault</c>, its <c>hub</c>): its machine, its address and how the
/// fleet reaches it.</summary>
public sealed record OwnServer(string Machine, string? Address, string? SshUser = null, int? SshPort = null)
{
    public MachineReach Reach => new(Address, SshUser, SshPort);
}

/// <summary>What the fleet has on record of how it reaches one server (the Mac's OwnerKeyPlan.Record).</summary>
public abstract record FleetRecord
{
    private FleetRecord() { }

    public sealed record Reach(MachineReach Machine) : FleetRecord;
    /// <summary>The pages that hold the record answered, and it is no whole connection.</summary>
    public sealed record None : FleetRecord;
    /// <summary>A page did not answer, and no page that answered names the server: nothing is known.</summary>
    public sealed record Unknown : FleetRecord;

    /// <summary>**The record of one server, out of the three pages that can hold it** (the Mac's <c>record(server:…)</c>). A
    /// page that names the server gives the fleet's record, whole or not: the list of machines first, then the server's row of
    /// the list of servers, then the hub's own page. A page that did not answer says nothing.</summary>
    public static FleetRecord Of(string server, MachineReach? listed, bool listRead, MachineReach? row, OwnServer? own, bool ownRead) =>
        Named(server, listed, row, own) is { } named
            ? named.OnRecord is not null ? new Reach(named) : new None()
            : listRead && ownRead ? new None() : new Unknown();

    /// <summary>What the first page that names the server says of it, whole or not; null when no page names it.</summary>
    public static MachineReach? Named(string server, MachineReach? listed, MachineReach? row, OwnServer? own) =>
        listed ?? row ?? (own is not null && own.Machine == server ? own.Reach : null);

    /// <summary>**The reads, in their order, and what they give**: the list of machines, or null when it did not answer;
    /// and the hub's own page, read only when neither the list nor the row names the server.</summary>
    public static async Task<FleetRecord> OfAsync(string server, MachineReach? row, Func<Task<IReadOnlyList<MachineAccess>?>> machines,
                                                  Func<Task<OwnServer?>> own)
    {
        var list = await machines().ConfigureAwait(false);
        var listed = list is null ? null : MachineReach.Of(server, list);
        OwnServer? named = null;
        var ownRead = false;
        if (listed is null && row is null)
        {
            try
            {
                named = await own().ConfigureAwait(false);
                ownRead = true;
            }
            catch (Exception e) when (e is not OutOfMemoryException) { }
        }
        return Of(server, listed, list is not null, row, named, ownRead);
    }
}

/// <summary>**The connection to each server of the hub's list, for one round of a step that the owner's computer runs by
/// itself as root there** (the Mac's ServerRecords; the owner's access line and the join's hardening). Such a step reaches
/// a server with the connection that the PC keeps from an install, else with the fleet's own record of that server: in the
/// list of machines for a server that an agent runs on, on the server's own row of the list of servers (a server that joined
/// and runs no agent yet), and in the vault's page for the hub's own server with no agent. The list is read once in a round,
/// at the first server that needs it; a read of it that did not answer is made again for the next server.
/// <paramref name="keptOf"/> gives the connection that the PC keeps for a server from its install, or null.</summary>
public sealed class ServerRecords(Func<Task<IReadOnlyList<MachineAccess>?>> machines, Func<Task<OwnServer?>> own,
                                  Func<ServerEntry, InstallTarget?>? keptOf = null)
{
    private readonly SemaphoreSlim gate = new(1, 1);
    private IReadOnlyList<MachineAccess>? list;

    /// <summary>The fleet's record of one server of the hub's list. <paramref name="isHub"/>: the list of servers says that it
    /// is the hub's own server; <paramref name="row"/>: what the server's own row says (<see cref="MachineReach.Row"/>), null
    /// when it says nothing.</summary>
    public async Task<FleetRecord> RecordAsync(string server, bool isHub, MachineReach? row = null)
    {
        await gate.WaitAsync().ConfigureAwait(false);
        IReadOnlyList<MachineAccess>? machinesRead;
        try
        {
            list ??= await machines().ConfigureAwait(false);
            machinesRead = list;
        }
        finally { gate.Release(); }
        if (isHub) return await FleetRecord.OfAsync(server, row, () => Task.FromResult(machinesRead), own).ConfigureAwait(false);
        return FleetRecord.Of(server, machinesRead is null ? null : MachineReach.Of(server, machinesRead), machinesRead is not null,
                              row, null, ownRead: true);
    }

    /// <summary>**The connection to one server**, or the reason there is none (<see cref="RootUnreached"/>).
    /// <paramref name="kept"/>: the connection that the PC keeps for it from an install, and with one no page is read. It is
    /// not for a root job: only <see cref="RootConnectionAsync"/> gives one its connection.</summary>
    internal async Task<InstallTarget> ConnectionAsync(ServerEntry server, InstallTarget? kept)
    {
        MachineReach? record = null;
        if (kept is null)
            switch (await RecordAsync(server.Name, server.Hub, MachineReach.Row(server)).ConfigureAwait(false))
            {
                case FleetRecord.Reach reach: record = reach.Machine; break;
                case FleetRecord.None: throw RootUnreached.NoConnection();
                default: throw RootUnreached.RecordNotRead();
            }
        return Target(server, kept, record) ?? throw RootUnreached.NoConnection();
    }

    /// <summary>**The connection to one server for a root job, only at an address that this PC's own Tailscale names as
    /// that server** (the Mac's <c>OwnerAccessModel.connection</c>, 22 November 2026): the address can come from the hub's
    /// record, and each job runs as root and reads its answer back. A Linux server lets SSH in on its Tailscale address
    /// only, so a server that answers anywhere else is not reached. The address is the connection's, never the row's.
    /// <paramref name="tailscaleStatus"/>: this PC's <c>tailscale status --json</c>, null when Tailscale does not answer.</summary>
    public async Task<InstallTarget> RootConnectionAsync(ServerEntry server, string? tailscaleStatus)
    {
        var target = await ConnectionAsync(server, keptOf?.Invoke(server)).ConfigureAwait(false);
        if (TailnetNodes.DeviceOf(target.Host, tailscaleStatus) != server.Name) throw RootUnreached.NotThatServer();
        return target;
    }

    /// <summary>**How the owner's computer reaches one server as root**: the connection that it keeps for it from its install,
    /// at the private address that the fleet reports, else the fleet's own record of the server. A kept user who is not root
    /// becomes root with <c>sudo -n</c>, so nothing waits for a password. A record that is not a whole connection, or not one
    /// that <c>ssh</c> can take, is none. **A record's user other than root is none for a root step**
    /// (<paramref name="rootOnly"/>; the Mac's validation of 23 November 2026): that user owns its <c>authorized_keys</c>,
    /// so a line there with a forced command prints what it likes for the whole session, the <c>sudo</c> and root's read
    /// included, and the hub writes that record. <paramref name="rootOnly"/> false only for a step that reads as that user
    /// anyway (the key registration reads the proof file as its owner).</summary>
    public static InstallTarget? Target(ServerEntry server, InstallTarget? kept, MachineReach? record, bool rootOnly = true)
    {
        if (kept is not null) return new MachineReach(server.Address).Reaching(kept with { BecomeRoot = kept.User != "root" });
        if (record?.OnRecord is not { } known || (rootOnly && known.User != "root")) return null;
        var target = new InstallTarget(known.Address, known.User, known.Port, BecomeRoot: known.User != "root");
        return target.IsValid ? target : null;
    }
}
