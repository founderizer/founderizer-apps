using System;
using System.Collections.Generic;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using Founderizer.Core;
using Founderizer.Remote;

namespace Founderizer.Setup.Install;

/// <summary>Where one step of an install stands.</summary>
public enum ProgressState { Waiting, Running, Done, Failed }

/// <summary>Where one step of an install stands, as the owner watches it (the Mac's InstallProgress). <c>Lines</c> are
/// the last lines that the server printed, with the owner's secrets taken out; <c>Detail</c> what went wrong.
/// <c>Unreachable</c>: this PC's last reads of the step reached nothing (F4 of 22 November 2026, piece 5): the step goes
/// on, and the next read that reaches the server reports it again without the flag.</summary>
public sealed record InstallProgress(string Step, string Title, string Says, ProgressState State,
                                     IReadOnlyList<string>? Lines = null, string? Detail = null, bool Unreachable = false)
{
    public IReadOnlyList<string> Lines { get; init; } = Lines ?? [];
}

/// <summary>The kinds of <see cref="InstallError"/> (the Mac's InstallError cases).</summary>
public enum InstallErrorKind { CannotStart, Step, NotRoot, TimedOut, NoClaimCode, NoChecklist, CheckStopped, NeedsPassword }

/// <summary>**Why an install stopped** (the Mac's InstallError). A step that failed because IRemote did not run its
/// program carries the way it failed (<see cref="Failure"/>), which says what the Mac reads from <c>ssh</c>'s
/// words.</summary>
public sealed class InstallError : Exception
{
    public InstallErrorKind Kind { get; }
    /// <summary>The step's title (a step that failed, a step that took too long).</summary>
    public string? Title { get; }
    /// <summary>The words of a step that failed, of a check that stopped, or of an install that could not start.</summary>
    public string? Says { get; }
    /// <summary>The user that is not root; for a failure of IRemote, the user it logged in as.</summary>
    public string? User { get; }
    public ServerCheck.PasswordNeed? Need { get; }
    /// <summary>How IRemote did not run the step's program, or null.</summary>
    public RemoteFailure? Failure { get; }
    /// <summary>The SSH port of that call.</summary>
    public int Port { get; }
    /// <summary>The first run's words, or the words after it, for a changed host key (<see cref="ServerCheck.HostKeyChanged"/>).</summary>
    public bool FirstRun { get; }
    /// <summary>Where the owner's Tailscale policy is kept, for a silent server on the private network.</summary>
    public ServerCheck.PolicyPlace? Policy { get; }

    private InstallError(InstallErrorKind kind, string? title = null, string? says = null, string? user = null,
                         ServerCheck.PasswordNeed? need = null, RemoteFailure? failure = null, int port = 22,
                         bool firstRun = true, ServerCheck.PolicyPlace? policy = null)
        : base(null)
    {
        Kind = kind; Title = title; Says = says; User = user; Need = need; Failure = failure; Port = port;
        FirstRun = firstRun; Policy = policy;
    }

    public static InstallError CannotStart(string says) => new(InstallErrorKind.CannotStart, says: says);
    public static InstallError Step(string title, string says) => new(InstallErrorKind.Step, title, says);
    /// <summary>A step whose program IRemote did not run: the PC's words for that way, the user and the port of the call,
    /// and the choices of those words (the first run's, the policy's place), which <see cref="Plain"/> keeps.</summary>
    public static InstallError Remote(string title, string says, RemoteFailure failure, int port, string user,
                                      bool firstRun = true, ServerCheck.PolicyPlace? policy = null) =>
        new(InstallErrorKind.Step, title, says, user, failure: failure, port: port, firstRun: firstRun, policy: policy);
    public static InstallError NotRoot(string user) => new(InstallErrorKind.NotRoot, user: user);
    public static InstallError TimedOut(string title) => new(InstallErrorKind.TimedOut, title);
    public static InstallError NoClaimCode() => new(InstallErrorKind.NoClaimCode);
    public static InstallError NoChecklist() => new(InstallErrorKind.NoChecklist);
    public static InstallError CheckStopped(string says) => new(InstallErrorKind.CheckStopped, says: says);
    public static InstallError NeedsPassword(ServerCheck.PasswordNeed need) => new(InstallErrorKind.NeedsPassword, need: need);

