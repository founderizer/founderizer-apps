using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Founderizer.Core;

namespace Founderizer.Owner.Vault;

/// <summary>Where the time of the last statement of each fleet is kept between starts.</summary>
public interface IGrantClockRecord
{
    long? Last(string fleet);
    void Keep(string fleet, long at);
}

/// <summary>The record in one JSON file of the app's folder, <c>{"&lt;fleet&gt;": &lt;at&gt;}</c> (the Mac's
/// <c>signedGrantClock</c> of its defaults). A file that does not read is no record: the next statement is dated now.</summary>
public sealed class GrantClockFile(string path) : IGrantClockRecord
{
    private readonly object gate = new();

    public long? Last(string fleet)
    {
        lock (gate) return Read().TryGetValue(fleet, out var at) ? at : null;
    }

    public void Keep(string fleet, long at)
    {
        lock (gate)
        {
            var all = Read();
            all[fleet] = at;
            KeptFile.Write(path, JsonSerializer.SerializeToUtf8Bytes(all, VaultJson.Default.DictionaryStringInt64));
        }
    }

    private Dictionary<string, long> Read()
    {
        try
        {
            return File.Exists(path) ? JsonSerializer.Deserialize(File.ReadAllBytes(path), VaultJson.Default.DictionaryStringInt64) ?? [] : [];
        }
        catch (JsonException)
        {
            return [];
        }
    }
}

/// <summary>**The time of the owner's next statement** for a fleet (the Mac's <c>GrantClock</c>): whole Unix seconds, and
/// one second after the last one this computer signed for it, or now when that is later. The central vault keeps a grant
/// statement only when it is newer than the one it holds for the same secret and agent, and two changes of one grant can
/// come in one second. **It is never <see cref="Ahead"/> or more after this computer's clock**: a last time from a clock
/// that ran ahead once is not followed, and the next statement is dated now.</summary>
public static class GrantClock
{
    /// <summary>One hour less than the central vault's <c>PIN_AHEAD</c> (one day), so that a statement is not refused for
    /// its time while the two clocks are no more than an hour apart.</summary>
    public const long Ahead = 86400 - 3600;

    private static readonly object Gate = new();

    public static long Next(string fleet, long now, IGrantClockRecord record)
    {
        lock (Gate)
        {
            var last = record.Last(fleet) ?? 0;
            var at = last >= now && last - now < Ahead ? last + 1 : now;     // no overflow, also for a damaged value
            record.Keep(fleet, at);
            return at;
        }
    }
}

/// <summary>A stop of a signature, in the owner's words, shown where the control shows its other problems: nothing was
/// signed and nothing was sent.</summary>
public sealed class SignStop(string words) : Exception(words);

/// <summary>The hub's clock and this PC's at the same read (Unix seconds).</summary>
public sealed record HubClock(double? HubTime, double? ReadAt);

/// <summary>**The owner's signature of each grant** (the Mac's <c>GrantSigning</c>, owner feature <c>signed_grants</c>). The
/// central vault seals a secret for a server only when the owner signed a grant of it to an agent there, or signed it into
/// the grantable pool, and only to a server whose key the owner pinned. The server of a grant is the one that the hub names
/// for the agent at the moment of the Give.
///
/// **The clock** (windows-app-plan-v2.md, 8.11). A give, a <c>pool</c> and a replace sign nothing while this PC's clock and
/// the hub's are more than an hour apart. A take-back and an <c>unpool</c> do not wait for it: their hub step came first,
/// and an end only narrows. Each read of the clocks is fresh (<see cref="VaultRoutes.ClockAsync"/>), where the Mac takes
/// its last read of the state: a hub that does not say its time now signs nothing here.
///
/// **The order** keeps the vault the narrower of the two: a grant is signed and sent before the hub's grant, and its end
/// after it (<see cref="SecretAccess"/>), so the vault seals no secret that team.json does not give. A hub that does not
/// offer <c>signed_grants</c> takes nothing here, and its controls work as before.
///
/// **The owner key is the caller's.** <c>ownerKey</c> gives the key that this PC holds for a fleet, or null; the caller
/// owns each key that it gives (the window's key store, U4, which keeps one key for each fleet and disposes it), and this
/// class never disposes one and keeps none past the call that signs.</summary>
public sealed class VaultSigning(IVaultCalls calls, Func<string, IOwnerKey?> ownerKey, IGrantClockRecord record)
{
    public const string Feature = "signed_grants";
    /// <summary>The hub's default of the grantable pool (owner API 1.328): <see cref="PoolsAsync"/> signs what it owes.</summary>
    public const string PoolDefaultFeature = "pool_default";
    /// <summary>The most pool statements of one round (the Mac's <c>CentralVaultModel.poolBatch</c>): the rest wait for the
    /// next round, which reads the hub's list again.</summary>
    public const int PoolBatch = 32;
    /// <summary>The door as a holder of the central vault: the agent and the machine of its grants.</summary>
    public const string DoorHolder = "door";

