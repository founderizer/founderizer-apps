using System;
using System.Collections.Generic;
using System.Linq;

namespace Founderizer.Owner.Vault;

/// <summary>**What this computer does about the fleet's central vault now** (the Mac's <c>VaultPlan</c>), decided from the
/// hub's reading (<c>GET /ui/vault</c>) and from what this computer knows itself. The app installs the vault, gives it a
/// recovery key and trusts each server by itself (the owner, 24 October 2026: "this should be automatically setup, even
/// under the hood if we dont need anything!"), and the Secrets page has a row only where he is the one who can move
/// things. One pure function, so that everything the app does without asking is written in one place and tested there.
///
/// Three rules bound it. A step that fails waits 10 minutes and is tried again, at most 6 times in a row, and then
/// waits for the owner. The install runs only while the hub reads no central vault and the fleet has an SSH connection on
/// record for the hub's own machine. And **a second computer never takes the vault over by itself**: when the vault
/// answers but this computer holds no owner key or no pin of the vault's key, or its pin is not the key the hub names,
/// nothing runs and only the owner's own Set up can act. The rounds that run the steps are piece L6's
/// (<c>Founderizer.Setup/RootJobs</c>).</summary>
public sealed record VaultPlan(VaultStep Step, VaultNeed? Vault = null, IReadOnlyList<VaultServerNeed>? Servers = null)
{
    /// <summary>The pin of each trusted machine is signed again when the one that the hub keeps is 7 days old, or when
    /// the hub keeps none.</summary>
    public const double PinRefresh = 7 * 86400;
    /// <summary>After a re-sign that succeeded, the next one of that machine waits a day.</summary>
    public const double ResignWait = 86400;
    /// <summary>A re-sign and the update never give up: after the sixth failure in a row their row shows, and they are
    /// tried again each hour.</summary>
    public const double RetryEvery = 3600;
    /// <summary>No pin and no grant is signed while this computer's clock and the hub's clock differ by more than this
    /// (windows-app-plan-v2.md, 8.11).</summary>
    public const double ClockSkew = 3600;

    // The Mac's words, with "PC" for this computer (rule 14).
    public const string ClockWords = "This PC's clock and the hub's clock differ by more than an hour.";
    public const string OtherKey = "The hub names another vault key than the one this PC pinned.";
    public const string OtherOwner = "The central vault on the hub's server holds another PC's owner key.";
    public const string RemovedHere = "You removed this server on this PC, so Founderizer does not trust its vault by itself. Select Try again to trust it.";

    /// <summary>The Founderizer Vault row: the central vault's update gave up after six tries (the Mac's
    /// <c>KeySwapWords.centralBehind</c>).</summary>
    public static string CentralBehind(string reason)
    {
        var text = reason.Trim();
        if (text.EndsWith('.')) text = text[..^1];
        return $"The central vault does not run the program of the hub's release yet: {text}.";
    }

    public IReadOnlyList<VaultServerNeed> ServerRows => Servers ?? [];

    public static readonly VaultPlan None = new(VaultStep.Nothing);

    /// <summary>Why this computer signs no pin and no grant now, or null: its clock and the hub's clock of its last state
    /// read (<paramref name="hubTime"/>, read at this computer's <paramref name="readAt"/>) differ by more than
    /// <see cref="ClockSkew"/>.</summary>
    public static string? ClockProblem(double? hubTime, double? readAt) =>
        hubTime is { } hub && readAt is { } read && Math.Abs(hub - read) > ClockSkew ? ClockWords : null;