    public override string Message => Description;

    /// <summary>The error in the app's words (the Mac's errorDescription).</summary>
    public string Description => Kind switch
    {
        InstallErrorKind.CannotStart or InstallErrorKind.CheckStopped => Says ?? "",
        InstallErrorKind.Step => $"{Title}: {Says}",
        InstallErrorKind.NotRoot => ServerCheck.NotRoot(User ?? ""),
        InstallErrorKind.TimedOut => $"{Title} took too long. The server is still working, or it cannot be reached.",
        InstallErrorKind.NoClaimCode => "The installer did not print a link code for this PC. Try again.",
        InstallErrorKind.NoChecklist => "The server did not answer its checks. Nothing was installed twice.",
        _ => Need == ServerCheck.PasswordNeed.Sudo
            ? "sudo on that server asks for a password."
            : "That server does not take this PC's SSH key, and asks for a password.",
    };

    /// <summary>The reason after an installer's stop mark, trimmed, or null when the words have no mark or nothing after
    /// it.</summary>
    internal static string? StopReason(string says)
    {
        var mark = InstallPlan.StopMarks.FirstOrDefault(m => says.Contains(m, StringComparison.Ordinal));
        if (mark is null) return null;
        var reason = says[(says.LastIndexOf(mark, StringComparison.Ordinal) + mark.Length)..].Trim(' ', '\t');
        return reason.Length == 0 ? null : reason;
    }

    /// <summary>The lines this app gives a step that failed: already the owner's words.</summary>
    internal static readonly IReadOnlyList<string> OwnWords =
    [
        InstallPlan.HubSystems, InstallPlan.JoinSystems, Installer.NoUser, OwnerPcKey.NotOnYourNetwork,
        NetworkSignIn.NotApproved, NetworkSignIn.NotStarted, Installer.NotThisPcs, OwnerPcKey.CodeRefused, Installer.JoinNoChecks,
    ];

    /// <summary>**What stopped the install, in a few plain words** (the Mac's <c>plain</c>): the installer's own reason
    /// after its stop mark; for a step that IRemote did not run, the PC's sentence for that way; this app's own words as
    /// they are; and else where it stopped. <paramref name="host"/> is the server's address as the owner gave it, or its
    /// address on the private network once the install reached it there. The words of a failure take the choices that
    /// the step's own words took (<see cref="FirstRun"/>, <see cref="Policy"/>), so that the step's detail and the page's
    /// line say the same.</summary>
    public string Plain(string host)
    {
        if (Kind != InstallErrorKind.Step) return Description;
        var says = Says ?? "";
        var server = host.Length == 0 ? "the server" : host;
        if (StopReason(says) is { } reason) return reason[..1].ToUpperInvariant() + reason[1..];
        if (Failure is { } failure) return ServerCheck.Failed(server, Port, User ?? "", failure, new RemoteLogin.AppKey(), FirstRun, Policy);
        if (OwnWords.Contains(says)) return says;
        return $"It stopped at “{Title}”.";
    }
}

/// <summary>The time of an install: what the tests give in place of the clock and the waits.</summary>
public class InstallerClock
{
    public static readonly InstallerClock System = new();
    public virtual DateTimeOffset Now => DateTimeOffset.UtcNow;
    public virtual Task DelayAsync(TimeSpan time, CancellationToken cancel) => Task.Delay(time, cancel);
}

/// <summary>**Installs one Linux server of a fleet from this PC, over IRemote** (the Mac's MachineInstaller): it runs
/// the plan's steps in order and reports each one as it starts and as it ends. Three things it never does: put the
/// Tailscale auth key in a command (it goes on standard input), keep or report a line that holds the key or a one-time
/// code (every line goes through <see cref="Redact"/>), or hand a sudo password to a <c>sudo</c> that does not ask for
/// one. Every call logs in with the app's own key, under the host key rule of a new server (<see cref="HostKeyRule.TakeNew"/>).
///
/// A step that fails stops the install. Nothing is undone: each installer step checks first, so the owner fixes what
/// the line says and starts the same install again.</summary>
public sealed class Installer
{
    /// <summary>The stop of an install whose hub has its owner and does not serve this PC.</summary>
    public const string NotThisPcs = "Your hub answered, and it does not serve its pages to this PC.";
    /// <summary>A server that printed no reading at its check.</summary>
    public const string NoUser = "It did not answer which user this is.";
    /// <summary>A join line that ended with no status and no <c>READY</c>.</summary>
    public const string JoinNoChecks = "The join did not reach the checks of this server.";
    /// <summary>The words of the hub installer's own line for a hub that has its owner and gets no new code.</summary>
    internal const string NoCodeMade = "no code was made";
    /// <summary>How many times an install asks for the server's checks while the call did not reach the server.</summary>
    internal const int VerifyTries = 3;
    /// <summary>The most characters of a call's output that the installer keeps (the Mac's bound).</summary>
    internal const int OutputLimit = 1_048_576;