    public bool Offered => calls.Features.Contains(Feature);

    /// <summary>The same signatures over other calls: a form's, which are of one hub and one generation.</summary>
    internal VaultSigning On(IVaultCalls other) => new(other, ownerKey, record);

    /// <summary>A stop, in the pin's own words, while the two clocks are more than an hour apart.</summary>
    public async Task CheckClockAsync(CancellationToken cancel = default)
    {
        var clock = await VaultRoutes.ClockAsync(calls, cancel).ConfigureAwait(false);
        if (VaultPlan.ClockProblem(clock.HubTime, clock.ReadAt) is { } words) throw new SignStop(words);
    }

    /// <summary>The signed statement of one agent's grant of one secret, sent to the vault: <c>grant</c> with the agent's
    /// machine for a use or a read, <c>ungrant</c> for null.</summary>
    public async Task GrantAsync(SecretGrant? level, string reference, string agent, string agentLabel, CancellationToken cancel = default)
    {
        if (!Offered) return;
        if (level is not null) await CheckClockAsync(cancel).ConfigureAwait(false);
        var (fleet, key) = await OwnerAsync(cancel).ConfigureAwait(false);
        string? machine = null;
        if (level is not null)
        {
            // The door is no agent of the team: its grant names its own pinned key, and never a machine the hub names.
            machine = agent == DoorHolder ? DoorHolder
                : (await VaultRoutes.TeamAsync(calls, cancel).ConfigureAwait(false)).Team.LineOf(agent)?.Placement?.Machine;
            if (!VaultIds.IsMachine(machine)) throw new SignStop(VaultWords.NoServer(agentLabel));
        }
        var at = Next(fleet);
        var statement = machine is not null ? OwnerStatement.Grant(fleet, reference, agent, machine, at)
                                            : OwnerStatement.Ungrant(fleet, reference, agent, at);
        await VaultRoutes.SignedGrantAsync(calls, statement, key.Sign(statement), Guid.NewGuid(), cancel).ConfigureAwait(false);
    }

    /// <summary>The signed statement of one secret's place in the grantable pool: <c>pool</c> while the fleet manager may
    /// give it, <c>unpool</c> when only the owner gives it. A <c>pool</c> waits for the clock; an <c>unpool</c> does not.</summary>
    public async Task PoolAsync(bool inPool, string reference, CancellationToken cancel = default)
    {
        if (!Offered) return;
        if (inPool) await CheckClockAsync(cancel).ConfigureAwait(false);
        var (fleet, key) = await OwnerAsync(cancel).ConfigureAwait(false);
        var at = Next(fleet);
        var statement = inPool ? OwnerStatement.Pool(fleet, reference, at) : OwnerStatement.Unpool(fleet, reference, at);
        await VaultRoutes.SignedGrantAsync(calls, statement, key.Sign(statement), Guid.NewGuid(), cancel).ConfigureAwait(false);
    }

