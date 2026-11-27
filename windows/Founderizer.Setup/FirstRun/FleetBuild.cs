using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using Founderizer.Setup.Cloud;
using Founderizer.Setup.Install;
using Founderizer.Setup.Network;

namespace Founderizer.Setup.FirstRun;

/// <summary>**One server's line on the first run's build page** (the Mac's FleetCore/FleetBuild.swift; the owner's "that
/// is brilliant!" of 16 November 2026): what runs there now in a few words, the minutes left, and a bar of four parts
/// (<see cref="InstallPhases.Names"/>), each from 0 to 1. The owner's turn, the manager's sign-in, has its words in the
/// dot's orange and no minutes; a server that is ready shows none of the three.</summary>
public sealed record FleetBuildRow(string? Words, int? Minutes, IReadOnlyList<double>? Parts, bool OwnersTurn)
{
    /// <summary>The seconds of a provider's build before its install: about 75 from the press to the server on the
    /// private network, the last 30 of them the server that starts and comes on that network.</summary>
    public const int BuildSeconds = 75, StartSeconds = 30;
    /// <summary>The bar's first part once the provider's server starts.</summary>
    public const double StartShare = 0.6;

    /// <summary>The provider makes the server, or the server starts and comes on the private network.</summary>
    public static FleetBuildRow Building(bool joining, IReadOnlyList<string> plan) =>
        new(joining ? "Starting your server" : "Making your server", MinutesOf((joining ? StartSeconds : BuildSeconds) + SecondsOf(plan)),
            [joining ? StartShare : 0.2, 0, 0, 0], false);

    /// <summary>The manager's own server is on the private network, and the hub does not answer yet.</summary>
    public static FleetBuildRow WaitsForHub(IReadOnlyList<string> plan) =>
        new("Waiting for your hub", MinutesOf(SecondsOf(plan)), [StartShare, 0, 0, 0], false);

    /// <summary>An install that began and has no step yet: the bar's first part where the provider's build left it.</summary>
    public static FleetBuildRow Starting(IReadOnlyList<string> plan, bool afterBuild) =>
        new("Starting your server", MinutesOf(SecondsOf(plan)), [afterBuild ? StartShare : 0, 0, 0, 0], false);

    /// <summary>**An install that runs**: its words, minutes and parts. The words are the one table's
    /// (<see cref="InstallPhases.Status"/>, F4 piece 4), and the checks of an agent's server name that server. An install whose steps are all done has no words and no
    /// minutes, and one whose step that runs has passed its estimate has its words and no minutes
    /// (<see cref="InstallPhases.MinutesLeft"/>).</summary>
    public static FleetBuildRow Installing(InstallPhases phases, string? joinFor = null, bool afterBuild = false)
    {
        var parts = phases.Parts.ToList();
        if (afterBuild && parts.Count > 0) parts[0] = StartShare + (1 - StartShare) * parts[0];
        var words = phases.Status;
        if (joinFor is not null && phases.Step == "verify") words = $"Checking {joinFor}'s server";
        return new FleetBuildRow(words, phases.Step is null || phases.MinutesLeft is not { } left ? null : Math.Max(1, left),
                                 parts, false);
    }

    /// <summary>The hub puts the manager on its server with its AI program.</summary>
    public static FleetBuildRow SettingUp(string program) => new($"Installing {program}", 1, [1, 1, 1, 0.5], false);

    /// <summary>The manager's sign-in is the owner's turn: in orange, with no minutes.</summary>
    public static FleetBuildRow SignIn { get; } = new("Waiting for your sign-in", null, [1, 1, 1, 1], true);

    /// <summary>A server that is ready: no words, no minutes and no bar.</summary>
    public static FleetBuildRow Ready { get; } = new(null, null, null, false);

    internal static int SecondsOf(IReadOnlyList<string> plan) =>
        plan.Sum(step => InstallPhases.Seconds.TryGetValue(step, out var s) ? s : InstallPhases.OtherStep);

    internal static int MinutesOf(int seconds) => Math.Max(1, (int)Math.Ceiling(seconds / 60.0));

    public bool Equals(FleetBuildRow? other) =>
        other is not null && Words == other.Words && Minutes == other.Minutes && OwnersTurn == other.OwnersTurn &&
        (Parts is null ? other.Parts is null : other.Parts is not null && Parts.SequenceEqual(other.Parts));

    public override int GetHashCode() => HashCode.Combine(Words, Minutes, OwnersTurn, Parts?.Count);
}