    // The time limits of the Mac's calls, in seconds (MachineInstaller.perform).
    private const double CheckLimit = 120, RunLimit = 1800, JoinLimit = 3600, DetachLimit = 120, ReadLimit = 120,
                         SignInStartLimit = 900, SignInCheckLimit = 60, VerifyLimit = 1800,
                         AuthKeyLimit = 2 * InstallPlan.AptLockWait + 600;

    private readonly InstallPlan plan;
    private readonly string authKey;
    private readonly char[]? sudoPassword;
    private readonly Func<string, Uri, CancellationToken, Task<string?>>? claim;
    private readonly Func<Uri, CancellationToken, Task<HubRead>> readHub;
    private readonly InstallerClock clock;
    private readonly TimeSpan verifyPause;
    private readonly bool firstRun;
    private readonly ServerCheck.PolicyPlace? policy;
    private readonly List<string> hidden = [];
    private bool feedsSudo;
    private Uri? ownedHub;
    private int hubRefusals;
    private bool installerMadeNoCode;
    private (string Code, Uri Claim)? foundClaim;
    private IReadOnlyList<string> lastOutput = [];
    /// <summary>How the last program that <see cref="SshAsync"/> ran failed to reach the server, for a wait's count of
    /// reads that reached nothing (the Mac's <c>lastStatus</c> of 255); null for one that reached it.</summary>
    private RemoteFailure? lastFailure;

    /// <summary>The reads in a row that reach nothing before the step says so (the Mac's <c>unreachedReads</c>).</summary>
    internal const int UnreachedReads = 3;

    /// <summary>Where the install reaches the server: the address the owner gave, until the network step puts the
    /// server on the private network, and from then on its address there.</summary>
    public InstallTarget Reached { get; private set; }

    /// <summary>**The connection at the machine's own private address**, which the machine printed in the network step over
    /// this very connection, not the hub (the Mac's <c>MachineInstaller.moved</c>). A port that the owner gave for the typed
    /// address is the owner's for that address too; any other port stays one that the owner did not give.</summary>
    internal static InstallTarget Moved(InstallTarget target, string address) =>
        target with { Host = address, PortGivenFor = target.PortGivenFor == target.Host ? address : target.PortGivenFor };

    /// <summary>The hub that the claim step claimed, or that served this PC already: its address with the hub's port.</summary>
    public Uri? ClaimedHub { get; private set; }

    /// <summary><paramref name="authKey"/>: the Tailscale auth key of a keyed network step. <paramref name="sudoPassword"/>:
    /// the password of a <c>sudo</c> that asks for one; the installer clears the array when it ends, however it ends.
    /// <paramref name="claim"/>: the claim of a hub plan (<see cref="Claim.SendAsync"/>): null when the hub took it, else
    /// the owner's words. <paramref name="readHub"/>: a read of the hub while the install waits for its code
    /// (<see cref="Claim.ReadHubAsync"/>). <paramref name="firstRun"/>: the install is the first run's, whose way out of a
    /// changed host key is Start again; <paramref name="policy"/>: where the owner's Tailscale policy is kept. Both
    /// choose the words of a failure, in each step's detail and in its error's line alike.</summary>
    public Installer(InstallPlan plan, string? authKey = null, char[]? sudoPassword = null,
                     Func<string, Uri, CancellationToken, Task<string?>>? claim = null,
                     Func<Uri, CancellationToken, Task<HubRead>>? readHub = null, InstallerClock? clock = null,
                     TimeSpan? verifyPause = null, bool firstRun = true, ServerCheck.PolicyPlace? policy = null)
    {
        this.firstRun = firstRun;
        this.policy = policy;
        this.plan = plan;
        this.authKey = authKey ?? "";
        this.sudoPassword = sudoPassword;
        this.claim = claim;
        this.readHub = readHub ?? ((_, _) => Task.FromResult(HubRead.Silent));
        this.clock = clock ?? InstallerClock.System;
        this.verifyPause = verifyPause ?? TimeSpan.FromSeconds(10);
        Reached = plan.Target;
    }

