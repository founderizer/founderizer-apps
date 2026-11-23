using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;
using Founderizer.Core;
using Founderizer.Remote;

namespace Founderizer.Setup.Install;

// The install of a Linux server of a fleet from the owner's PC (windows-app-plan-v2.md, piece L3): the Mac's
// FleetCore/MachineInstall.swift, with the same steps and the same programs, which app/vectors/remote-install.json
// holds (InstallVectorTests). Only the SSH under it differs: IRemote (Founderizer.Remote) in place of the Mac's ssh.
//
// **No program lives in a text file** (8.10): each comes from this code, whose strings have line feeds only.

/// <summary>Which machine of a fleet is checked, which says where its checkout is and as whom <c>verify</c> runs there
/// (the Mac's MachineCheckout).</summary>
public enum MachineCheckout
{
    /// <summary>The hub's own machine: the checkout that its service runs in.</summary>
    Hub,
    /// <summary>A Linux machine that joined: <c>fleet-server</c>, owned by the service user.</summary>
    LinuxWorker,
    /// <summary>A Mac that joined: <c>fleet-server</c> in the home of the Mac user whose LaunchAgents run its agents.</summary>
    MacWorker,
}

/// <summary>The two installs (the Mac's InstallJob): the hub itself, and a machine that joins a hub that runs.</summary>
public enum InstallJob { Hub, Join }

/// <summary>The steps of the first run's servers' slider (the Mac's ServersStep): one server for all, the hub and its
/// keys on a server of their own, the hub and each agent on a server of their own.</summary>
public enum ServersStep { One, Two, Each }

/// <summary>As whom a remote program runs (the Mac's InstallPlan.Runs).</summary>
public enum Runs
{
    /// <summary>As the user this PC logs in as: the check of the server.</summary>
    Login,
    /// <summary>As root, through <c>sudo -n</c> for a user that is not root.</summary>
    Root,
    /// <summary>As root, through a <c>sudo -S</c> that reads the password from the first line of standard input.</summary>
    RootWithPassword,
}

/// <summary>The manager's name on the page "Name your manager" (the Mac's ManagerName in FleetShape.swift).</summary>
public static partial class ManagerName
{
    /// <summary>The name that stands in the field when the page opens.</summary>
    public const string Suggested = "Juno";
    /// <summary>The name of a manager whose owner gave none that the hub takes.</summary>
    public const string Fallback = "manager";

    /// <summary>The names that the fleet uses itself on a server, and their starts: the installer refuses them for a
    /// manager (hubsetup.py RESERVED_AGENT_NAMES, FLEET_OWN_NAMES, FLEET_OWN_STARTS).</summary>
    internal static readonly string[] Taken = ["owner", "hub", "agents", "channels", "chats", "checks", "git", "pilot",
                                               "server", "vault", "watch", "work"];
    internal static readonly string[] TakenStarts = ["login-", "vault-"];

    /// <summary>**The name that the hub gets**: the typed words in lower case when they are one name by the installer's
    /// rule (a letter, then letters, digits and "-", 2 to 26 characters, and no name of the fleet's own); else null.</summary>
    public static string? AgentName(string typed)
    {
        var name = typed.Trim().ToLowerInvariant();
        if (!Shape().IsMatch(name) || Taken.Contains(name) || TakenStarts.Any(s => name.StartsWith(s, StringComparison.Ordinal)))
            return null;
        return name;
    }

    [GeneratedRegex(@"\A[a-z][a-z0-9-]{1,25}\z", RegexOptions.CultureInvariant)]
    private static partial Regex Shape();
}

/// <summary>The server, as the owner gives it: an address, a user, a port, and whether the user becomes root with
/// <c>sudo</c> (the Mac's InstallTarget, with no key file: the PC logs in with the app's own key, or a password
/// once).</summary>
public sealed partial record InstallTarget(string Host, string User = "root", int Port = 22, bool BecomeRoot = false)
{
    /// <summary>Why this server cannot be installed as given, in the owner's words, or null.</summary>
    public string? Problem
    {
        get
        {
            if (!HostShape().IsMatch(Host)) return "Enter the address or host name of the server, as you reach it over SSH.";
            if (!UserShape().IsMatch(User)) return "Enter the user you reach that server with: root, or a user that can become root.";
            if (Port is < 1 or > 65535) return "The SSH port is between 1 and 65535.";
            return null;
        }
    }

    public bool IsValid => Problem is null;

    /// <summary>The target of an IRemote call.</summary>
    public RemoteTarget Remote => new(Host, Port, User);

