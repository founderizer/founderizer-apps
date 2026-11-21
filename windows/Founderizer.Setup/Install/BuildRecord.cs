using System;
using System.Collections.Generic;
using System.Linq;

namespace Founderizer.Setup.Install;

/// <summary>The stage that a build reached: the provider was asked for the server, or it made it and this PC waits for
/// it on the private network.</summary>
public enum BuildStage { Making, Joining }

/// <summary>How a build stands or ended. <c>Interrupted</c> is never written.</summary>
public enum BuildOutcome { Running, Joined, Stopped, Cancelled, Interrupted }

/// <summary>**What the build left at the provider, as far as this PC knows** (the Mac's BuildRecord.AtProvider). Which
/// error of a provider's call leaves which is the providers' piece (L2): it gives the value to
/// <see cref="BuildRecord.CallEnded"/>.</summary>
public enum AtProvider
{
    /// <summary>The call has no answer that this PC knows: a server can be there.</summary>
    NotKnown,
    /// <summary>Nothing: the call was not sent, the provider refused it, or the app deleted what the provider made.</summary>
    Nothing,
    /// <summary>A step failed after the provider made something, and the app could not delete all of it.</summary>
    LeftBehind,
    /// <summary>The server is at the provider.</summary>
    Server,
}

/// <summary>**One server that this PC asked a provider to make, kept after its page is gone** (the Mac's BuildRecord):
/// a server that was made and never joined exists at its provider and is billed. A record exists only from the moment
/// the call for the server begins. The server's name and the provider's id stay on this PC, for the owner's own eyes.
/// The provider and the use are kept by their names ("hetzner", "hub"), as the Mac's file has them.</summary>
public sealed record BuildRecord : Founderizer.Setup.FirstRun.IKeptRecord<BuildRecord>
{
    public Guid Id { get; init; } = Guid.NewGuid();
    public string Launch { get; init; } = "";
    public string Provider { get; init; } = "";
    public string Use { get; init; } = "";
    /// <summary>The address of the hub that the server was made for; a first run's server has none until it is on the
    /// private network.</summary>
    [System.Text.Json.Serialization.JsonInclude]
    public string? Hub { get; internal set; }
    public string Name { get; init; } = "";
    [System.Text.Json.Serialization.JsonInclude]
    public string? ServerId { get; internal set; }
    [System.Text.Json.Serialization.JsonInclude]
    public BuildStage Stage { get; internal set; } = BuildStage.Making;
    [System.Text.Json.Serialization.JsonInclude]
    public AtProvider AtProvider { get; internal set; } = AtProvider.NotKnown;
    /// <summary>The private network's own list had the server, and this PC did not see it.</summary>
    [System.Text.Json.Serialization.JsonInclude]
    public bool OnNetwork { get; internal set; }
    public DateTimeOffset Began { get; init; }
    [System.Text.Json.Serialization.JsonInclude]
    public DateTimeOffset? MadeAt { get; internal set; }
    [System.Text.Json.Serialization.JsonInclude]
    public string? Type { get; internal set; }
    [System.Text.Json.Serialization.JsonInclude]
    public decimal? MonthlyPrice { get; internal set; }
    [System.Text.Json.Serialization.JsonInclude]
    public string? Currency { get; internal set; }
    [System.Text.Json.Serialization.JsonInclude]
    public DateTimeOffset? Ended { get; internal set; }
    [System.Text.Json.Serialization.JsonInclude]
    public BuildOutcome Outcome { get; internal set; } = BuildOutcome.Running;

    /// <summary>The provider is asked for the server now.</summary>
    public static BuildRecord Begin(string provider, string use, string? hub, string name, string launch, DateTimeOffset at) =>
        new() { Provider = provider, Use = use, Hub = hub, Name = name, Launch = launch, Began = at };

    /// <summary>The provider answered with the server: it exists there, and this PC waits for it on the network.</summary>
    public BuildRecord Made(string id, DateTimeOffset at, string? type = null, decimal? monthlyPrice = null, string? currency = null)
    {
        if (Outcome != BuildOutcome.Running || Stage != BuildStage.Making) return this;
        return this with { ServerId = id, Stage = BuildStage.Joining, AtProvider = AtProvider.Server, MadeAt = at, Type = type,
                           MonthlyPrice = monthlyPrice, Currency = currency };
    }

    /// <summary>The call for the server ended with an error: what it left at the provider. Only for the call itself.</summary>
    public BuildRecord CallEnded(AtProvider left) =>
        Outcome != BuildOutcome.Running || Stage != BuildStage.Making ? this : this with { AtProvider = left };

    /// <summary>This PC saw the server on the private network, or a later install proved it: it is at the provider.
    /// <paramref name="hub"/>: for a first run's server, the address that its hub will have.</summary>
    public BuildRecord Joined(DateTimeOffset at, string? hub = null)
    {
        if (Outcome == BuildOutcome.Joined) return this;
        return this with { Outcome = BuildOutcome.Joined, AtProvider = AtProvider.Server,
                           Hub = Hub is null && !string.IsNullOrEmpty(hub) ? hub : Hub, Ended = at };
    }

    /// <summary>The build ended with no join that this PC saw: it stopped, or its page ended it.</summary>
    public BuildRecord End(DateTimeOffset at, bool cancelled = false, bool onNetwork = false) =>
        Outcome != BuildOutcome.Running ? this
            : this with { Outcome = cancelled ? BuildOutcome.Cancelled : BuildOutcome.Stopped, OnNetwork = onNetwork, Ended = at };

    /// <summary>**The server can stand at its provider with no place in a fleet**: this PC never saw it join, and the
    /// build did not leave nothing there.</summary>
    [System.Text.Json.Serialization.JsonIgnore]
    public bool IsUnjoined => Outcome is BuildOutcome.Stopped or BuildOutcome.Cancelled or BuildOutcome.Interrupted &&
                              AtProvider != AtProvider.Nothing;

    /// <summary>The provider answered with the server's id, so it exists there for sure.</summary>
    [System.Text.Json.Serialization.JsonIgnore]
    public bool IsMade => ServerId is not null;

    /// <summary>The newest time in the record.</summary>
    [System.Text.Json.Serialization.JsonIgnore]
    public DateTimeOffset LastChange => new[] { Began, MadeAt ?? Began, Ended ?? Began }.Max();

    /// <summary>The same record as a later start reads it when it says that its work runs: cut off.</summary>
    public BuildRecord CutOff() => this with { Outcome = BuildOutcome.Interrupted };

    /// <summary>The record says that its work runs.</summary>
    [System.Text.Json.Serialization.JsonIgnore]
    public bool Runs => Outcome == BuildOutcome.Running;

    /// <summary>**The names that a new server of this PC must not take**: of each build that did not join, left
    /// something at its provider (or does not know yet) and began less than <paramref name="life"/> ago (the Mac's
    /// CloudServers.joinKeyLife with StartAgain.deviceSlack, which the providers' piece gives).</summary>
    public static IReadOnlyList<string> NamesInUse(IEnumerable<BuildRecord> records, DateTimeOffset now, TimeSpan life) =>
        records.Where(r => r.Outcome != BuildOutcome.Joined && r.AtProvider != AtProvider.Nothing && now - r.Began < life)
               .Select(r => r.Name).ToList();
}