    /// <summary>An installer whose claim and hub reads go through the hub client and the PC's secret box.</summary>
    public static Installer For(InstallPlan plan, HubClient http, ISecretBox box, string? authKey = null, char[]? sudoPassword = null,
                                bool firstRun = true, ServerCheck.PolicyPlace? policy = null) =>
        new(plan, authKey, sudoPassword, (code, uri, cancel) => Claim.SendAsync(http, box, uri, code, cancel),
            (hub, cancel) => Claim.ReadHubAsync(http, box, hub, cancel), firstRun: firstRun, policy: policy);

    /// <summary>A plan with no claim (a join, a check, a restart, an update), run over <paramref name="remote"/>.
    /// <paramref name="authKey"/>: the key of a keyed plan's network step, the one that the plan was made with.</summary>
    public static Task<VerifyChecklist> RunAsync(InstallPlan plan, IRemote remote, Action<InstallProgress> progress,
                                                 CancellationToken cancel, string? authKey = null) =>
        new Installer(plan, authKey).RunAsync(remote, progress, cancel);

    /// <summary>**Runs the whole install** and answers with the server's own checklist. <paramref name="report"/> is
    /// called for each step as it starts and as it ends.</summary>
    public async Task<VerifyChecklist> RunAsync(IRemote remote, Action<InstallProgress> report, CancellationToken cancel)
    {
        try
        {
            foreach (var step in plan.Steps)
            {
                report(new InstallProgress(step.Id, step.Title, step.Says, ProgressState.Running));
                try
                {
                    var lines = await PerformAsync(remote, step, report, cancel);
                    if (step.Id == "network" && InstallPlan.PrivateAddress(lines) is { } address) Reached = Moved(Reached, address);
                    if (step.Action is StepAction.Verify)
                    {
                        var output = string.Join("\n", lines);
                        var checklist = VerifyChecklist.Read(output, clock.Now.ToUnixTimeMilliseconds() / 1000.0);
                        if (checklist is null)
                        {
                            // Text that holds no list of checks is the server's own error: the stop keeps its line.
                            if (plan.Installs && lines.Count > 0 && !VerifyChecklist.HoldsList(output))
                                throw InstallError.Step(step.Title, lines[^1]);
                            throw InstallError.NoChecklist();
                        }
                        report(new InstallProgress(step.Id, step.Title, step.Says, ProgressState.Done, [checklist.Line]));
                        return checklist;
                    }
                    report(new InstallProgress(step.Id, step.Title, step.Says, ProgressState.Done, lines.TakeLast(12).ToList()));
                }
                catch (Exception e) when (e is not OutOfMemoryException)
                {
                    var says = e is InstallError install ? install.Description : e.Message;
                    report(new InstallProgress(step.Id, step.Title, step.Says, ProgressState.Failed, lastOutput.TakeLast(12).ToList(), says));
                    throw;
                }
            }
            throw InstallError.NoChecklist();
        }
        finally
        {
            if (sudoPassword is not null) Array.Clear(sudoPassword);
        }
    }