    /// <summary>**The pool statements that the hub's default owes the central vault, signed and sent by themselves** (the
    /// Mac's <c>GrantSigning.pools</c> and <c>CentralVaultModel.poolRound</c>, owner feature <c>pool_default</c>, owner API
    /// 1.328): <paramref name="due"/> is the reading's <see cref="VaultReading.PoolDue"/>, and the round of the vault (L6's
    /// <c>VaultRound</c>) calls this when its plan has no step. The vault seals a secret to a server only with the owner's
    /// signed grant or pool statement of it, so a give by the hub's default reaches its agent once this has run. It asks
    /// the owner nothing.
    ///
    /// The rules: nothing without both features; at most <see cref="PoolBatch"/> a round, the ends (<c>unpool</c>) first;
    /// a <c>default_pool</c> only while the two clocks agree, and an <c>unpool</c> also when they do not, because an end
    /// only narrows; one read of the fleet and of the owner key for the whole batch, and every statement signed before the
    /// first one goes; a signature that fails ends the signing, and the ones made before it go. A refusal of the vault
    /// (4xx: no value yet, a key that moves money, the owner's own unpool) goes on to the next statement; any other
    /// failure ends the batch, and the next round reads the hub's list again. Gives how many the hub took. It throws nothing
    /// but a cancel, as the Mac's: a failure of the key store or of the clock's file ends the round with its count.</summary>
    public async Task<int> PoolsAsync(IReadOnlyList<VaultPoolDue> due, CancellationToken cancel = default)
    {
        if (!Offered || !calls.Features.Contains(PoolDefaultFeature) || due.Count == 0) return 0;
        var batch = due.OrderBy(d => d.In).Take(PoolBatch).ToList();        // a stable order: the ends first
        bool clockGood;
        try
        {
            await CheckClockAsync(cancel).ConfigureAwait(false);
            clockGood = true;
        }
        catch (Exception e) when (e is SignStop or HubException or InvalidOperationException)
        {
            clockGood = false;
        }
        var owed = batch.Where(d => !d.In || clockGood).ToList();
        if (owed.Count == 0) return 0;
        string fleet;
        IOwnerKey key;
        try
        {
            (fleet, key) = await OwnerAsync(cancel).ConfigureAwait(false);
        }
        catch (Exception e) when (e is not OperationCanceledException)
        {
            return 0;           // no fleet, no answer, or a key store that failed in any way: nothing is signed
        }
        var made = new List<(string Statement, string Signature)>();
        foreach (var one in owed)
        {
            try
            {
                var at = Next(fleet);       // the clock's file can fail to read or to write
                var statement = one.In ? OwnerStatement.DefaultPool(fleet, one.Login, at) : OwnerStatement.Unpool(fleet, one.Login, at);
                made.Add((statement, key.Sign(statement)));
            }
            catch (Exception e) when (e is not OperationCanceledException)
            {
                break;          // the signing ends here, and the ones made before it go
            }
        }
        var sent = 0;
        foreach (var (statement, signature) in made)
        {
            try
            {
                await VaultRoutes.SignedGrantAsync(calls, statement, signature, Guid.NewGuid(), cancel).ConfigureAwait(false);
                sent++;
            }
            catch (HubException e) when (e is { Kind: HubErrorKind.Refusal, Status: >= 400 and < 500 } && !e.IsGenerationChanged)
            {
                // the vault refused this one: the next one goes on
            }
            catch (Exception e) when (e is not OperationCanceledException)
            {
                break;          // the hub, the network, a changed generation or a signature of no shape: the next round tries again
            }
        }
        return sent;
    }

    /// <summary>The owner's signed replace of one secret's value (owner feature <c>secret_replace</c>): the statement about
    /// this very sealed copy and its signature, for the intake that carries the copy. The central vault puts a new value
    /// under a reference that it holds only with them, so a PC that cannot sign sends no replace.</summary>
    public async Task<(string Statement, string Signature)> ReplaceAsync(string reference, string sealedCopy, CancellationToken cancel = default)
    {
        await CheckClockAsync(cancel).ConfigureAwait(false);
        var (fleet, key) = await OwnerAsync(cancel).ConfigureAwait(false);
        var statement = OwnerStatement.Replace(fleet, reference, OwnerStatement.Checksum(sealedCopy), Next(fleet));
        return (statement, key.Sign(statement));
    }

    /// <summary>This fleet's id, as the hub names it, and the owner key this PC holds for it.</summary>
    private async Task<(string Fleet, IOwnerKey Key)> OwnerAsync(CancellationToken cancel)
    {
        var fleet = (await VaultRoutes.ReadingAsync(calls, cancel).ConfigureAwait(false))?.FleetId ?? throw new SignStop(VaultWords.NoFleet);
        return (fleet, ownerKey(fleet) ?? throw new SignStop(VaultWords.NoOwnerKey));
    }

    private long Next(string fleet) => GrantClock.Next(fleet, calls.Now.ToUnixTimeSeconds(), record);
}

/// <summary>**One agent's access to one secret, in its one order**, for the save's steps and for each control that gives a
/// secret or takes it back: a give is signed for the central vault before the hub has it, and an end after the hub took it
/// back, so the vault's signed grants always include the hub's.</summary>
public static class SecretAccess
{
    public static async Task<GrantReceipt> ChangeAsync(IVaultCalls calls, VaultSigning signing, string reference, string agent, string agentLabel,
                                                       SecretGrant? level, CancellationToken cancel = default)
    {
        if (level is not null) await signing.GrantAsync(level, reference, agent, agentLabel, cancel).ConfigureAwait(false);
        var receipt = await VaultRoutes.GrantAsync(calls, reference, agent, level, Guid.NewGuid(), cancel).ConfigureAwait(false);
        if (level is null) await signing.GrantAsync(null, reference, agent, agentLabel, cancel).ConfigureAwait(false);
        return receipt;
    }
}