    [GeneratedRegex(@"\A[a-zA-Z0-9]([a-zA-Z0-9.:-]{0,252}[a-zA-Z0-9])?\z", RegexOptions.CultureInvariant)]
    private static partial Regex HostShape();

    [GeneratedRegex(@"\A[a-z_][a-z0-9_-]{0,31}\z", RegexOptions.CultureInvariant)]
    private static partial Regex UserShape();
}

/// <summary>What the installer does with one step (the Mac's InstallStep.Action).</summary>
public abstract record StepAction
{
    private StepAction() { }

    /// <summary>The check of the server (<see cref="ServerCheck.Script"/>), as the login user, read again every
    /// <paramref name="Every"/> seconds while the server starts, for at most <paramref name="Within"/>.</summary>
    public sealed record Check(double Every, double Within) : StepAction;
    /// <summary>One command on the server, as root.</summary>
    public sealed record Run(string Program) : StepAction;
    /// <summary>The hub's own join line, whose last word is <c>verify</c>'s (the Mac's <c>join</c>).</summary>
    public sealed record Join(string Line) : StepAction
    {
        /// <summary>The line holds a one-time code: no text of this record names it.</summary>
        public override string ToString() => "Join { Line = (not shown) }";
    }
    /// <summary>One command whose standard input is the Tailscale auth key, so the key is in no argument.</summary>
    public sealed record SendAuthKey(string Program) : StepAction;
    /// <summary>One command, started and left running on the server.</summary>
    public sealed record Detach(string Program) : StepAction;
    /// <summary>Read this command's output every <paramref name="Every"/> seconds until it holds the mark.</summary>
    public sealed record WaitFor(string Program, string Mark, double Every, double Within) : StepAction;
    /// <summary>The wait for the hub installer's link code (<see cref="ClaimCode.LogMark"/>), which also asks the hub
    /// whether this PC owns it already.</summary>
    public sealed record WaitForClaim(string Program, double Every, double Within) : StepAction;
    /// <summary>Tailscale's own sign-in on the server (<c>Start</c>), and <c>Watch</c>, read until the server is on the private network.</summary>
    public sealed record SignIn(string Start, string Watch, double Every, double Within) : StepAction;
    /// <summary>This PC proves its own address to the new hub with the code the installer printed.</summary>
    public sealed record Claim() : StepAction;
    /// <summary><c>verify --json</c> on the server, whose answers become the checklist.</summary>
    public sealed record Verify(string Program) : StepAction;
}

/// <summary>One step of an install, in the order it runs.</summary>
public sealed record InstallStep(string Id, string Title, string Says, StepAction Action);

/// <summary>A system that an installer takes: <c>ID</c> and <c>VERSION_ID</c> of its os-release, and its name.</summary>
public sealed record InstallSystem(string Id, string Version, string Name);