    private async Task<IReadOnlyList<string>> PerformAsync(IRemote remote, InstallStep step, Action<InstallProgress> report,
                                                           CancellationToken cancel)
    {
        switch (step.Action)
        {
            case StepAction.Check check:
                return await CheckAsync(remote, step, check, report, cancel);
            case StepAction.Run run:
                return await SshAsync(remote, run.Program, step.Title, null, RunLimit, cancel);
            case StepAction.Join join:
            {
                // The line leaves its own checks to the plan's next step (InstallPlan.VerifyLater). A join.sh from
                // before that runs them, and a status that is not 0 is then the line's own answer about verify: taken
                // when the server printed verify's last word, and the checks that follow say what is true.
                var (answer, lines) = await CallAsync(remote, InstallPlan.VerifyLater + join.Line, null, JoinLimit, Runs.Root, cancel);
                lastOutput = lines;
                if (answer.ExitStatus == 0 || lines.Any(l => l.Contains(VerifyChecklist.ReadyLine, StringComparison.Ordinal))) return lines;
                ThrowFailure(step.Title, answer, lines);
                throw InstallError.Step(step.Title, lines.LastOrDefault() ?? JoinNoChecks);
            }
            case StepAction.SendAuthKey send:
            {
                // An installer made without the plan's key would send an empty key, and the server would not reach the
                // private network (the first run's join did so): it stops here, as the claim step stops with no claim.
                if (authKey.Length == 0) throw new InvalidOperationException("this installer was given no key, and its plan sends one");
                var key = Encoding.UTF8.GetBytes(authKey);
                try { return await SshAsync(remote, send.Program, step.Title, key, AuthKeyLimit, cancel); }
                finally { CryptographicOperations.ZeroMemory(key); }
            }
            case StepAction.Detach detach:
                return await SshAsync(remote, detach.Program, step.Title, null, DetachLimit, cancel);
            case StepAction.WaitFor wait:
                return await WaitAsync(remote, wait.Program, wait.Mark, wait.Every, wait.Within, step, false, report, cancel);
            case StepAction.WaitForClaim wait:
                return await WaitAsync(remote, wait.Program, ClaimCode.LogMark, wait.Every, wait.Within, step, true, report, cancel);
            case StepAction.SignIn signIn:
                return await SignInAsync(remote, signIn, step, report, cancel);
            case StepAction.Claim:
                return await ClaimAsync(cancel);
            case StepAction.Verify verify:
                return await VerifyAsync(remote, verify.Program, step, cancel);
            default:
                throw new InvalidOperationException("a step of no known kind");
        }
    }

    /// <summary>**The claim step**: nothing when this PC owns the hub already (its wait read so); else the code and the
    /// address that the installer printed, only to an address of 100.64.0.0/10 and the path <c>/claim</c>.</summary>
    private async Task<IReadOnlyList<string>> ClaimAsync(CancellationToken cancel)
    {
        if (ownedHub is { } owned)
        {
            ClaimedHub = owned;
            return [$"This PC claimed the hub at {owned.Host}."];
        }
        var found = foundClaim ?? ClaimCode.Found(string.Join("\n", lastOutput)) ?? throw InstallError.NoClaimCode();
        if (!Claim.IsTarget(found.Claim)) throw InstallError.Step(Claim.Title, OwnerPcKey.NotOnYourNetwork);
        if (claim is null) throw new InvalidOperationException("this installer was given no claim, and its plan has one");
        if (await claim(found.Code, found.Claim, cancel) is { } refused) throw InstallError.Step(Claim.Title, refused);
        ClaimedHub = new Uri(found.Claim.GetLeftPart(UriPartial.Authority) + "/");
        return [$"This PC claimed the hub at {found.Claim.Host}."];
    }

    /// <summary>**The server's checks, the last step.** A call that never reached the server (the four ways of not
    /// reaching one) is made again, <see cref="VerifyTries"/> times in all; a call that broke after it began, a login
    /// that the server did not take, and a call past its time are not. A machine's own check asks one time.</summary>
    private async Task<IReadOnlyList<string>> VerifyAsync(IRemote remote, string program, InstallStep step, CancellationToken cancel)
    {
        var left = VerifyTries;
        while (true)
        {
            var (answer, lines) = await CallAsync(remote, program, null, VerifyLimit, Runs.Root, cancel);
            lastOutput = lines;
            if (!plan.Installs || answer.Failure is null || VerifyChecklist.Read(string.Join("\n", lines)) is not null) return lines;
            left--;
            if (left > 0 && answer.Failure is RemoteFailure.NotFound or RemoteFailure.Refused or RemoteFailure.NoAnswer or RemoteFailure.Closed)
            {
                await clock.DelayAsync(verifyPause, cancel);
                continue;
            }
            ThrowFailure(step.Title, answer, lines);
        }
    }