/// <summary>The names of the servers that the PC makes (the Mac's <c>FleetOnTailscale.freeName</c>).</summary>
public static class ServerNamesOfPc
{
    /// <summary>**A name no device of the network has**, nor this PC, nor a build of this PC that may still stand at its
    /// provider: the first free <c>worker-N</c>.</summary>
    public static string Free(string statusJson, IEnumerable<string> taken)
    {
        var names = PcNetwork.Devices(statusJson).Select(d => d.Name).ToHashSet(StringComparer.Ordinal);
        if (PcNetwork.OwnName(statusJson) is { } own) names.Add(own);
        foreach (var name in taken) names.Add(name.ToLowerInvariant());
        for (var n = 1; n <= names.Count + 1; n++)
            if (!names.Contains($"worker-{n}")) return $"worker-{n}";
        return $"worker-{names.Count + 1}";
    }
}

/// <summary>**What the first run needs of Tailscale's API with the fleet's key** (<see cref="TailscaleApi"/>, piece L2): one
/// interface, so that a test gives a stand-in of the tailnet.</summary>
public interface IFleetNet
{
    bool IsHeld { get; }
    Task<FleetKeySetup> MakeFleetClientAsync(string accessToken, CancellationToken cancel = default);
    Task<string> AuthKeyAsync(string hostname, int lifeSeconds, CancellationToken cancel = default);
    Task<JoinedDevice?> JoinedAsync(string hostname, DateTimeOffset since, CancellationToken cancel = default);
    Task<IReadOnlyList<FleetDevice>> DevicesAsync(CancellationToken cancel = default);
    Task DeleteDeviceAsync(string id, CancellationToken cancel = default);
}

/// <summary>The tailnet of the fleet's key, through L2's <see cref="TailscaleApi"/>.</summary>
public sealed class FleetNet(TailscaleApi api) : IFleetNet
{
    public bool IsHeld => api.IsHeld;
    public Task<FleetKeySetup> MakeFleetClientAsync(string accessToken, CancellationToken cancel = default) => api.MakeFleetClientAsync(accessToken, cancel);
    public Task<string> AuthKeyAsync(string hostname, int lifeSeconds, CancellationToken cancel = default) => api.AuthKeyAsync(hostname, lifeSeconds, cancel);
    public Task<JoinedDevice?> JoinedAsync(string hostname, DateTimeOffset since, CancellationToken cancel = default) => api.JoinedAsync(hostname, since, cancel);
    public Task<IReadOnlyList<FleetDevice>> DevicesAsync(CancellationToken cancel = default) => api.DevicesAsync(cancel);
    public Task DeleteDeviceAsync(string id, CancellationToken cancel = default) => api.DeleteDeviceAsync(id, cancel);
}

/// <summary>What the provider's build of one server needs from the PC: the provider, the fleet's Tailscale key, this
/// PC's network, the app's SSH key, the records, and the clock.</summary>
public sealed record CloudDeps(
    Func<CloudProvider, ICloud> Cloud,
    IFleetNet Tailscale,
    Func<CancellationToken, Task<string?>> Status,
    Func<string> AppPublicLine,
    KeptRecords<BuildRecord> Builds,
    Func<DateTimeOffset> Now,
    Func<TimeSpan, CancellationToken, Task> Pause,
    PolicyPlace? Policy = null);

/// <summary>**A VPS made at a provider** (the Mac's <c>FleetCloudModel</c>): the token, the choice of the new server (and
/// the account's servers) before anything is made, and the build of exactly the server that the owner said yes to, with
/// its record kept from the moment the provider is asked. One build or one read at a time: a press while one runs does
/// nothing.</summary>
public sealed class CloudStep(CloudDeps deps)
{
    /// <summary><c>Choosing</c>: the provider's own servers and the new one, of which the owner chooses one before
    /// anything is made.</summary>
    public enum Stage { Token, Choosing, Making, Joining }

    /// <summary>What a page reads of this step.</summary>
    public sealed record View(Stage Stage, Stage? Stopped, string? Failure, CloudProvider? Provider, CloudServerUse Use, CloudOffer? Offer,
                              IReadOnlyList<CloudOffer> Choices, IReadOnlyList<CloudExisting> Existing, string? Chosen, bool TokenTaken,
                              bool AccountFull, int Listing, bool Lists, bool KeyEnded = false)
    {
        public CloudExisting? ChosenServer => Existing.FirstOrDefault(s => s.Id == Chosen);
    }

    /// <summary>A list that could not be read is read again by itself, a minute apart, at most this many times.</summary>
    public const int ReadsAgain = 30;
    public static readonly TimeSpan ReadAgainAfter = TimeSpan.FromSeconds(60);