/// <summary>**The ordered steps of one install, with what must never be written down** (the Mac's InstallPlan).
/// <c>Redactions</c> are the Tailscale auth key and the one-time join code: every line that this app shows or keeps
/// loses them (<see cref="Redact"/>).</summary>
public sealed record InstallPlan(InstallJob Job, InstallTarget Target, IReadOnlyList<InstallStep> Steps,
                                 IReadOnlyList<string> Redactions, bool Installs = false)
{
    /// <summary>A plan holds the auth key and the join code: its text names neither.</summary>
    public override string ToString() => $"InstallPlan {{ Job = {Job}, Target = {Target}, Steps = {Steps.Count} }}";

    // ------------------------------------------------------------ the installers' words

    /// <summary>The line an installer prints when it stops, in either brand.</summary>
    public static readonly IReadOnlyList<string> StopMarks =
        ["Founderizer install stopped:", "Fleet install stopped:", "Founderizer join stopped:", "Fleet join stopped:"];

    /// <summary>Whether an install stopped only because the server could not get onto the private network by itself and
    /// no Tailscale key was given.</summary>
    public static bool NeedsNetworkKey(string says)
    {
        var said = says.ToLowerInvariant();
        return said.Contains("not on your private network", StringComparison.Ordinal) ||
               said.Contains("no tailscale auth key came in", StringComparison.Ordinal) ||
               said.Contains("did not join with that auth key", StringComparison.Ordinal);
    }

    /// <summary>The line of an installer's output that says it stopped, or null.</summary>
    public static string? StopLine(IEnumerable<string> lines) =>
        lines.FirstOrDefault(line => StopMarks.Any(mark => line.Contains(mark, StringComparison.Ordinal)));

    /// <summary>The systems each installer takes, the one table of the check and of the words.</summary>
    public static readonly IReadOnlyList<InstallSystem> JoinTakes =
    [
        new("ubuntu", "22.04", "Ubuntu"), new("ubuntu", "24.04", "Ubuntu"), new("ubuntu", "26.04", "Ubuntu"),
        new("debian", "12", "Debian"), new("debian", "13", "Debian"),
    ];
    public static readonly IReadOnlyList<InstallSystem> HubTakes = JoinTakes;

    public static IReadOnlyList<InstallSystem> Systems(InstallJob job) => job == InstallJob.Hub ? HubTakes : JoinTakes;

    public static readonly string JoinSystems = SystemsLine(JoinTakes);
    public static readonly string HubSystems = SystemsLine(HubTakes);

    /// <summary>"This install needs Ubuntu 22.04, 24.04 or 26.04, or Debian 12 or 13."</summary>
    internal static string SystemsLine(IReadOnlyList<InstallSystem> systems)
    {
        var names = new List<string>();
        foreach (var system in systems) if (!names.Contains(system.Name)) names.Add(system.Name);
        var each = names.Select(name => name + " " + ServerCheck.Spoken(systems.Where(s => s.Name == name).Select(s => s.Version).ToList(), "or")).ToList();
        var all = each.Count > 1 ? string.Join(", ", each.Take(each.Count - 1)) + ", or " + each[^1] : string.Concat(each);
        return $"This install needs {all}.";
    }

    // ------------------------------------------------------------ the hub

    /// <summary>The published Founderizer repository, which a customer's download page may replace.</summary>
    public const string DefaultSource = "https://github.com/founderizer/founderizer.git";
    /// <summary>The manager gets a server of its own in its setup, so the hub's installer runs no agent on the hub.</summary>
    internal const string ManagerServer = "FLEET_MANAGER_SERVER=later";
    /// <summary>One server for all: the hub's own server takes agents, the manager among them.</summary>
    internal const string OneServerWord = "FLEET_HUB_SERVER=shared";
    /// <summary>The AI programs that <c>hub.sh --runtime</c> takes.</summary>
    internal static readonly string[] HubRuntimes = ["claude", "codex"];
    /// <summary>This app's own last step is <c>verify</c>, so the installer ends with none of its own.</summary>
    internal const string CallerVerifies = "FLEET_VERIFY=caller";
    internal const string HubLog = "/root/fleet-install.log";
    internal const string HubKit = "/root/fleet-kit";
    internal const string AuthKeyFile = "/root/fleet-authkey";
    internal const string HubCheckout = "/home/fleet/fleet-pilot";
    internal const string JoinCheckout = "/home/fleet/fleet-server";
    internal const string HubCheckoutOfItsService = "$(systemctl --user show -p WorkingDirectory --value fleet-hub 2>/dev/null)";
    internal const string ServiceUser = "fleet";

    /// <summary>The installer's word for the kept step of the first run's slider (the Mac's FleetShapeHub.installWord):
    /// <c>FLEET_SHAPE_STEP=two</c>; none for one server, whose own word writes it.</summary>
    public static string? ShapeWord(ServersStep step) => step == ServersStep.One ? null : "FLEET_SHAPE_STEP=" + Raw(step);

    internal static string Raw(ServersStep step) => step switch
    {
        ServersStep.One => "one",
        ServersStep.Two => "two",
        _ => "each",
    };

    /// <summary>**The install of a new hub** (INSTALL-PROMPT.md job A; the Mac's <c>InstallPlan.hub</c>): the server,
    /// the private network, the code, the plan, the installer itself, the claim that proves this PC to the hub, and
    /// <c>verify</c>. <paramref name="managerName"/> goes to the installer only when it is one name by the installer's
    /// rule; <paramref name="runtime"/> only with one server, and only <c>claude</c> or <c>codex</c>.</summary>
    public static InstallPlan Hub(InstallTarget target, string source, string? authKey, string? managerName = null,
                                  bool oneServer = false, ServersStep? shape = null, string? runtime = null)
    {
        var kit = HubKit;
        var log = HubLog;
        var kept = oneServer || shape is null ? null : ShapeWord(shape.Value);
        var layout = (kept is null ? "" : kept + " ") + (oneServer ? OneServerWord : ManagerServer);
        var program = oneServer && runtime is not null && HubRuntimes.Contains(runtime) ? " --runtime " + runtime : "";
        var named = managerName is not null && ManagerName.AgentName(managerName) == managerName ? " --manager-name " + managerName : "";
        var options = named + program;
        InstallStep[] steps =
        [
            new("read", ServerCheck.Title, "Which system it is, and whether we are root there.", ReadAction),
            new("network", "The private network",
                authKey is null ? "This server is already on your private network, so no key is needed."
                                : "Tailscale, with your key on standard input, and the address it gets.",
                authKey is null ? new StepAction.Run(OnNetwork) : KeyedNetwork),
            new("code", "The Founderizer code", "A copy of the code on the server, from your own download page.",
                new StepAction.Run(GitInstall + " || { " + PackagesStop + "; }; if test -d " + kit + "/.git; then git -C " + kit +
                                   " pull -q --ff-only; else git clone -q -- " + Quote(source) + " " + kit + " || { " + CloneStop +
                                   "; }; fi; git -C " + kit + " rev-parse --short HEAD; ls " + kit + "/hub.sh")),
            new("plan", "The plan", "Every step the install would take. It changes nothing.",
                new StepAction.Run(layout + " " + CallerVerifies + " sh " + kit + "/hub.sh --check" + options)),
            new("start", "Install the hub", "The installer runs on the server and writes what it does to a log.",
                new StepAction.Detach("setsid sh -c '" + layout + " " + CallerVerifies + " sh " + kit + "/hub.sh" + options +
                                      " < /dev/null > " + log + " 2>&1' > /dev/null 2>&1 < /dev/null &")),
            new("wait_claim", "Wait for the link code", "The installer makes a one-time code for this PC.",
                new StepAction.WaitForClaim("tail -n 60 " + log, 10, 1200)),
            new("claim", "Claim the hub", "This PC sends the code back, and the hub serves your pages to it alone.",
                new StepAction.Claim()),
            new("wait_ready", "Finish the install", "The security updates and the checks take some minutes.",
                new StepAction.WaitFor("tail -n 40 " + log, "READY", 20, 1800)),
            new("verify", "Check the server", "Every check of the server.", new StepAction.Verify(VerifyCommand(MachineCheckout.Hub))),
        ];
        return new InstallPlan(InstallJob.Hub, target, steps, authKey is null ? [] : [authKey], Installs: true);
    }

    /// <summary>The first step of both installs: the check, read again while the server starts.</summary>
    internal static readonly StepAction ReadAction = new StepAction.Check(ServerCheck.WaitEvery, ServerCheck.WaitWithin);

    /// <summary>How long each apt-get of an install waits for apt's lock.</summary>
    internal const int AptLockWait = 1200;

    internal static readonly string UpdateOnce =
        $"DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout={AptLockWait} -q update";

    /// <summary>git, which the code step needs and Debian's images do not have (INSTALL-PROMPT.md A3).</summary>
    internal static readonly string GitInstall =
        "command -v git >/dev/null 2>&1 || { { for try in 1 2 3 4 5 6 7 8 9; do " + UpdateOnce +
        " && break; sleep 15; false; done || " + UpdateOnce + "; } && DEBIAN_FRONTEND=noninteractive apt-get -o " +
        $"DPkg::Lock::Timeout={AptLockWait} -y -q install git; }}";

    internal const string PackagesStop = "echo 'Founderizer install stopped: The packages of this system could not be installed: " +
                                         "apt-get did not finish. A package mirror can fail for a moment: run the line again.'; exit 1";
    internal const string CloneStop = "echo 'Founderizer install stopped: Could not clone the Founderizer repository from its " +
                                      "address: git did not finish. Check the address, then run the line again.'; exit 1";

    internal static readonly string TailscaleThere = TailscaleStop(null);

    internal static string TailscaleStop(string? removing) =>
        "command -v tailscale >/dev/null 2>&1 || { " + (removing is null ? "" : "rm -f " + removing + "; ") +
        "echo 'Founderizer install stopped: Could not install Tailscale on this server: its installer did not " +
        "finish. A package mirror can fail for a moment: run the line again.'; exit 1; }; ";

    /// <summary>Tailscale's own installer, on a server that has none, with curl first.</summary>
    internal static readonly string TailscaleInstall =
        "command -v tailscale >/dev/null 2>&1 || { command -v curl >/dev/null 2>&1 || " +
        "{ export DEBIAN_FRONTEND=noninteractive; { for try in 1 2 3 4 5 6 7 8 9; do " + UpdateOnce + " >/dev/null " +
        "&& break; sleep 15; false; done || " + UpdateOnce + " >/dev/null; } && " +
        $"apt-get -o DPkg::Lock::Timeout={AptLockWait} -y -q install curl ca-certificates >/dev/null; }}; " +
        $"for try in 1 2 3; do apt-get -o DPkg::Lock::Timeout={AptLockWait} -q install </dev/null >/dev/null 2>&1; " +
        "curl -fsSL https://tailscale.com/install.sh | sh && command -v tailscale >/dev/null 2>&1 && break; " +
        "sleep 20; done; }; ";

    internal const int TailscaleUpWait = 300;

    /// <summary>The server onto the private network with the key on standard input, and the address it gets.</summary>
    internal static readonly StepAction KeyedNetwork = new StepAction.SendAuthKey(
        "umask 077; cat > " + AuthKeyFile + "; " + TailscaleInstall + TailscaleStop(AuthKeyFile) +
        "tailscale status >/dev/null 2>&1 || tailscale up --reset --auth-key=file:" + AuthKeyFile + " " +
        $"--accept-dns=false --timeout={TailscaleUpWait}s; rm -f " + AuthKeyFile + "; " +
        "tailscale status >/dev/null 2>&1 && tailscale ip -4");

    /// <summary>The address of a server that is on the private network already; on one that is not, the words that ask
    /// for the key.</summary>
    internal static readonly string OnNetwork =
        "tailscale status >/dev/null 2>&1 && tailscale ip -4 2>/dev/null | grep . || { " +
        "tailscale status --json 2>/dev/null | grep -q '\"BackendState\": \"NeedsMachineAuth\"' " +
        "&& { tailscale status; exit 1; }; echo '" + NetworkSignIn.NotOnNetwork + "'; exit 1; }";

    /// <summary>The server's address on the private network, as the network step printed it, or null.</summary>
    public static string? PrivateAddress(IReadOnlyList<string> lines) => lines.LastOrDefault(ClaimCode.IsPrivateAddress);

    // ------------------------------------------------------------ a server that joins

    /// <summary>**A server that joins a hub that runs** (INSTALL-PROMPT.md job B): the hub's join line, run exactly as
    /// the hub wrote it.</summary>
    public static InstallPlan Join(InstallTarget target, string line, string code, string? authKey)
    {
        var network = authKey is null ? NetworkSignIn.Action(TailscaleInstall, NetworkSignIn.Tags(line)) : KeyedNetwork;
        InstallStep[] steps =
        [
            new("read", ServerCheck.Title, "Which system it is, and whether we are root there.", ReadAction),
            new("network", "The private network",
                authKey is null ? "Tailscale, with a sign-in link for you when this server is not on it yet."
                                : "Tailscale, with your key on standard input, and the address it gets.", network),
            new("join", "Join the fleet", "The line your hub gave for this server, as it wrote it.", new StepAction.Join(line)),
            new("verify", "Check the server", "Every check of the server.", new StepAction.Verify(VerifyCommand(MachineCheckout.LinuxWorker))),
        ];
        var redactions = new List<string>();
        if (authKey is not null) redactions.Add(authKey);
        redactions.Add(code);
        return new InstallPlan(InstallJob.Join, target, steps, redactions, Installs: true);
    }

    /// <summary>**What the installer puts before a join line**: join.sh then leaves its own checks out, because the
    /// plan's next step runs them in the form that the app reads, so the self-test runs once (the Mac's
    /// InstallPlan.verifyLater). A join.sh from before it runs its checks as before.</summary>
    public const string VerifyLater = "export " + CallerVerifies + "; ";

    /// <summary>Only the checks of one machine: <c>verify --json</c> there.</summary>
    public static InstallPlan Check(InstallTarget target, MachineCheckout machine) =>
        new(InstallJob.Join, target,
            [new InstallStep("verify", "Check the server", "Every check of that server.", new StepAction.Verify(VerifyCommand(machine)))], []);

    internal const string RestartMark = "/run/founderizer-restart";
    internal const string BootedMark = "FLEET_BOOTED";

    /// <summary>A restart of one machine, and the proof that it came back.</summary>
    public static InstallPlan Restart(InstallTarget target, MachineCheckout machine)
    {
        const string mark = RestartMark, back = BootedMark;
        InstallStep[] steps =
        [
            new("mark", "Mark this boot", "A file in the server's own /run, which only a restart clears.",
                new StepAction.Run($"touch {mark} && test -f {mark} && echo marked")),
            new("restart", "Restart the server", "The server restarts, after this connection closes.",
                new StepAction.Detach("setsid sh -c 'sleep 2; systemctl reboot || reboot' > /dev/null 2>&1 < /dev/null &")),
            new("back", "Wait for it to come back",
                "The server answers again, with its /run empty, its units started and its clock caught up.",
                new StepAction.WaitFor($"test -f {mark} || {{ systemctl is-system-running 2>/dev/null " +
                                       "| grep -q -e running -e degraded && { timedatectl show -p NTPSynchronized " +
                                       "--value 2>/dev/null | grep -q yes || test \"$(cut -d. -f1 /proc/uptime)\" " +
                                       $"-gt 120; }} && echo {back}; }}", back, 10, 900)),
            new("verify", "Check the server", "Every check again, to say where the server stands after its restart.",
                new StepAction.Verify(VerifyCommand(machine))),
        ];
        return new InstallPlan(InstallJob.Join, target, steps, []);
    }

    /// <summary>The configuration ref, the one branch a fleet runs.</summary>
    public const string ConfigRef = "config";
    internal const string CanUpdateMark = "FLEET_CAN_UPDATE";
    internal const string HelperUpMark = "FLEET_HELPER_UP";

    /// <summary>One agent's own OS user on a Linux machine of a fleet.</summary>
    public static string AgentUser(string agent) => "fleet-" + agent;

    /// <summary>One program as that agent's own OS user, from that user's home, PATH and user services.</summary>
    internal static string AsAgent(string agent, string inner)
    {
        var user = AgentUser(agent);
        return $"runuser -u {user} -- env HOME=/home/{user} XDG_RUNTIME_DIR=/run/user/$(id -u {user}) " +
               $"PATH=/home/{user}/.local/bin:/usr/local/bin:/usr/bin:/bin sh -c {Quote(inner)}";
    }

    /// <summary>The update of one agent's helper over SSH: fetch, fast-forward onto the configuration ref, restart that
    /// agent's service, and the checks again. <paramref name="label"/> is the agent as the apps name it (its name with
    /// capitals, or its role when one word of the role is the name).</summary>
    public static InstallPlan Update(InstallTarget target, MachineCheckout machine, string agent, string? label = null)
    {
        var kit = $"/home/{AgentUser(agent)}/fleet-{agent}";
        var reference = "refs/remotes/origin/" + ConfigRef;
        var unit = $"fleet-{agent}.service";
        var read = $"cd {kit} 2>/dev/null || {{ echo 'the checkout {kit} is not there'; exit 1; }}; " +
                   "said=$(git fetch -q origin 2>&1) || { echo \"the fetch of origin failed: $said\"; exit 1; }; " +
                   $"git rev-parse --verify --quiet {reference} >/dev/null || " +
                   $"{{ echo 'origin has no {ConfigRef} ref, so there is nothing to move onto'; exit 1; }}; " +
                   "test -z \"$(git status --porcelain --untracked-files=no)\" || " +
                   "{ echo 'the checkout has its own changes, so it stays where it is'; exit 1; }; " +
                   $"git merge-base --is-ancestor HEAD {reference} || " +
                   $"{{ echo 'the checkout holds commits that {ConfigRef} does not, so it cannot be moved on. " +
                   $"Push them, or look at the checkout.'; exit 1; }}; echo {CanUpdateMark}";
        var move = $"cd {kit} || exit 1; said=$(git merge -q --ff-only {reference} 2>&1) || " +
                   $"{{ echo \"the checkout did not move onto {ConfigRef}: $said\"; exit 1; }}; git rev-parse --short HEAD";
        var service = $"systemctl --user restart {unit} || {{ echo '{unit} did not restart'; exit 1; }}; " +
                      $"systemctl --user is-active -q {unit} || " +
                      $"{{ echo '{unit} is not running after its restart'; exit 1; }}; echo {HelperUpMark}";
        var who = label ?? AgentBook.Capitalized(agent);
        InstallStep[] steps =
        [
            new("checkout", "Read the checkout",
                $"What Founderizer on {who}'s server has, and whether it can move on without losing anything.",
                new StepAction.Run(AsAgent(agent, read))),
            new("move", "Move the checkout on", $"It fast-forwards onto {ConfigRef}, as Founderizer's own update does.",
                new StepAction.Run(AsAgent(agent, move))),
            new("service", "Restart Founderizer", $"{who}'s own service, which is what loads the new checkout.",
                new StepAction.Run(AsAgent(agent, service))),
            new("verify", "Check the server", "Every check again, to say where the server stands after the update.",
                new StepAction.Verify(VerifyCommand(machine))),
        ];
        return new InstallPlan(InstallJob.Join, target, steps, []);
    }

    /// <summary><c>verify --json</c> in that machine's checkout, as the user whose services it reads.</summary>
    public static string VerifyCommand(MachineCheckout machine)
    {
        if (machine == MachineCheckout.MacWorker)
            return "PATH=/opt/homebrew/bin:/usr/local/bin:$PATH; cd \"$HOME/fleet-server\" && python3 fleet.py verify --json";
        var inner = VerifyProgram(machine);
        return $"runuser -u {ServiceUser} -- env HOME=/home/{ServiceUser} XDG_RUNTIME_DIR=/run/user/$(id -u {ServiceUser}) " +
               $"PATH=/home/{ServiceUser}/.local/bin:/usr/local/bin:/usr/bin:/bin sh -c {Quote(inner)}";
    }

    internal static string VerifyProgram(MachineCheckout machine) =>
        machine != MachineCheckout.Hub
            ? $"cd {JoinCheckout} && python3 fleet.py verify --json"
            : $"kit={HubCheckoutOfItsService}; cd \"${{kit:-{HubCheckout}}}\" && python3 fleet.py verify --json";

    // ------------------------------------------------------------ the command that the server gets

    /// <summary>**The command for one remote program** (the last word of the Mac's <c>ssh</c> arguments): the program
    /// itself for root and for <see cref="Runs.Login"/>, and for a user that becomes root, the program through
    /// <c>sudo -i</c> in the words of <see cref="ThroughSudo"/>. IRemote gets it as its program.</summary>
    public static string Command(string program, InstallTarget reaching, Runs runs) => runs switch
    {
        Runs.Root when reaching.BecomeRoot => "sudo -n -i -- /bin/sh -c " + Quote(ThroughSudo(program)),
        Runs.RootWithPassword when reaching.BecomeRoot => "sudo -S -k -p '' -i -- /bin/sh -c " + Quote(ThroughSudo(program)),
        _ => program,
    };

    /// <summary>**A root program in words that reach <c>/bin/sh</c> unchanged through <c>sudo -i</c>** (the Mac's
    /// throughSudo): a program in printable ASCII with no "$" that sudo would pass bare goes as it is; each other one
    /// goes as one <c>printf</c> with octal escapes, which <c>/bin/sh</c> runs with <c>eval</c>.</summary>
    internal static string ThroughSudo(string program)
    {
        if (ArrivesThroughSudo(program)) return program;
        const string special = "'\\%`\"$";
        var format = new StringBuilder();
        var bytes = Encoding.UTF8.GetBytes(program);
        for (var index = 0; index < bytes.Length; index++)
        {
            var b = bytes[index];
            if (b is >= 0x20 and <= 0x7e && !special.Contains((char)b) && !(index == 0 && b == (byte)'-'))
                format.Append((char)b);
            else
                format.Append('\\').Append((char)('0' + (b >> 6))).Append((char)('0' + ((b >> 3) & 7))).Append((char)('0' + (b & 7)));
        }
        return "eval \"`printf '" + format + "'`\"";
    }

    /// <summary>Whether root's login shell gives <c>/bin/sh</c> this program unchanged after <c>sudo -i</c>.</summary>
    internal static bool ArrivesThroughSudo(string program)
    {
        var bytes = Encoding.UTF8.GetBytes(program);
        for (var index = 0; index < bytes.Length; index++)
        {
            if (bytes[index] is < 0x20 or > 0x7e) return false;
            if (bytes[index] == (byte)'$' && index + 1 < bytes.Length && BareThroughSudo(bytes[index + 1])) return false;
        }
        return true;
    }

    private static bool BareThroughSudo(byte b) =>
        b is >= 0x30 and <= 0x39 or >= 0x41 and <= 0x5a or >= 0x61 and <= 0x7a || b == (byte)'_' || b == (byte)'-' || b == (byte)'$';

    /// <summary>The same line with the owner's own secrets taken out of it: everything this app shows, keeps or reports
    /// goes through here.</summary>
    public string Redact(string text)
    {
        var line = text;
        foreach (var secret in Redactions)
            if (secret.Length >= 8) line = line.Replace(secret, "(not shown)", StringComparison.Ordinal);
        return line;
    }

    /// <summary>One shell word, for a program put inside another one.</summary>
    internal static string Quote(string value) => "'" + value.Replace("'", "'\\''", StringComparison.Ordinal) + "'";
}

