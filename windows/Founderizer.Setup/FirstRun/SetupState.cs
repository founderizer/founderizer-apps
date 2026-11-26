using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.Json.Serialization;
using Founderizer.Setup.Cloud;
using Founderizer.Setup.Install;
using Founderizer.Setup.Network;

namespace Founderizer.Setup.FirstRun;

/// <summary>**The pages of the first run on a PC** (the Mac's <c>FirstRunModel.Step</c>), in their order. Not on the PC
/// (plan, section 7, 2.1): the second way of the welcome page and its page (<c>paste</c>), and the pages that no press
/// leads to on the Mac (<c>machine</c>, <c>address</c>).</summary>
public enum SetupPage
{
    /// <summary>The welcome page: the team, its title and its one way.</summary>
    Welcome,
    /// <summary>"Help improve Founderizer", before the manager's name.</summary>
    ErrorReports,
    /// <summary>"Name your manager".</summary>
    Name,
    /// <summary>"&lt;Name&gt;'s AI provider".</summary>
    AiProvider,
    /// <summary>"Your fleet's servers", the slider.</summary>
    Servers,
    /// <summary>Tailscale on this PC, only when the PC is on no tailnet.</summary>
    Network,
    /// <summary>The fleet's own Tailscale key, from one pasted access token, only when the box holds none.</summary>
    Key,
    /// <summary>"A VPS for your fleet": four providers and Other VPS.</summary>
    Cloud,
    /// <summary>A provider's token, then its choice ("Your fleet") and its build.</summary>
    Token,
    /// <summary>Other VPS: the address, the check, the password once (or the owner's key once), and Install.</summary>
    Vps,
    /// <summary>The build page, and the hub's install with its checks.</summary>
    Installing,
    /// <summary>The hub answers and this PC is its owner's computer.</summary>
    Done,
}

/// <summary>The steps of Other VPS (the Mac's <c>FleetVPSModel.Phase</c>).</summary>
public enum VpsPhase { Address, Checking, Password, Waiting, Ready, Stopped }

/// <summary>**Other VPS as its page reads it.** <c>Need</c> is the password that the server asks for; <c>Why</c> the
/// words of a wait or a stop; <c>Summary</c> and <c>Changes</c> the check's two lines; <c>HoldsSudo</c>: a <c>sudo</c>
/// password waits for the install. The owner's key once (the owner's choice of 21 November 2026): <c>KeyName</c> is the
/// chosen file's name while the step is open (never its path), <c>KeyAsksPassphrase</c> whether the passphrase field
/// shows, <c>KeyWarning</c> the sentence of a file that is no key or a passphrase that does not open it. No byte of the
/// key and no passphrase is in this record. <c>KeysOnly</c>: the stop is that of a server that takes SSH keys only.</summary>
public sealed record VpsView(VpsPhase Phase, string Address, InstallTarget? Target, ServerCheck.PasswordNeed? Need, string? Why,
                             string? Summary, string? Changes, bool HoldsSudo, string? KeyName = null, bool KeyAsksPassphrase = false,
                             string? KeyWarning = null, bool KeysOnly = false)
{
    public static VpsView Start { get; } = new(VpsPhase.Address, "", null, null, null, null, null, false);

    /// <summary>The server as the page's title names it.</summary>
    public string Host => Target?.Host ?? Address.Trim();

    /// <summary>**Where the key's row "SSH key · Choose key" shows** (picture 13d; the owner's "Key row here too" of 21
    /// November 2026, picture 14b, W15): the stop of a server that takes keys only, and the password's page of an SSH
    /// password, where the owner gives the password or the key. Not the password's page of a <c>sudo</c> password: the
    /// app's key got in there.</summary>
    public bool TakesKey => Phase switch
    {
        VpsPhase.Stopped => KeysOnly,
        VpsPhase.Password => Need == ServerCheck.PasswordNeed.Ssh,
        _ => false,
    };
}