    private readonly object gate = new();
    private View now = new(Stage.Token, null, null, null, CloudServerUse.Hub, null, [], [], null, false, false, 0, true);
    private CancellationTokenSource? work;
    private readonly HashSet<string> taken = new(StringComparer.Ordinal);
    private string? wanted;

    /// <summary>Called after each change, outside the step's lock.</summary>
    public event Action? Changed;

    public View Now { get { lock (gate) return now; } }

    /// <summary>A build or a read runs now.</summary>
    public bool Busy { get { lock (gate) return work is not null; } }

    /// <summary>This PC holds a token of the provider.</summary>
    public bool Holds(CloudProvider provider) => deps.Cloud(provider).IsHeld;

    private void Set(Func<View, View> change)
    {
        lock (gate) now = change(now);
        Changed?.Invoke();
    }

    private CancellationToken? Begin()
    {
        lock (gate)
        {
            if (work is not null) return null;
            work = new CancellationTokenSource();
            return work.Token;
        }
    }

    private void End(CancellationToken token)
    {
        lock (gate)
            if (work is not null && work.Token == token) { work.Dispose(); work = null; }
    }

    /// <summary>A token goes once; once the provider took it, the choice opens. The token is kept in the box by the
    /// provider's own check, and nowhere else.</summary>
    public async Task SendTokenAsync(CloudProvider provider, string token, CloudServerUse use, bool lists = true)
    {
        if (token.Trim().Length == 0 || Begin() is not { } cancel) return;
        taken.Clear(); wanted = null;
        Set(v => v with { Listing = v.Listing + 1, Failure = null, Stopped = null, Provider = provider, Use = use, Lists = lists, AccountFull = false,
                          Offer = null, Choices = [], Existing = [], Chosen = null, Stage = Stage.Choosing });
        try
        {
            try { await deps.Cloud(provider).CheckTokenAsync(token.Trim(), cancel).ConfigureAwait(false); }
            catch (Exception error) when (error is not OperationCanceledException)
            {
                if (cancel.IsCancellationRequested) return;
                Set(v => v with { Failure = error.Message, Stopped = Stage.Token, Stage = Stage.Token });
                return;
            }
            if (cancel.IsCancellationRequested) return;
            Set(v => v with { TokenTaken = true });
            await ReadAsync(provider, use, lists, cancel).ConfigureAwait(false);
        }
        catch (OperationCanceledException) { }
        finally { End(cancel); }
    }

    /// <summary>**Before anything is made: the new server's offer and the account's servers, with its price.**</summary>
    public async Task OpenAsync(CloudProvider provider, CloudServerUse use, bool lists = true)
    {
        if (Begin() is not { } cancel) return;
        taken.Clear(); wanted = null;
        Set(v => v with { Listing = v.Listing + 1, Failure = null, Stopped = null, Provider = provider, Use = use, TokenTaken = true, Lists = lists,
                          AccountFull = false, Offer = null, Choices = [], Existing = [], Chosen = null, Stage = Stage.Choosing });
        try { await ReadAsync(provider, use, lists, cancel).ConfigureAwait(false); }
        catch (OperationCanceledException) { }
        finally { End(cancel); }
    }

    /// <summary>The offer and the account's servers, read together: a list that cannot be read fails the read, as the
    /// offer does, and the read goes again by itself. The token's own refusal asks for a token again.</summary>
    private async Task ReadAsync(CloudProvider provider, CloudServerUse use, bool lists, CancellationToken cancel)
    {
        var cloud = deps.Cloud(provider);
        for (var round = 0; round <= ReadsAgain; round++)
        {
            if (round > 0) await deps.Pause(ReadAgainAfter, cancel).ConfigureAwait(false);
            cancel.ThrowIfCancellationRequested();
            try
            {
                var offers = await cloud.OffersAsync(use, taken, cancel).ConfigureAwait(false);
                var existing = lists ? await cloud.ServersAsync(cancel).ConfigureAwait(false) : [];
                cancel.ThrowIfCancellationRequested();
                if (offers.Count == 0) throw new CloudException(CloudFailure.NoRoom, provider);
                var kept = offers.FirstOrDefault(o => o.Kind == wanted);
                if (kept is null) wanted = null;
                Set(v => v with { Failure = round > 0 ? null : v.Failure, Stopped = round > 0 ? null : v.Stopped, Offer = kept ?? offers[0],
                                  Choices = offers, Existing = existing });
                return;
            }
            catch (Exception error) when (error is not OperationCanceledException)
            {
                cancel.ThrowIfCancellationRequested();
                if (CloudStop.RefusesToken(error))
                {
                    Set(v => v with { Failure = error.Message, Stopped = Stage.Token, TokenTaken = false, Stage = Stage.Token });
                    return;
                }
                Set(v => v with { Failure = error.Message, Stopped = Stage.Choosing });
            }
        }
        Set(v => v with { Stage = Stage.Token });
    }