    /// <summary>**The check of the server, as the install's first step**: a server that cannot take the install is said
    /// so here, before anything on it changes; one that still starts is read again until it does not.</summary>
    private async Task<IReadOnlyList<string>> CheckAsync(IRemote remote, InstallStep step, StepAction.Check check,
                                                         Action<InstallProgress> report, CancellationToken cancel)
    {
        var deadline = clock.Now.AddSeconds(check.Within);
        var script = Encoding.UTF8.GetBytes(ServerCheck.Script);
        while (true)
        {
            var lines = await SshAsync(remote, "/bin/sh -s", step.Title, script, CheckLimit, cancel, runs: Runs.Login);
            var reading = ServerCheck.Read(string.Join("\n", lines)) ?? throw InstallError.Step(step.Title, NoUser);
            if (reading.Uid != 0 && !plan.Target.BecomeRoot) throw InstallError.NotRoot(plan.Target.User);
            var holds = sudoPassword is { Length: > 0 };
            switch (ServerCheck.VerdictOf(reading, plan.Job, Reached.Port, holds))
            {
                case ServerCheck.Verdict.Ready ready:
                    // A password is fed only to a sudo that asks for one; one that asks nothing never sees it.
                    feedsSudo = holds && reading.Sudo == ServerCheck.Sudo.Password && plan.Target.BecomeRoot;
                    if (!feedsSudo && sudoPassword is not null) Array.Clear(sudoPassword);
                    return [ready.Summary, ready.Changes];
                case ServerCheck.Verdict.Stop stop:
                    throw InstallError.CheckStopped(stop.Says);
                case ServerCheck.Verdict.NeedsPassword need:
                    throw InstallError.NeedsPassword(need.Need);
                case ServerCheck.Verdict.Wait wait:
                    if (clock.Now >= deadline) throw InstallError.TimedOut(step.Title);
                    report(new InstallProgress(step.Id, step.Title, step.Says, ProgressState.Running, [wait.Says]));
                    await clock.DelayAsync(TimeSpan.FromSeconds(check.Every), cancel);
                    break;
            }
        }
    }

    /// <summary>Reads the installer's log until it prints <paramref name="mark"/>. Each read that finds the installer at a
    /// new step of its own says so as this step's line. <paramref name="forClaim"/>: the wait for the link code, whose
    /// reads with no code also ask the hub whether this PC owns it already.
    /// **Reads that reach nothing are counted** (the Mac's <c>MachineInstaller.wait</c>, F4 piece 5): at the third in a
    /// row the step is reported again as <see cref="InstallProgress.Unreachable"/>, with the installer's step that it said
    /// last, and the next read that reaches the server reports it without. A count of reads and not a time decides, and it
    /// ends nothing: the wait ends as before.</summary>
    private async Task<IReadOnlyList<string>> WaitAsync(IRemote remote, string program, string mark, double every, double within,
                                                        InstallStep step, bool forClaim, Action<InstallProgress> report,
                                                        CancellationToken cancel)
    {
        var deadline = clock.Now.AddSeconds(within);
        string? said = null;
        var failed = 0;
        var saidUnreachable = false;
        if (forClaim) { hubRefusals = 0; installerMadeNoCode = false; }
        while (clock.Now < deadline)
        {
            var raw = await SshAsync(remote, program, step.Title, null, ReadLimit, cancel, allowFailure: true, hide: false);
            var reached = lastFailure is null;
            failed = reached ? 0 : failed + 1;
            if (failed == UnreachedReads)
            {
                saidUnreachable = true;
                report(new InstallProgress(step.Id, step.Title, step.Says, ProgressState.Running, said is null ? [] : [said], Unreachable: true));
            }
            if (forClaim && ClaimCode.Found(string.Join("\n", raw)) is { } found)
            {
                // The link code is one-time: no line that this app shows holds it.
                foundClaim = found;
                hidden.Add(ClaimCode.Grouped(found.Code));
                hidden.Add(found.Code);
            }
            var lines = raw.Select(Hide).ToList();
            lastOutput = lines;
            if (InstallPlan.StopLine(lines) is { } stop) throw InstallError.Step(step.Title, stop);
            if (string.Join("\n", raw).Contains(mark, StringComparison.Ordinal)) return lines;
            if (forClaim && await OwnsTheHubAsync(step, lines, cancel)) return lines;
            var now = lines.LastOrDefault(l => InstallPhases.InstallerStep(l) is not null);
            if (now is not null && (now != said || (reached && saidUnreachable)))
            {
                said = now;
                saidUnreachable = false;
                report(new InstallProgress(step.Id, step.Title, step.Says, ProgressState.Running, [now]));
            }
            else if (reached && saidUnreachable)
            {
                saidUnreachable = false;
                report(new InstallProgress(step.Id, step.Title, step.Says, ProgressState.Running, said is null ? [] : [said]));
            }
            await clock.DelayAsync(TimeSpan.FromSeconds(every), cancel);
        }
        throw InstallError.TimedOut(step.Title);
    }