/// <summary>**Tailscale's own sign-in on a server that is not on the private network** (the Mac's NetworkSignIn): the
/// server prints a link, the page shows it, and the install goes on by itself once the owner approved it.</summary>
public sealed partial record NetworkSignIn(Uri Url, string? Server)
{
    internal const string Log = "/tmp/fleet-tailscale-up.log";
    internal const string OnMark = "fleet-on-network";
    internal const string EndMark = "fleet-sign-in-ended";
    internal const string NameMark = "fleet-machine-name=";
    internal const int WaitMinutes = 15;
    internal const double Within = WaitMinutes * 60 + 60;
    internal const double Every = 8;
    public const string NotOnNetwork = "This machine is not on your private network. Give the Tailscale key of your fleet.";
    public const string NotApproved = "The link was not approved in time.";
    public const string NotStarted = "Tailscale did not start on this server.";

    internal static StepAction Action(string install, IReadOnlyList<string> tags)
    {
        var tagged = tags.Count == 0 ? "" : "--advertise-tags=" + string.Join(",", tags) + " ";
        var up = $"tailscale up {tagged}--accept-dns=false --timeout={WaitMinutes}m";
        var start = install + InstallPlan.TailscaleThere + $"umask 077; rm -f {Log}; tailscale status >/dev/null 2>&1 && exit 0; " +
                    $"setsid sh -c '{up}; echo {EndMark} $?' > {Log} 2>&1 < /dev/null &";
        var check = $"echo {NameMark}$(hostname); tailscale status --json 2>/dev/null | grep -q '\"BackendState\": \"Running\"' && " +
                    $"{{ echo {OnMark}; tailscale ip -4; rm -f {Log}; exit 0; }}; cat {Log} 2>/dev/null; true";
        return new StepAction.SignIn(start, check, Every, Within);
    }