    public static VaultPlan Of(VaultReading? reading, VaultFacts facts)
    {
        if (reading?.FleetId is null) return None;                       // no vault served, or no fleet named
        if (reading.Central is not { } central)
        {
            // The hub reads no vault: none was installed, or it is down. Only the app's own install runs, and it leaves
            // a vault that another computer's key holds as it is.
            if (facts.OtherOwner) return new VaultPlan(VaultStep.TakeOver, new VaultNeed.SetUp(OtherOwner));
            // another PC's owner key on this PC: no automatic install puts a new one in its place, only Set up (the Mac's
            // keyOtherMac, 61b264f33)
            if (facts.KeyOtherPc) return new VaultPlan(VaultStep.TakeOver, new VaultNeed.SetUp(null));
            if (facts.Install is { GivenUp: true } given) return new VaultPlan(VaultStep.Nothing, new VaultNeed.Retry(VaultStep.Install, given.Reason));
            if (!facts.HubOnRecord || !(facts.Install?.IsDue(facts.Now) ?? true)) return None;
            return new VaultPlan(VaultStep.Install);
        }
        if (!central.Ok || central.Recipient is not { } recipient) return None;
        if (!facts.KeyHeld || facts.Pin is not { } pin) return new VaultPlan(VaultStep.TakeOver, new VaultNeed.SetUp(null));
        if (pin != recipient) return new VaultPlan(VaultStep.TakeOver, new VaultNeed.SetUp(OtherKey));
        // Each server whose vault key is not pinned as it reports it now, unless this session's own pin of that very key
        // is still on its way into the hub's next reading. A server that the owner removed here gets no pin again.
        var open = reading.Machines.Where(m => facts.RemovedKnown && m.CanBeTrusted && !m.IsTrusted && !facts.Removed.Contains(m.Machine) &&
                                               facts.ConfirmedPins.GetValueOrDefault(m.Machine) != m.BrokerRecipient).ToList();
        // Each trusted server whose kept pin is missing or PinRefresh old, from a hub that says when its kept pin was
        // signed: signed again, at most once a day after a success.
        var stale = reading.Machines.Where(m => facts.RemovedKnown && m.IsTrusted && m.KeptPinKnown && !facts.Removed.Contains(m.Machine) &&
                                                (m.KeptPinAt is { } at ? facts.Now - at > PinRefresh : true) &&
                                                facts.Now - facts.SignedAt.GetValueOrDefault(m.Machine) >= ResignWait).ToList();
        var opened = open.Select(m => m.Machine).ToHashSet(StringComparer.Ordinal);
        var resigned = stale.Select(m => m.Machine).ToHashSet(StringComparer.Ordinal);
        var listed = reading.Machines.Where(m => opened.Contains(m.Machine) || resigned.Contains(m.Machine)).ToList();
        var gaveUp = listed.Select(m => facts.Servers.GetValueOrDefault(m.Machine) is { GivenUp: true } tries
                                       ? new VaultServerNeed(m.Machine, tries.Reason) : null)
                           .OfType<VaultServerNeed>().ToList();
        var marked = reading.Machines.Where(m => m.CanBeTrusted && facts.Removed.Contains(m.Machine)).Select(m => m.Machine)
                            .ToHashSet(StringComparer.Ordinal);
        var rows = reading.Machines.Select(m => marked.Contains(m.Machine) ? new VaultServerNeed(m.Machine, RemovedHere)
                                                : gaveUp.FirstOrDefault(g => g.Machine == m.Machine))
                          .OfType<VaultServerNeed>().ToList();
        var due = listed.Where(m => facts.Servers.GetValueOrDefault(m.Machine) is not { } tries || tries.IsDue(facts.Now) ||
                                    (resigned.Contains(m.Machine) && !opened.Contains(m.Machine) && tries.GivenUp &&
                                     facts.Now - tries.Last >= RetryEvery))
                        .Select(m => m.Machine).ToList();
        VaultNeed? vault = null;
        if (central.Recovery is null && facts.ConfirmedRecovery is null)
        {
            if (facts.Recovery is { GivenUp: true } given) vault = new VaultNeed.Retry(VaultStep.Recover, given.Reason);
            else if (facts.Recovery?.IsDue(facts.Now) ?? true) return new VaultPlan(VaultStep.Recover, null, rows);
        }
        // The vault runs another program than the hub's release: the install's root step again brings it up to date.
        if (facts.UpdateKnown && reading.ProgramBehind && facts.Update is { GivenUp: true } update)
        {
            var row = new VaultNeed.Retry(VaultStep.Update, CentralBehind(update.Reason));
            if (facts.Now - update.Last >= RetryEvery) return new VaultPlan(VaultStep.Update, vault ?? row, rows);
            vault ??= row;
        }
        else if (facts.UpdateKnown && reading.ProgramBehind && (facts.Update?.IsDue(facts.Now) ?? true))
        {
            return new VaultPlan(VaultStep.Update, vault, rows);
        }
        return new VaultPlan(due.Count == 0 ? VaultStep.Nothing : new VaultStep.Trust(due), vault, rows);
    }