    /// <summary>The owner's type in the list under a server: the press then makes it or nothing.</summary>
    public void Choose(CloudOffer offer)
    {
        if (Now is not { Stage: Stage.Choosing } v || !v.Choices.Contains(offer)) return;
        wanted = offer.Kind;
        Set(x => x with { Offer = offer });
    }

    /// <summary>A server of the account's list, or null for the new one.</summary>
    public void ChooseExisting(string? id) => Set(v => v.Stage == Stage.Choosing ? v with { Chosen = id } : v);

    /// <summary>**Why the press made nothing**, over the press of the choice, which stays; null takes the line away.</summary>
    public void Stop(string? why)
    {
        if (Busy || Now.Stage != Stage.Choosing) return;
        Set(v => v with { Failure = why, Stopped = why is null ? null : Stage.Choosing });
    }

    /// <summary>Ends a build or a choice.</summary>
    public void Cancel()
    {
        lock (gate) { work?.Cancel(); work = null; }
        taken.Clear(); wanted = null;
        Set(v => new View(Stage.Token, null, null, null, v.Use, null, [], [], null, false, false, v.Listing + 1, v.Lists));
    }

    /// <summary>**Make the server**: the new one, exactly as the step showed it, and nothing else. <paramref name="made"/>
    /// gets the new server's name right before its provider is asked for it, and again with the provider's id.
    /// <paramref name="hub"/>: the hub that the server is made for; none for the hub's own server of a first run, which
    /// is kept under the hub's address to be once it is on the private network. <paramref name="install"/> gets the server
    /// at its address on the private network, as root, when it joined. False when nothing was started.</summary>
    public bool MakeNew(string? hub, Action<string, string?>? made, Func<InstallTarget, Task> install)
    {
        var v = Now;
        if (v is not { Stage: Stage.Choosing, Chosen: null, Provider: { } provider, Offer: { } offer } || Begin() is not { } cancel) return false;
        Set(x => x with { Failure = null, Stopped = null, Stage = Stage.Making });
        _ = Task.Run(async () =>
        {
            try { await BuildAsync(provider, v.Use, offer, hub, made, install, cancel).ConfigureAwait(false); }
            finally { End(cancel); }
        });
        return true;
    }