    /// <summary>The <c>--advertise-tags</c> of the hub's join line, each one a tag this app would write itself; else none.</summary>
    public static IReadOnlyList<string> Tags(string line)
    {
        var found = TagsWord().Match(line);
        if (!found.Success) return [];
        var tags = found.Value["--advertise-tags=".Length..].Split(',');
        return tags.All(t => Tag().IsMatch(t)) ? tags : [];
    }

    /// <summary>What one read of the step found.</summary>
    internal abstract record Reading
    {
        private Reading() { }
        internal sealed record On : Reading;
        internal sealed record Ended(string Says) : Reading;
        internal sealed record Waiting(NetworkSignIn? Link) : Reading;
    }

    internal static Reading Read(IReadOnlyList<string> lines)
    {
        if (lines.Contains(OnMark)) return new Reading.On();
        var end = lines.FirstOrDefault(l => l.StartsWith(EndMark, StringComparison.Ordinal));
        if (end is not null)
        {
            if (end == EndMark + " 0") return new Reading.Waiting(null);
            var said = lines.Select(l => l.ToLowerInvariant()).ToList();
            if (said.Any(l => l.StartsWith("timeout waiting for tailscale", StringComparison.Ordinal))) return new Reading.Ended(NotApproved);
            var refused = said.Any(l => l.Contains("requested tags", StringComparison.Ordinal));
            return new Reading.Ended(refused ? NotOnNetwork : NotStarted);
        }
        return new Reading.Waiting(Found(lines));
    }