    /// <summary>**Whether this PC owns the hub already**, read from the hub itself at the address that the network step
    /// gave it. A refusal stops the install only with two signs together: the installer's line that it made no code,
    /// and the hub's refusal at two reads in a row.</summary>
    private async Task<bool> OwnsTheHubAsync(InstallStep step, IReadOnlyList<string> log, CancellationToken cancel)
    {
        if (log.Any(l => l.Contains(NoCodeMade, StringComparison.Ordinal))) installerMadeNoCode = true;
        if (!ClaimCode.IsPrivateAddress(Reached.Host)) return false;
        var hub = new Uri($"http://{Reached.Host}:{Claim.HubPort}/");
        switch (await readHub(hub, cancel))
        {
            case HubRead.Serves:
                ownedHub = hub;
                return true;
            case HubRead.Refuses:
                hubRefusals++;
                if (installerMadeNoCode && hubRefusals >= 2) throw InstallError.Step(step.Title, NotThisPcs);
                return false;
            default:
                hubRefusals = 0;
                return false;
        }
    }

    /// <summary>Tailscale's sign-in: started on the server, then read until the server is on the network. The link goes
    /// to the screen as this step's lines.</summary>
    private async Task<IReadOnlyList<string>> SignInAsync(IRemote remote, StepAction.SignIn signIn, InstallStep step,
                                                          Action<InstallProgress> report, CancellationToken cancel)
    {
        await SshAsync(remote, signIn.Start, step.Title, null, SignInStartLimit, cancel);
        var deadline = clock.Now.AddSeconds(signIn.Within);
        var shown = false;      // a link he never saw was not his to approve
        var answered = false;   // the last read reached the server
        while (clock.Now < deadline)
        {
            var lines = await SshAsync(remote, signIn.Watch, step.Title, null, SignInCheckLimit, cancel, allowFailure: true);
            answered = lines.Any(l => l.StartsWith(NetworkSignIn.NameMark, StringComparison.Ordinal));
            switch (NetworkSignIn.Read(lines))
            {
                case NetworkSignIn.Reading.On:
                    return lines;
                case NetworkSignIn.Reading.Ended ended:
                    throw InstallError.Step(step.Title, ended.Says == NetworkSignIn.NotApproved && !shown ? NetworkSignIn.NotStarted : ended.Says);
                case NetworkSignIn.Reading.Waiting { Link: not null }:
                    shown = true;
                    report(new InstallProgress(step.Id, step.Title, step.Says, ProgressState.Running, lines));
                    break;
            }
            await clock.DelayAsync(TimeSpan.FromSeconds(signIn.Every), cancel);
        }
        if (!answered) throw InstallError.TimedOut(step.Title);
        throw InstallError.Step(step.Title, shown ? NetworkSignIn.NotApproved : NetworkSignIn.NotStarted);
    }

    /// <summary>One program as a step runs it: its lines when it ended with 0 (or with any status, for a read of a
    /// wait); else the step stops with the server's last line, or with the PC's words for the way IRemote failed.</summary>
    private async Task<IReadOnlyList<string>> SshAsync(IRemote remote, string program, string title, byte[]? stdin, double limit,
                                                       CancellationToken cancel, bool allowFailure = false, Runs runs = Runs.Root,
                                                       bool hide = true)
    {
        var (answer, lines) = await CallAsync(remote, program, stdin, limit, runs, cancel, hide);
        lastOutput = lines;
        lastFailure = answer.Failure;
        if (allowFailure || answer.ExitStatus == 0) return lines;
        ThrowFailure(title, answer, lines);
        throw InstallError.Step(title, lines.LastOrDefault() ?? $"The server answered {answer.ExitStatus}.");
    }