/// <summary>**One install as its page reads it** (the Mac's <c>MachineInstallModel</c> state): whether it runs, each step
/// as the installer reported it, the plan's steps, when the step that runs began, the stop's words, the server's own
/// checklist, and the hub that the claim gave.</summary>
public sealed record InstallView(bool Running, IReadOnlyList<InstallProgress> Steps, IReadOnlyList<string> Planned, DateTimeOffset RunningSince,
                                 string? Failure, VerifyChecklist? Checklist, string? ClaimedHub, bool NeedsNetworkKey, string? Server = null,
                                 string? JoinHub = null, string? NetworkFailure = null, InstallHold? Hold = null)
{
    public static InstallView None { get; } = new(false, [], [], DateTimeOffset.MinValue, null, null, null, false);

    /// <summary>**One report of an install that runs** (the Mac's <c>MachineInstallModel.record</c>): the step in its
    /// place; the time since the step that runs began, new (<paramref name="now"/>) only when the id of the first step
    /// that runs changes, since the installer reports a step again at each wait of its check, at each heading of the
    /// hub's installer and at each read of the network sign-in (F4 piece 2: the minutes counted from the last report,
    /// "· 13 min" for the whole wait of the hub's installer); and the press's hold, kept at each report, so that the bar
    /// never goes back inside one try nor across a retry (pieces 3 and 4). A new press makes a new view, and so a new
    /// hold; a retry empties the steps, so its first step has a new time, and keeps the hold.</summary>
    public InstallView Reported(InstallProgress progress, DateTimeOffset now)
    {
        var steps = Steps.ToList();
        var at = steps.FindIndex(p => p.Step == progress.Step);
        if (at >= 0) steps[at] = progress; else steps.Add(progress);
        var hold = InstallPhases.Of(steps, Planned) is { } phases ? (Hold ?? InstallHold.None).Keep(phases) : Hold;
        static string? Runs(IReadOnlyList<InstallProgress> all) => all.FirstOrDefault(p => p.State == ProgressState.Running)?.Step;
        return this with { Steps = steps, RunningSince = Runs(steps) == Runs(Steps) ? RunningSince : now, Hold = hold };
    }

    /// <summary>**The phases of this install as the build page shows them**: its steps, with the time that the step
    /// which runs has run (<paramref name="runningFor"/>), held by this press's <see cref="Hold"/>, so that a retry never
    /// sends the bar back and a heading that the table does not have keeps the line (the Mac's
    /// <c>InstallPhases(...).map(install.hold.applied(to:))</c>). Null for a plan with no network step.</summary>
    public InstallPhases? Phases(double runningFor) =>
        InstallPhases.Of(Steps, Planned, runningFor) is { } phases ? (Hold ?? InstallHold.None).Applied(phases) : null;

    /// <summary>The install's checks let the first run go on: none failed, or only the sign-in.</summary>
    public bool Passed => Checklist is { } list && (list.IsReady || list.OnlyNeedsSignIn);

    /// <summary>**The Tailscale link that this install waits on, while it waits** (the Mac's
    /// <c>MachineInstallModel.networkSignIn</c>): the link in the lines of the step that runs, only Tailscale's own
    /// sign-in page (<see cref="Install.NetworkSignIn.Found"/>). The owner approves it, and the install goes on by itself.</summary>
    public Install.NetworkSignIn? NetworkSignIn =>
        Running && Steps.LastOrDefault(s => s.State == ProgressState.Running) is { } step ? Install.NetworkSignIn.Found(step.Lines) : null;
}

/// <summary>Connect Tailscale: the press was made (the title waits for Tailscale), and its words.</summary>
public sealed record NetworkView(bool Pressed, bool Busy, string? Failure)
{
    public static NetworkView Start { get; } = new(false, false, null);
}

/// <summary>Your Tailscale key: the key is made now, its words, and the line to add to a policy file that the PC may not
/// write, with the words over it. <c>Made</c>: a paste of this run made the key (the install's page then offers Install
/// again).</summary>
public sealed record KeyView(bool Busy, string? Failure, string? LinesToAdd, string? Asks, bool Made = false)
{
    public static KeyView Start { get; } = new(false, null, null, null);
}

/// <summary>The manager's own server that the one press makes: its name from the moment its provider is asked, its id at
/// its provider once the provider answered, and its address on the private network once it is there (the Mac's
/// <c>managersServerMade</c>, and <c>managersServer</c> once it has an address).</summary>
public sealed record MadeServer(string Name, string? Address, string? Id, CloudProvider Provider);

/// <summary>**The first run as its pages read it**: an immutable value, as <c>StoreState</c> is for the daily pages; each
/// press makes a new one, and <see cref="SetupStore.Changed"/> says so.</summary>
public sealed record SetupState
{
    public SetupPage Page { get; init; } = SetupPage.Welcome;
    /// <summary>The provider of the token page.</summary>
    public CloudProvider? TokenOf { get; init; }
    /// <summary>The card that the owner pressed, while the network page or the key's stands in front of its page.</summary>
    public SetupPage? After { get; init; }
    public CloudProvider? AfterProvider { get; init; }