    /// <summary>The link in these lines: only Tailscale's own sign-in page.</summary>
    public static NetworkSignIn? Found(IReadOnlyList<string> lines)
    {
        var link = lines.LastOrDefault(l => SignInLink().IsMatch(l));
        if (link is null || !Uri.TryCreate(link, UriKind.Absolute, out var url)) return null;
        var name = lines.FirstOrDefault(l => l.StartsWith(NameMark, StringComparison.Ordinal))?[NameMark.Length..];
        return new NetworkSignIn(url, name is not null && ServerName().IsMatch(name) ? name : null);
    }

    [GeneratedRegex(@"--advertise-tags=[^ ;&|]+", RegexOptions.CultureInvariant)]
    private static partial Regex TagsWord();

    [GeneratedRegex(@"\Atag:[a-z0-9][a-z0-9-]{0,62}\z", RegexOptions.CultureInvariant)]
    private static partial Regex Tag();

    [GeneratedRegex(@"\Ahttps://login\.tailscale\.com/a/[0-9a-zA-Z]{6,64}\z", RegexOptions.CultureInvariant)]
    private static partial Regex SignInLink();

    /// <summary>A server's name in Founderizer (the Mac's Servers.namePattern).</summary>
    [GeneratedRegex(@"\A[a-z][a-z0-9-]{1,30}\z", RegexOptions.CultureInvariant)]
    private static partial Regex ServerName();
}