    /// <summary>**The server, made with nothing typed** (the Mac's <c>build</c>): a name no device of the network has, the
    /// app's own SSH key, a join key for that one server from the fleet's Tailscale key, and the provider's firewall with
    /// no way in. The build keeps its own record from the moment the provider is asked, at each of its moments, so a
    /// server that was made and never joined is still known afterwards.</summary>
    private async Task BuildAsync(CloudProvider provider, CloudServerUse use, CloudOffer offer, string? hub, Action<string, string?>? made,
                                  Func<InstallTarget, Task> install, CancellationToken cancel)
    {
        var started = deps.Now();
        var reached = Stage.Making;
        BuildRecord? kept = null;
        Exception? stoppedBy = null;
        void Keep() { if (kept is not null) deps.Builds.Write(kept); }
        string failure;
        try
        {
            var status = await deps.Status(cancel).ConfigureAwait(false) ?? "{}";
            var name = ServerNamesOfPc.Free(status, BuildRecord.NamesInUse(deps.Builds.All(), deps.Now(), StartAgain.DeviceWindow));
            var publicKey = deps.AppPublicLine();
            var authKey = await deps.Tailscale.AuthKeyAsync(name, CloudJoin.KeyLife, cancel).ConfigureAwait(false);
            made?.Invoke(name, null);
            kept = BuildRecord.Begin(provider.Raw(), use == CloudServerUse.Hub ? "hub" : "agent", hub, name, AppLaunchOf(deps), deps.Now());
            Keep();
            var server = await deps.Cloud(provider).MakeAsync(new CloudOrder(name, use, publicKey, authKey, offer), cancel).ConfigureAwait(false);
            made?.Invoke(name, server.Id);
            kept = kept.Made(server.Id, deps.Now(), server.Type, server.MonthlyPrice, server.Currency);
            Keep();
            Set(v => v with { Stage = Stage.Joining });
            reached = Stage.Joining;
            var end = await CloudJoin.WaitAsync(name, deps.Now(), deps.Status,
                                                c => deps.Tailscale.JoinedAsync(name, started, c), deps.Now, deps.Pause, cancel).ConfigureAwait(false);
            cancel.ThrowIfCancellationRequested();
            if (end is CloudJoin.End.Online online)
            {
                var future = hub is null && use == CloudServerUse.Hub ? StartAgain.HubAddress(online.Address) : null;
                kept = kept.Joined(deps.Now(), future);
                Keep();
                Set(v => v with { Stage = Stage.Token });
                await install(new InstallTarget(online.Address)).ConfigureAwait(false);
                return;
            }
            JoinedDevice? listed = (end as CloudJoin.End.Listed)?.Device;
            listed ??= await deps.Tailscale.JoinedAsync(name, started, cancel).ConfigureAwait(false);
            if (listed is not null)
            {
                var now = await deps.Status(cancel).ConfigureAwait(false) ?? "";
                var words = FleetReach.Keeps(listed, now) ? FleetReach.Hidden(name, use == CloudServerUse.Hub, deps.Policy) : FleetReach.Unseen(name);
                kept = kept.End(deps.Now(), onNetwork: true);
                Keep();
                Set(v => v with { Failure = words, Stopped = reached, Stage = Stage.Token });
                return;
            }
            failure = CloudJoin.NotJoined(name, provider);
        }
        catch (OperationCanceledException)
        {
            if (kept is not null) { kept = kept.End(deps.Now(), cancelled: true); Keep(); }
            return;
        }
        catch (Exception error) when (cancel.IsCancellationRequested)
        {
            // **A cancel ended this build** (Cancel set the step back already): what the end threw is no failure, and
            // nothing of the page changes; the record says what the call left (the Mac's build). A stop of the call for
            // the server ends as the provider's call with no answer (CloudServers.CreateCallAsync).
            if (kept is not null) { kept = kept.CallEnded(After(error)).End(deps.Now(), cancelled: true); Keep(); }
            return;
        }
        catch (Exception error)
        {
            failure = error.Message;
            if (kept is not null) kept = kept.CallEnded(After(error));
            stoppedBy = error;
        }
        if (kept is not null) { kept = kept.End(deps.Now()); Keep(); }
        var full = stoppedBy is CloudException { Failure: CloudFailure.Full };
        if (reached == Stage.Making && stoppedBy is { } why && CloudStop.ReadsListAgain(why, kept is not null))
        {
            if (why is CloudException { Failure: CloudFailure.Taken }) taken.Add(offer.Key);
            Set(v => v with { Failure = failure, Stopped = reached, AccountFull = full, Listing = v.Listing + 1, Offer = null, Choices = [],
                              Existing = [], Chosen = null, Stage = Stage.Choosing });
            try { await ReadAsync(provider, use, Now.Lists, cancel).ConfigureAwait(false); }
            catch (OperationCanceledException) { }
            return;
        }
        Set(v => v with { Failure = failure, Stopped = reached, AccountFull = full, Stage = Stage.Token,
                          TokenTaken = stoppedBy is not null && CloudStop.RefusesToken(stoppedBy) ? false : v.TokenTaken,
                          KeyEnded = stoppedBy is FleetKeyException { Failure: FleetKeyFailure.FleetKeyEnded } });
    }

    private static string AppLaunchOf(CloudDeps deps) => deps.Builds.Launch;

    /// <summary>What a call that ended with this error left at the provider (the Mac's <c>AtProvider.after</c>). A
    /// provider's own fault answer (a 5xx), no answer, or a success with no id that this app reads, to the call for the
    /// server is <c>Nothing</c> only when the provider held the server that it made and this app deleted it
    /// (<c>TakenBack</c>, <c>UnreadTakenBack</c>); its other end (<c>Unsure</c>, <c>Unread</c>) is <c>NotKnown</c>, and
    /// the name stays in use.</summary>
    public static AtProvider After(Exception error) => error switch
    {
        OperationCanceledException => AtProvider.Nothing,
        CloudException { Failure: CloudFailure.LeftBehind } => AtProvider.LeftBehind,
        CloudException { Failure: CloudFailure.Unreachable or CloudFailure.NotUnderstood or CloudFailure.Unsure or CloudFailure.Unread } => AtProvider.NotKnown,
        CloudException => AtProvider.Nothing,
        _ => AtProvider.NotKnown,
    };
}