    /// <summary>The owner went on from "Name your manager" in this first run.</summary>
    public bool Named { get; init; }
    /// <summary>The manager's name as the owner typed it.</summary>
    public string ManagerName { get; init; } = Founderizer.Setup.Install.ManagerName.Suggested;
    /// <summary>The manager's AI provider as the owner chose it on its page (kept on this PC), or none.</summary>
    public string? AiProvider { get; init; }
    public bool ChoseAi { get; init; }
    public ServersStep ServersStep { get; init; } = ServersStep.Two;
    /// <summary>The owner went on from "Your fleet's servers" in this first run.</summary>
    public bool Shaped { get; init; }
    /// <summary>The owner's answer on "Help improve Founderizer": true to send, false not to, null before.</summary>
    public bool? SendsReports { get; init; }

    /// <summary>This PC is on the owner's private network, as its last read said; null until then.</summary>
    public bool? PcReady { get; init; }
    public PcNetwork.Standing? Pc { get; init; }

    public NetworkView Network { get; init; } = NetworkView.Start;
    public KeyView Key { get; init; } = KeyView.Start;
    /// <summary>The box holds the fleet's Tailscale key.</summary>
    public bool HoldsFleetKey { get; init; }
    /// <summary>Tailscale ended the fleet's key that the box holds: the key's page comes again before a server, as for a
    /// box that holds none, until a paste makes a new one.</summary>
    public bool FleetKeyEnded { get; init; }

    /// <summary>The hub's server at its provider.</summary>
    public CloudStep.View? Cloud { get; init; }
    /// <summary>The manager's own server, on 2 servers and 1 per agent.</summary>
    public CloudStep.View? ManagersCloud { get; init; }
    /// <summary>The provider of the manager's own server, when the owner chose another one than the hub's.</summary>
    public CloudProvider? ManagersProvider { get; init; }
    /// <summary>That provider's token page shows for the manager's own server.</summary>
    public CloudProvider? ManagersToken { get; init; }
    /// <summary>The provider's words when it refused the manager's own server on the build page.</summary>
    public string? ManagersRefusal { get; init; }
    /// <summary>The steps to get more servers at Hetzner show in place of their link.</summary>
    public bool ManagersMoreShown { get; init; }
    public IReadOnlySet<CloudProvider> ManagersFull { get; init; } = new HashSet<CloudProvider>();
    public MadeServer? ManagersServer { get; init; }
    /// <summary>The hub's address that the newest try of the hub's server gives, for which the manager's server is kept.</summary>
    public string? ManagersHub { get; init; }

    public VpsView Vps { get; init; } = VpsView.Start;
    public InstallView Install { get; init; } = InstallView.None;
    public InstallView ManagerInstall { get; init; } = InstallView.None;

    /// <summary>An install of this first run began.</summary>
    public bool Began { get; init; }
    /// <summary>The hub's server of this try came from the provider's build.</summary>
    public bool HubBuilt { get; init; }
    /// <summary>The window went to the manager's setup.</summary>
    public bool HandedOver { get; init; }
    /// <summary>**The new hub answers this PC**: the owner's store holds its reading (the Mac's <c>store.state != nil</c>).</summary>
    public bool HubAnswers { get; init; }
    /// <summary>**The owner pressed "Open Founderizer" under checks that did not pass** (the Mac's <c>afterInstall</c>,
    /// <c>openApp</c>): the window goes to the manager's setup as after checks that passed, once the hand-over can come.</summary>
    public bool OpenAsked { get; init; }
    /// <summary>The manager that the hand-over went to, and the provider that its setup gets.</summary>
    public string? HandedTo { get; init; }

    /// <summary>The page's own line of a press that made nothing.</summary>
    public string? Failure { get; init; }

    // ------------------------------------------------------------ what the Mac's model says of itself

    /// <summary>One server for all: the owner came through the slider's page and chose its first step.</summary>
    public bool OneServer => Shaped && ServersStep == ServersStep.One;

    /// <summary>The first run's one press makes the manager's own server too.</summary>
    public bool MakesManagersServer => Shaped && ServersStep.ManagersOwnServer();

    /// <summary>The AI provider that this first run gives on, or null when the owner did not go on from its page.</summary>
    public string? ChosenAi => ChoseAi ? AiProvider : null;

    /// <summary>**The name that the hub's installer gets** (<c>hub.sh --manager-name</c>): the typed name by the installer's
    /// own rule (<see cref="Founderizer.Setup.Install.ManagerName.AgentName"/>), or none for a first run that did not ask.</summary>
    public string? HubName => Named ? Founderizer.Setup.Install.ManagerName.AgentName(ManagerName) : null;

    /// <summary>From here on the first run keeps the window: the hub answers in the middle of the first run, at the
    /// claim of an install, and what this PC proved comes after it.</summary>
    public bool HoldsWindow => Page is SetupPage.Installing or SetupPage.Done;