    public bool Equals(VaultPlan? other) =>
        other is not null && Equals(Step, other.Step) && Equals(Vault, other.Vault) && ServerRows.SequenceEqual(other.ServerRows);

    public override int GetHashCode() => HashCode.Combine(Step, Vault, ServerRows.Count);
}

/// <summary>One step of the plan.</summary>
public abstract record VaultStep
{
    public static readonly VaultStep Nothing = new Named("nothing");
    /// <summary>The install of the central vault, as root on the hub's machine over this computer's SSH connection.</summary>
    public static readonly VaultStep Install = new Named("install");
    /// <summary>A recovery code made and kept in this computer's secret box, and its key signed and sent to the vault.</summary>
    public static readonly VaultStep Recover = new Named("recover");
    /// <summary>The install's root step again, because the vault runs another program than the hub's release.</summary>
    public static readonly VaultStep Update = new Named("update");
    /// <summary>Nothing runs: the vault is not this computer's to act on, and only the owner's Set up takes it over.</summary>
    public static readonly VaultStep TakeOver = new Named("take_over");

    public sealed record Named(string Name) : VaultStep;

    /// <summary>These servers' vault keys read over SSH, and each one pinned when it is the key the hub reports.</summary>
    public sealed record Trust(IReadOnlyList<string> Machines) : VaultStep
    {
        public bool Equals(Trust? other) => other is not null && Machines.SequenceEqual(other.Machines);
        public override int GetHashCode() => Machines.Count;
    }
}

/// <summary>The Founderizer Vault row of the Secrets page.</summary>
public abstract record VaultNeed
{
    /// <summary>An automatic step gave up: the step that Retry runs once more, and the reason of its last try.</summary>
    public sealed record Retry(VaultStep Step, string Reason) : VaultNeed;
    /// <summary>Set up takes the vault over on this computer; with a reason when there is more to say.</summary>
    public sealed record SetUp(string? Reason) : VaultNeed;
}

/// <summary>A server row of the Secrets page: the automatic trust gave up on it, or the owner removed it here.</summary>
public sealed record VaultServerNeed(string Machine, string Reason);

/// <summary>The tries of one automatic step: how many failed in a row, when the last one did, and why.</summary>
public sealed record VaultTries(int Failures, double Last, string Reason)
{
    /// <summary>A step that failed is tried again after 10 minutes, at most 6 times in a row.</summary>
    public const double Wait = 600;
    public const int Most = 6;

    public bool GivenUp => Failures >= Most;
    public bool IsDue(double now) => !GivenUp && now - Last >= Wait;

    public static VaultTries Failed(VaultTries? earlier, double now, string reason) => new((earlier?.Failures ?? 0) + 1, now, reason);
}

/// <summary>What this computer knows itself, beside the hub's reading (the Mac's <c>VaultFacts</c>).</summary>
public sealed record VaultFacts
{
    /// <summary>This computer holds an owner key for the reading's fleet.</summary>
    public required bool KeyHeld { get; init; }
    /// <summary>This computer's pin of the vault's key: what the install printed on the hub's machine.</summary>
    public required string? Pin { get; init; }
    /// <summary>The fleet has an SSH connection on record for the hub's own machine.</summary>
    public required bool HubOnRecord { get; init; }
    public bool OtherOwner { get; init; }
    /// <summary>This PC holds for the fleet an owner key that it cannot open, now or later (the Mac's <c>keyOtherMac</c>,
    /// a Mac that Migration Assistant or a restore made; on a PC the key store's <c>Gone</c>, U4). Only the owner's Set up
    /// replaces it.</summary>
    public bool KeyOtherPc { get; init; }
    public string? ConfirmedRecovery { get; init; }
    public IReadOnlyDictionary<string, string> ConfirmedPins { get; init; } = new Dictionary<string, string>();
    public IReadOnlyDictionary<string, double> SignedAt { get; init; } = new Dictionary<string, double>();
    public VaultTries? Install { get; init; }
    public VaultTries? Recovery { get; init; }
    public IReadOnlyDictionary<string, VaultTries> Servers { get; init; } = new Dictionary<string, VaultTries>();
    public VaultTries? Update { get; init; }
    public IReadOnlySet<string> Removed { get; init; } = new HashSet<string>();
    public bool RemovedKnown { get; init; } = true;
    public bool UpdateKnown { get; init; } = true;
    public required double Now { get; init; }
}