    /// <summary>A call that IRemote did not run to its end stops the step: past its time limit, the Mac's
    /// <c>timedOut</c>; else the PC's words for that way. A program that a signal ended has no status and no failure:
    /// with lines, the step failed with its last line, as the Mac's (its caller says so); with none, the connection
    /// broke.</summary>
    private void ThrowFailure(string title, RemoteResult answer, IReadOnlyList<string> lines)
    {
        if (answer.Failure == RemoteFailure.TimedOut) throw InstallError.TimedOut(title);
        var failure = answer.Failure ?? (answer.ExitStatus is null && lines.Count == 0 ? RemoteFailure.Dropped : (RemoteFailure?)null);
        if (failure is not { } way) return;
        var says = ServerCheck.Failed(Reached.Host, Reached.Port, Reached.User, way, new RemoteLogin.AppKey(), firstRun, policy);
        throw InstallError.Remote(title, says, way, Reached.Port, Reached.User, firstRun, policy);
    }

    /// <summary>**One program on the server.** A root step of an install that feeds <c>sudo -S</c> carries the password
    /// on the first line of its standard input, and the step's own input after it; that copy is cleared after the call.
    /// The lines are those of both streams in the order they came, each trimmed, with no empty one, and with the
    /// owner's secrets taken out.</summary>
    private async Task<(RemoteResult Answer, IReadOnlyList<string> Lines)> CallAsync(IRemote remote, string program, byte[]? stdin,
                                                                                    double limit, Runs runs, CancellationToken cancel,
                                                                                    bool hide = true)
    {
        var feeds = runs == Runs.Root && feedsSudo && sudoPassword is { Length: > 0 };
        var command = InstallPlan.Command(program, Reached, feeds ? Runs.RootWithPassword : runs);
        byte[]? input = stdin, made = null;
        if (feeds)
        {
            var password = Encoding.UTF8.GetBytes(sudoPassword!);
            made = new byte[password.Length + 1 + (stdin?.Length ?? 0)];
            password.CopyTo(made, 0);
            made[password.Length] = (byte)'\n';
            stdin?.CopyTo(made, password.Length + 1);
            CryptographicOperations.ZeroMemory(password);
            input = made;
        }
        var arrived = new List<string>();
        var kept = 0;
        try
        {
            var call = new RemoteCall(Reached.Remote, command, input, new RemoteLogin.AppKey(), HostKeyRule.TakeNew,
                                      RemoteCall.ConnectTimeout) { Limit = TimeSpan.FromSeconds(limit) };
            var answer = await remote.RunAsync(call, line =>
            {
                if (kept > OutputLimit) return;
                kept += line.Length + 1;
                arrived.Add(line);
            }, cancel);
            if (answer.Failure == RemoteFailure.Canceled) throw new OperationCanceledException(cancel);
            if (arrived.Count == 0 && (answer.Output.Length > 0 || answer.Errors.Length > 0))
                arrived.AddRange((answer.Output + "\n" + answer.Errors).Split('\n'));
            var lines = arrived.Select(l => l.Trim(' ', '\t')).Where(l => l.Length > 0).Select(l => hide ? Hide(l) : l).ToList();
            return (answer, lines);
        }
        finally
        {
            if (made is not null) CryptographicOperations.ZeroMemory(made);
        }
    }

    /// <summary>A line with the owner's secrets taken out of it: the plan's, the link code that the installer printed,
    /// and the sudo password that this install holds.</summary>
    public string Redact(string text) => Hide(text);

    private string Hide(string text)
    {
        var line = plan.Redact(text);
        foreach (var secret in hidden) line = line.Replace(secret, "(not shown)", StringComparison.Ordinal);
        if (sudoPassword is not { Length: > 0 } password) return line;
        var at = line.AsSpan().IndexOf((ReadOnlySpan<char>)password);
        if (at < 0) return line;
        var built = new StringBuilder();
        var rest = line.AsSpan();
        while ((at = rest.IndexOf((ReadOnlySpan<char>)password)) >= 0)
        {
            built.Append(rest[..at]).Append("(not shown)");
            rest = rest[(at + password.Length)..];
        }
        return built.Append(rest).ToString();
    }
}