    /// <summary>The page's name, as the steps on Back's line read it (the Mac's <c>pageName</c>): <c>building</c> for a
    /// provider's page while its server is made.</summary>
    public string PageName => Page switch
    {
        SetupPage.Welcome => "welcome",
        SetupPage.ErrorReports => "errorReports",
        SetupPage.Name => "name",
        SetupPage.AiProvider => "aiProvider",
        SetupPage.Servers => "servers",
        SetupPage.Network => "network",
        SetupPage.Key => "key",
        SetupPage.Cloud => "cloud",
        SetupPage.Token => Cloud?.Stage is CloudStep.Stage.Making or CloudStep.Stage.Joining ? "building" : "token",
        SetupPage.Vps => "vps",
        SetupPage.Installing => "installing",
        _ => "done",
    };

    /// <summary>**The steps on Back's line**, for the pages of the welcome page's first way.</summary>
    public SetupProgress? Progress =>
        FirstRunSteps.Of(PageName, Named) is { } step && FirstRunSteps.InFlow.IndexOf(step) is var index and >= 0
            ? new SetupProgress(FirstRunSteps.Names, index)
            : null;

    /// <summary>A provider's server is made now.</summary>
    public bool CloudBuilds => Cloud?.Stage is CloudStep.Stage.Making or CloudStep.Stage.Joining;

    /// <summary>The page "Your fleet": the fleet that the one press makes, for an owner who came through the slider's page
    /// and whose account has no server of its own.</summary>
    public bool ShowsFleet => Shaped && (Cloud?.Existing.Count ?? 0) == 0;
}

internal static class Lists
{
    public static int IndexOf<T>(this IReadOnlyList<T> list, T item)
    {
        for (var i = 0; i < list.Count; i++) if (EqualityComparer<T>.Default.Equals(list[i], item)) return i;
        return -1;
    }
}

/// <summary>**The owner's answers that this PC keeps between starts of the app** (the Mac's settings of the first run:
/// <c>firstRunManagerName</c>, <c>firstRunAIProvider</c>, <c>firstRunServersStep</c>, <c>firstRunErrorReports</c> and
/// the answer that waits for a hub). No key, token or password is one of them, and no address of a server but the two of
/// the mark of the manager's first setup (<c>ManagerSetupMark</c>): the hub's own, and, until it joined, the private address
/// of the manager's own server that the first run made.</summary>
public interface ISetupChoices
{
    string? Get(string name);
    void Set(string name, string? value);
}

/// <summary>The kept answers in memory, for a test or a window that keeps nothing.</summary>
public sealed class MemoryChoices : ISetupChoices
{
    private readonly Dictionary<string, string> values = new(StringComparer.Ordinal);
    public string? Get(string name) { lock (values) return values.GetValueOrDefault(name); }
    public void Set(string name, string? value)
    {
        lock (values)
        {
            if (value is null) values.Remove(name);
            else values[name] = value;
        }
    }
}

/// <summary>The names of the kept answers.</summary>
public static class SetupChoiceNames
{
    public const string ManagerName = "firstRunManagerName";
    public const string AiProvider = "firstRunAIProvider";
    public const string ServersStep = "firstRunServersStep";
    /// <summary>The card with the check mark: <c>send</c> or <c>none</c>.</summary>
    public const string Reports = "firstRunErrorReports";
    /// <summary>The answer that no hub took yet: <c>send</c> or <c>none</c>.</summary>
    public const string ReportsWaiting = "firstRunErrorReportsWaiting";
}

/// <summary>The body of POST /ui/error-reports (owner feature <c>error_reports</c>): the first run's answer.</summary>
public sealed record ErrorReportsAsk(bool Send);

/// <summary>The receipt of POST /ui/error-reports: the switch as it is now.</summary>
public sealed record ErrorReportsReceipt(bool Ok, string RequestId, bool Send);

/// <summary>The JSON context of the first run's own owner writes.</summary>
[JsonSourceGenerationOptions(
    PropertyNamingPolicy = JsonKnownNamingPolicy.SnakeCaseLower,
    RespectNullableAnnotations = true,
    RespectRequiredConstructorParameters = true,
    NumberHandling = JsonNumberHandling.Strict,
    UnmappedMemberHandling = JsonUnmappedMemberHandling.Skip,
    GenerationMode = JsonSourceGenerationMode.Metadata)]
[JsonSerializable(typeof(ErrorReportsAsk))]
[JsonSerializable(typeof(ErrorReportsReceipt))]
public sealed partial class SetupJson : JsonSerializerContext;
