using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Threading.Tasks;
using Founderizer.Core;
using Founderizer.Owner.Reads;
using Founderizer.Setup.Install;

namespace Founderizer.Setup.RootJobs;

/// <summary>One agent of the fleet, for the browser parts: its name and its boxes (<c>can</c>).</summary>
public sealed record BrowserAgent(string Name, IReadOnlyList<string> Can)
{
    public static BrowserAgent Of(MobileAgent agent) => new(agent.Name, agent.Can ?? []);
}

/// <summary>One task of the fleet, for the browser parts: its agent, its state, and whether it does work now (null from a
/// hub that does not say).</summary>
public sealed record BrowserTask(string Owner, string State, bool? Works)
{
    public static BrowserTask Of(MobileTaskHead task) => new(task.Owner, task.State, task.Works);
}

/// <summary>**One agent's two ports** (a line of <c>/etc/fleet-browser/ports</c>).</summary>
public sealed record BrowserPorts(string User, long Devtools, long Screen);

/// <summary>**Whom each agent of a server runs as** (owner API 1.224), as its service read it: by the agent's name, its OS
/// user and that user's uid, each null for an agent whose user is not made yet. A value that does not read is none.</summary>
public sealed record AgentUsers(IReadOnlyDictionary<string, AgentUsers.Entry> Users)
{
    public sealed record Entry(string? User, long? Uid);

    /// <summary>The value of a reading's <c>agents</c>: null for a reading with none.</summary>
    public static AgentUsers? Read(JsonElement? value)
    {
        if (value is not { } given || given.ValueKind is JsonValueKind.Null or JsonValueKind.Undefined) return null;
        var users = new Dictionary<string, Entry>(StringComparer.Ordinal);
        if (given.ValueKind == JsonValueKind.Object)
            foreach (var member in given.EnumerateObject())
                users[member.Name] = new Entry(BrowserParts.Text(RootServer.Member(member.Value, "user")),
                                               BrowserParts.Whole(RootServer.Member(member.Value, "uid")));
        return new AgentUsers(users);
    }
}

/// <summary>**A Linux server's browser parts, as its service read them** (<c>lifecycle.browser_reading</c>, owner API 1.224;
/// the Mac's ServerBrowserReading): its state (<c>ready</c>, <c>missing</c>, <c>table_missing</c> or <c>unsupported</c>),
/// the packages that are missing, the SHA-256 of each file of the parts that is there, the word of the table's unit, the
/// agents' ports, whether the step keeps a record of what it added, the uids of the broker and of the worker user, and
/// whether the service could keep the live proof for the agents' helpers. A field that does not read is none.</summary>
public sealed record BrowserParts(
    string? State, IReadOnlyList<string> Missing, IReadOnlyDictionary<string, string> Files, string? Unit,
    IReadOnlyList<BrowserPorts>? Ports, bool Added, long? Broker, long? Worker, bool? ProofKept)
{
    /// <summary>The value of a reading's <c>browser</c>: null for a reading with none.</summary>
    public static BrowserParts? Read(JsonElement? value)
    {
        if (value is not { } given || given.ValueKind is JsonValueKind.Null or JsonValueKind.Undefined) return null;
        JsonElement? Member(string name) => RootServer.Member(given, name);
        return new BrowserParts(
            Text(Member("state")), Strings(Member("missing")) ?? [], FilesOf(Member("files")), Text(Member("unit")),
            PortsOf(Member("ports")), Flag(Member("added")) == true, Whole(Member("broker")), Whole(Member("worker")),
            Flag(Member("proof_kept")));
    }

    internal static string? Text(JsonElement? value) => value is { ValueKind: JsonValueKind.String } text ? text.GetString() : null;

    /// <summary>A whole number, as the Mac's <c>Int</c> reads it (64 bits): a port or a uid that a smaller number would
    /// wrap or refuse reads as it is, and the rules that hold it to its range see it.</summary>
    internal static long? Whole(JsonElement? value) =>
        value is { ValueKind: JsonValueKind.Number } number && number.TryGetInt64(out var whole) ? whole : null;

    private static bool? Flag(JsonElement? value) =>
        value is { ValueKind: JsonValueKind.True or JsonValueKind.False } flag ? flag.GetBoolean() : null;

    private static IReadOnlyList<string>? Strings(JsonElement? value)
    {
        if (value is not { ValueKind: JsonValueKind.Array } list) return null;
        var all = new List<string>();
        foreach (var item in list.EnumerateArray())
        {
            if (item.ValueKind != JsonValueKind.String) return null;
            all.Add(item.GetString()!);
        }
        return all;
    }

    /// <summary>The Mac's <c>[String: String?]</c>, without the nulls: a value that is neither text nor null costs all of
    /// them.</summary>
    private static Dictionary<string, string> FilesOf(JsonElement? value)
    {
        var none = new Dictionary<string, string>(StringComparer.Ordinal);
        if (value is not { ValueKind: JsonValueKind.Object } map) return none;
        var all = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var member in map.EnumerateObject())
        {
            if (member.Value.ValueKind == JsonValueKind.Null) continue;
            if (member.Value.ValueKind != JsonValueKind.String) return none;
            all[member.Name] = member.Value.GetString()!;
        }
        return all;
    }

    /// <summary>The Mac's <c>[ServerBrowser.Ports]</c>, whose read fails as a whole: null then.</summary>
    private static IReadOnlyList<BrowserPorts>? PortsOf(JsonElement? value)
    {
        if (value is not { ValueKind: JsonValueKind.Array } list) return null;
        var all = new List<BrowserPorts>();
        foreach (var item in list.EnumerateArray())
        {
            if (Text(RootServer.Member(item, "user")) is not { } user || Whole(RootServer.Member(item, "devtools")) is not { } devtools ||
                Whole(RootServer.Member(item, "screen")) is not { } screen) return null;
            all.Add(new BrowserPorts(user, devtools, screen));
        }
        return all;
    }
}

/// <summary>**The parts as the wanted agents need them** (the Mac's Want): their ports, the table of those ports, the users
/// and their uids that the table was made from, the broker's uid, and the worker user, whose live proof gets a folder of
/// its own.</summary>
public sealed record BrowserWant(IReadOnlyList<BrowserPorts> Rows, string Table, IReadOnlyDictionary<string, long> Uids, long? Broker,
                                 string Worker, long WorkerId)
{
    /// <summary>What the count of tries is of: the same want keeps its count.</summary>
    public string Digest
    {
        get
        {
            var users = string.Join(",", Rows.Select(r => $"{r.User} {Number(Uids.TryGetValue(r.User, out var uid) ? uid : -1)}"));
            var text = string.Join('\u0001', Browser.PortsText(Rows), Table, Browser.PolicyText, users,
                                   Broker is { } broker ? Number(broker) : "-", Worker, Number(WorkerId));
            return Browser.Hash(text)[..16];
        }
    }

    internal static string Number(long value) => value.ToString(CultureInfo.InvariantCulture);
}

/// <summary>What the parts of one server need now (the Mac's Work).</summary>
public abstract record BrowserWork
{
    private BrowserWork() { }

    /// <summary>They are as they should be: no agent wants them and none is there, or they are all in place.</summary>
    public sealed record Nothing : BrowserWork;
    public sealed record Install(BrowserWant Want) : BrowserWork;
    public sealed record Remove : BrowserWork;

    /// <summary>What the count of tries is of; null for nothing to do.</summary>
    public string? Digest => this switch
    {
        Install install => install.Want.Digest,
        Remove => "remove",
        _ => null,
    };
}

/// <summary>What the owner's computer keeps of one server's browser parts between two starts of the app: the want that its
/// tries are of, and the tries (the Mac's Memory).</summary>
public sealed record BrowserMemory(string Digest = "", int Failures = 0, double Last = 0, string Reason = "")
{
    public JobTries? Tries => Failures == 0 ? null : new JobTries(Failures, Last, Reason);

    /// <summary>One more start of a step, or a run that started none.</summary>
    public BrowserMemory Tried(double now, string reason)
    {
        var next = JobTries.Failed(Tries, now, reason);
        return this with { Failures = next.Failures, Last = next.Last, Reason = next.Reason };
    }
}

/// <summary>What one run of the browser program came to (the Mac's Outcome).</summary>
public abstract record BrowserOutcome
{
    private BrowserOutcome() { }

    /// <summary>A step started now; what the one before it said ("" for none).</summary>
    public sealed record StepStarted(string Last) : BrowserOutcome;
    /// <summary>A step still runs: nothing started.</summary>
    public sealed record StepRuns(string Last) : BrowserOutcome;
    /// <summary>The program ran and started no step, with the words for the log.</summary>
    public sealed record Failed(string Said) : BrowserOutcome;
    /// <summary>The output reads as a program that did not start: nothing ran on the server.</summary>
    public sealed record NotStarted(string Said) : BrowserOutcome;
}

/// <summary>One round's turn of the browser parts of a server, with what the owner's computer keeps of them after it and
/// this start's tries that ran nothing there.</summary>
public sealed record BrowserTurn(JobTurn Turn, BrowserMemory Memory, JobTries? Unreached);

/// <summary>**The agents' browser parts on a Linux server, put in place and taken away by the owner's computer** (the Mac's
/// ServerBrowser; the owner's "Every agent with shell" of 17 November 2026). An agent with the Browser box on a Linux worker
/// gets a Chrome of its own there; its parts need root: Google's Chrome with its APT source and key, Xvfb, Openbox, x11vnc,
/// nftables, the fonts, Chrome's policies, the agents' ports and the fleet's own nftables table that guards them. They come
/// and go from the owner's computer by themselves, over the root connection that it has to each server, with a log line
/// only: in a server that joined, with a current reading of its own service, no open job, no task that works, and not in the
/// hour after its join; installed where an agent wants them and a part differs, and taken away where none does. Each program
/// is this app's own and changes only what differs; <c>remote-root.json</c> holds it byte for byte.</summary>
public static partial class Browser
{
    // ------------------------------------------------------------ the contract (devops's scripts/fleet-browser)

    public const string UnitPath = "/etc/systemd/system/fleet-browser-ports.service";
    public const string DropinFolder = "/etc/systemd/system/nftables.service.d";
    public const string DropinPath = DropinFolder + "/fleet-browser.conf";
    public const string DefaultPath = "/etc/default/google-chrome";
    public const string OriginPath = "/etc/apt/apt.conf.d/53fleet-google-chrome";
    public const string StageFolder = "/etc/opt/chrome/policies";
    public const string PoliciesFolder = StageFolder + "/managed";
    public const string FixedPath = PoliciesFolder + "/fleet-fixed.json";
    public const string PolicyPath = PoliciesFolder + "/fleet-providers.json";
    public const string PortsFolder = "/etc/fleet-browser";
    public const string PortsPath = PortsFolder + "/ports";
    public const string TablePath = PortsFolder + "/table.nft";
    public const string SourcePath = "/etc/apt/sources.list.d/google-chrome.sources";
    public const string KeyPath = "/usr/share/keyrings/google-chrome.gpg";
    /// <summary>The lock that the step and the root helper's removal of an agent take before they change the ports file and
    /// the table.</summary>
    public const string LockPath = PortsFolder + "/lock";

    /// <summary>What the server's reading names each of them (<c>lifecycle.BROWSER_PARTS</c>).</summary>
    public static readonly IReadOnlyDictionary<string, string> Parts = new Dictionary<string, string>(StringComparer.Ordinal)
    {
        ["unit"] = UnitPath, ["dropin"] = DropinPath, ["default"] = DefaultPath, ["origin"] = OriginPath, ["fixed"] = FixedPath,
        ["policy"] = PolicyPath, ["ports"] = PortsPath, ["table"] = TablePath, ["source"] = SourcePath, ["key"] = KeyPath,
    };

    /// <summary><c>lifecycle.BROWSER_PACKAGES</c>.</summary>
    public static readonly IReadOnlyList<string> Packages =
        ["google-chrome-stable", "xvfb", "xauth", "openbox", "x11vnc", "ffmpeg", "nftables", "fonts-noto-core",
         "fonts-noto-color-emoji", "libatomic1"];

    /// <summary>Installed, and never recorded as added, so that no removal takes them away.</summary>
    internal static readonly IReadOnlyList<string> KeptPackages = ["libatomic1", "nftables"];
    internal const string Broker = "fleet-vault";

    /// <summary>The providers' own sign-in sites, and the key sites under them that stay allowed: a copy of the Mac's
    /// ProviderSites (a copy of <c>vault.py</c>), which <c>remote-root.json</c> holds. The policy blocks each host of the
    /// first list, and opens the second.</summary>
    internal static readonly IReadOnlyList<string> Sites = ["claude.ai", "claude.com", "chatgpt.com", "auth.openai.com", "x.ai"];
    internal static readonly IReadOnlyList<string> KeySites = ["platform.claude.com", "api.x.ai"];

    internal const string TableComment = "# Founderizer writes this table whole from /etc/fleet-browser/ports (plan 04, D11).";
    internal const int DevtoolsFirst = 9300, DevtoolsLast = 9399, ScreenFirst = 5910, ScreenLast = 5999;

    /// <summary>The table's unit (devops's <c>fleet-browser-ports.service</c>).</summary>
    public const string UnitText = "[Unit]\n"
        + "Description=Founderizer browser ports: the fleet's own nftables table for the agents' browser ports\n"
        + "After=nftables.service\n"
        + "ReloadPropagatedFrom=nftables.service\n"
        + "\n"
        + "[Service]\n"
        + "Type=oneshot\n"
        + "RemainAfterExit=yes\n"
        + "ExecStart=/usr/sbin/nft -f /etc/fleet-browser/table.nft\n"
        + "ExecReload=/usr/sbin/nft -f /etc/fleet-browser/table.nft\n"
        + "ExecStop=-/usr/sbin/nft delete table inet fleet_browser\n"
        + "\n"
        + "[Install]\n"
        + "WantedBy=multi-user.target nftables.service\n";

    /// <summary>The table again after each start, reload and stop of <c>nftables.service</c> (devops's
    /// <c>fleet-browser.conf</c>).</summary>
    public const string DropinText = "# Founderizer's browser parts: each start, reload and stop of nftables.service flushes the whole ruleset, so\n"
        + "# the fleet's own table of the agents' browser ports is loaded again after each of them (plan 04, D11).\n"
        + "[Service]\n"
        + "ExecStartPost=-/usr/sbin/nft -f /etc/fleet-browser/table.nft\n"
        + "ExecReload=-/usr/sbin/nft -f /etc/fleet-browser/table.nft\n"
        + "ExecStopPost=-/usr/sbin/nft -f /etc/fleet-browser/table.nft\n";

    /// <summary>Chrome's daily job adds no source of its own (devops's <c>google-chrome.default</c>).</summary>
    public const string DefaultText = "repo_add_once=\"false\"\nrepo_reenable_on_distupgrade=\"false\"\n";

    /// <summary>Unattended upgrades take Chrome's updates (devops's <c>53fleet-google-chrome</c>).</summary>
    public const string OriginText = "// Founderizer's browser parts, written and removed with them by the owner's Mac:\n"
        + "// unattended upgrades take Google Chrome's updates too.\n"
        + "Unattended-Upgrade::Origins-Pattern {\n"
        + "        \"origin=Google LLC,codename=stable,label=Google\";\n"
        + "};\n";

    /// <summary>The fixed Chrome policy (devops's <c>fleet-fixed.json</c>).</summary>
    public const string FixedText = "{\"RestoreOnStartup\": 1, \"PasswordManagerEnabled\": false, \"BrowserSignin\": 0, "
        + "\"SyncDisabled\": true, \"DiskCacheSize\": 104857600}\n";

    /// <summary>Chrome's package's own APT source (devops's <c>contract/google-chrome.sources</c>).</summary>
    public const string SourceText = "### THIS FILE IS AUTOMATICALLY CONFIGURED ###\n"
        + "# Changes to this file will not be preserved.\n"
        + "# This file will not be recreated if removed.\n"
        + "X-Repolib-Name: Google Chrome\n"
        + "Types: deb\n"
        + "URIs: https://dl.google.com/linux/chrome-stable/deb/\n"
        + "Suites: stable\n"
        + "Components: main\n"
        + "Architectures: amd64\n"
        + "Signed-By: /usr/share/keyrings/google-chrome.gpg\n";

    /// <summary>**Google's signing key, the pinned primary key alone with its subkeys**, as base64: <c>gpg --export</c> of
    /// <c>EB4C 1BFD 4F04 2F6D DDCC EC91 7721 F63B D38B 4796</c> from Google's published file of 17 November 2026. The step
    /// writes it only where no key is there.</summary>
    internal const string KeyData = "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"
        + "a2N+cNFSkXzUmw0Rj/iUmZcSITcM8QOSK6U=";

    /// <summary>**The policy from this app's own lists**: no agent opens a file of its server, Chrome's password manager or
    /// a provider's sign-in, and the providers' consoles stay open.</summary>
    public static string PolicyText
    {
        get
        {
            static string List(IEnumerable<string> items) => "[" + string.Join(", ", items.Select(i => $"\"{i}\"")) + "]";
            return "{\"URLBlocklist\": " + List(new[] { "file://*", "chrome://password-manager" }.Concat(Sites)) + ", \"URLAllowlist\": "
                   + List(KeySites) + "}\n";
        }
    }

    // ------------------------------------------------------------ the ports and the table

    /// <summary>The table of no line, its last rule alone: every port of both ranges closed (the removal's first step).</summary>
    internal static string EmptyTable => Table([], new Dictionary<string, long>(), null, 0)!;

    /// <summary>The ports file of these rows.</summary>
    public static string PortsText(IEnumerable<BrowserPorts> rows) =>
        string.Concat(rows.Select(r => $"{r.User} {BrowserWant.Number(r.Devtools)} {BrowserWant.Number(r.Screen)}\n"));

    /// <summary>**The table of these rows**, byte for byte as the contract gives it: each rule holds only for a packet to
    /// this server itself, each DevTools port refuses every user but root, the broker and the agent, each screen-sharing port
    /// every user but root and the worker user, a packet from either port whose socket is not the agent's is dropped, and
    /// the last rule refuses each new connection to every other port of both ranges. Null where a row's user has no
    /// uid, and where a row's DevTools port is not of 9300 to 9399 or its screen port not of 5910 to 5999: <see cref="Assign"/>
    /// keeps no such row, and this second guard makes sure that no caller makes a rule for another port of the server
    /// (port 22, say).</summary>
    public static string? Table(IReadOnlyList<BrowserPorts> rows, IReadOnlyDictionary<string, long> uids, long? broker, long worker)
    {
        var lines = new List<string> { TableComment, "table inet fleet_browser", "delete table inet fleet_browser",
                                       "table inet fleet_browser {", "\tchain out {", "\t\ttype filter hook output priority 0; policy accept;" };
        static string N(long value) => BrowserWant.Number(value);
        foreach (var row in rows)
        {
            if (!uids.TryGetValue(row.User, out var uid) || !IsDevtools(row.Devtools) || !IsScreen(row.Screen)) return null;
            var users = new List<long> { 0 };
            if (broker is { } known) users.Add(known);
            users.Add(uid);
            var allowed = string.Join(", ", users.Select(N));
            lines.Add($"\t\toifname \"lo\" tcp dport {N(row.Devtools)} meta skuid != {{ {allowed} }} reject with tcp reset");
            lines.Add($"\t\toifname \"lo\" tcp dport {N(row.Screen)} meta skuid != {{ 0, {N(worker)} }} reject with tcp reset");
            lines.Add($"\t\toifname \"lo\" tcp sport {{ {N(row.Devtools)}, {N(row.Screen)} }} meta skuid != {N(uid)} drop");
            lines.Add($"\t\toifname \"lo\" tcp dport {{ {N(row.Devtools)}, {N(row.Screen)} }} accept");
        }
        lines.Add($"\t\toifname \"lo\" tcp flags & (syn | ack) == syn tcp dport {{ {N(ScreenFirst)}-{N(ScreenLast)}, {N(DevtoolsFirst)}-{N(DevtoolsLast)} }} reject with tcp reset");
        return string.Join("\n", lines.Append("\t}").Append("}")) + "\n";
    }

    /// <summary>**The rows for the wanted users**: each row of a user that is still wanted keeps its place and its ports, the
    /// rows of the others go, and each new user takes the lowest ports that no row of <paramref name="current"/> holds (so a
    /// port given up now goes to nobody else in the same step). As many new users as there are free ports.
    ///
    /// **<paramref name="current"/> is the server's reading, and the hub relays it** (the Mac's rule of 24 November 2026),
    /// so a broken-in hub can say any number there. A row of it whose DevTools port is not of 9300 to 9399, whose screen
    /// port is not of 5910 to 5999, or whose user, or one of whose ports, an earlier row has, is no row: it keeps no place
    /// and holds no port, and its user takes free ports as a new user does. Without it a reading of port 22 for an agent
    /// makes the step write the table's rules for port 22.</summary>
    public static IReadOnlyList<BrowserPorts> Assign(IReadOnlyList<BrowserPorts> current, IReadOnlyList<string> wanted)
    {
        var want = new HashSet<string>(wanted, StringComparer.Ordinal);
        var held = new List<BrowserPorts>();
        var devtools = new HashSet<long>();
        var screens = new HashSet<long>();
        var users = new HashSet<string>(StringComparer.Ordinal);
        foreach (var row in current)
        {
            if (!IsDevtools(row.Devtools) || !IsScreen(row.Screen) || devtools.Contains(row.Devtools) || screens.Contains(row.Screen)
                || users.Contains(row.User)) continue;
            held.Add(row);
            devtools.Add(row.Devtools);
            screens.Add(row.Screen);
            users.Add(row.User);
        }
        var rows = held.Where(r => want.Contains(r.User)).ToList();
        foreach (var user in wanted.Where(u => rows.All(r => r.User != u)))
        {
            var next = Enumerable.Range(DevtoolsFirst, DevtoolsLast - DevtoolsFirst + 1).Where(p => !devtools.Contains(p)).Cast<int?>().FirstOrDefault();
            var screen = Enumerable.Range(ScreenFirst, ScreenLast - ScreenFirst + 1).Where(p => !screens.Contains(p)).Cast<int?>().FirstOrDefault();
            if (next is not { } n || screen is not { } s) break;
            rows.Add(new BrowserPorts(user, n, s));
            devtools.Add(n);
            screens.Add(s);
        }
        return rows;
    }

    /// <summary>A DevTools port of the agents' range (the Mac's <c>devtoolsPorts</c>).</summary>
    internal static bool IsDevtools(long port) => port is >= DevtoolsFirst and <= DevtoolsLast;

    /// <summary>A screen port of the agents' range (the Mac's <c>screenPorts</c>).</summary>
    internal static bool IsScreen(long port) => port is >= ScreenFirst and <= ScreenLast;

    /// <summary>The user of the service of every Linux server of this sweep (<c>join.sh</c>'s WORKER).</summary>
    internal const string ServiceUser = "fleet";

    /// <summary>**Whether the worker user of a reading may have the screen ports' rule and the live proof's folder** (the
    /// Mac's <c>workerFits</c>, 24 November 2026). The hub relays the reading, which names the worker user and its uid; the
    /// table lets that uid open every agent's screen port, and the step gives it the live proof's folder. Every Linux server
    /// of this sweep runs its service as <see cref="ServiceUser"/>, so the name must be that one: not a cloud image's login
    /// user, an admin's account or another program's user, and no agent's or the broker's. Its uid may be any but 0, the
    /// broker's and the uid of a <c>fleet-</c> user of the reading. The step checks the same again on the server, from its
    /// own users, before anything else and again under its lock (<c>worker-refused</c>).</summary>
    public static bool WorkerFits(string user, long uid, IReadOnlyDictionary<string, long> uids, long? broker) =>
        user == ServiceUser && uid != 0 && uid != broker
        && !uids.Any(u => u.Key.StartsWith("fleet-", StringComparison.Ordinal) && u.Value == uid);

    // ------------------------------------------------------------ when

    /// <summary>The SHA-256 of a text in lower-case hex, as the server's reading gives a file's.</summary>
    internal static string Hash(string text) => Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(text)));

    [GeneratedRegex(@"\Afleet-[a-z][a-z0-9-]{1,25}\z", RegexOptions.CultureInvariant)]
    private static partial Regex AgentUser();

    /// <summary>**The OS users of the agents on this server that want a browser**, in the order of the server's agents: the
    /// Browser box and the Shell box on, and a user of its own there, which is neither the server service's user nor the
    /// vault broker's. An agent whose user is not made yet is not among them. **Null where the reading does not name such
    /// an agent at all**: then the round does nothing, and never takes the parts or an agent's ports away for an agent that
    /// it cannot see.</summary>
    public static IReadOnlyList<string>? Wanted(ServerEntry server, AgentUsers? agentUsers, IReadOnlyList<BrowserAgent> agents)
    {
        if (server.Reading is not { } reading || agentUsers is not { Users: var users }) return null;
        var byName = new Dictionary<string, BrowserAgent>(StringComparer.Ordinal);
        foreach (var agent in agents) byName.TryAdd(agent.Name, agent);
        var found = new List<string>();
        foreach (var name in server.Agents)
        {
            if (!byName.TryGetValue(name, out var agent) || !agent.Can.Contains("browser") || !agent.Can.Contains("shell")) continue;
            if (!users.TryGetValue(name, out var entry)) return null;
            if (entry.User is not { } user || user == reading.User || user == Broker || found.Contains(user) || !AgentUser().IsMatch(user))
                continue;
            found.Add(user);
        }
        return found;
    }

    /// <summary>**What one round does with one server**, or null where the round says nothing: not a server of this sweep
    /// (a Mac, the hub's own server, a server that did not join), an open job of its service, the hour after its join, a
    /// reading that is not current or not its service's own, a reading without the parts, a task that makes the step wait,
    /// or a want whose users the reading does not name. A task in state working makes the step wait unless its
    /// <c>works</c> is false.</summary>
    public static BrowserWork? WorkFor(RootServer row, IReadOnlyList<BrowserAgent> agents, IReadOnlyList<BrowserTask> tasks,
                                       JoinState? join, double time)
    {
        var server = row.Entry;
        if (server is not { Kind: "linux", Joined: true, Hub: false } || server.Job?.IsOpen == true) return null;
        if (join is not null && join.Server == server.Name && time - join.Created < RootJob.JoinGrace) return null;
        if (server.Reading is not { Source: "server" } reading || !reading.IsCurrent(time)) return null;
        if (row.Browser is not { } parts || parts.State is not { } state) return null;
        if (state == "unsupported") return new BrowserWork.Nothing();
        var here = new HashSet<string>(server.Agents, StringComparer.Ordinal);
        if (tasks.Any(t => here.Contains(t.Owner) && t.State == "working" && t.Works != false)) return null;
        if (Wanted(server, row.Users, agents) is not { } wanted) return null;
        if (wanted.Count == 0)
        {
            // Chrome's own files (its source, its key, /etc/default/google-chrome) are not among these: where Chrome stays
            // after a removal, they stay with it.
            var ours = new[] { "unit", "dropin", "origin", "fixed", "policy", "ports", "table" }.Any(parts.Files.ContainsKey);
            return parts.Added || ours || parts.Ports is { Count: > 0 } ? new BrowserWork.Remove() : new BrowserWork.Nothing();
        }
        var uids = new Dictionary<string, long>(StringComparer.Ordinal);
        if (row.Users is { } known)
            foreach (var entry in known.Users.Values)
                if (entry is { User: { } user, Uid: { } uid }) uids[user] = uid;
        var rows = Assign(parts.Ports ?? [], wanted);
        if (reading.User is not { } worker || parts.Worker is not { } workerId || !WorkerFits(worker, workerId, uids, parts.Broker) ||
            Table(rows, uids, parts.Broker, workerId) is not { } table) return null;
        var want = new BrowserWant(rows, table, uids.Where(u => rows.Any(r => r.User == u.Key)).ToDictionary(StringComparer.Ordinal),
                                   parts.Broker, worker, workerId);
        var expected = new Dictionary<string, string>(StringComparer.Ordinal)
        {
            ["unit"] = Hash(UnitText), ["dropin"] = Hash(DropinText), ["default"] = Hash(DefaultText), ["origin"] = Hash(OriginText),
            ["fixed"] = Hash(FixedText), ["policy"] = Hash(PolicyText), ["ports"] = Hash(PortsText(rows)), ["table"] = Hash(table),
        };
        var inPlace = state == "ready" && parts.Missing.Count == 0 && parts.Unit == "active"
                      && expected.All(e => parts.Files.TryGetValue(e.Key, out var there) && there == e.Value)
                      && parts.Files.ContainsKey("source") && parts.Files.ContainsKey("key") && parts.ProofKept != false;
        return inPlace ? new BrowserWork.Nothing() : new BrowserWork.Install(want);
    }

    // ------------------------------------------------------------ how often

    /// <summary>**One round's work for one server.** The same want in two rounds in a row runs the program; each start is a
    /// try, ten minutes apart and six at most for one want; a step that still runs is no try. A new want starts the count
    /// again, and a reading that matches the want ends it. A try that ran nothing on the server is never in the kept
    /// count (as in <see cref="RootJob.TurnAsync"/>).</summary>
    public static async Task<BrowserTurn> TurnAsync(BrowserWork? work, BrowserMemory memory, JobTries? unreached, bool seenBefore,
                                                    double now, Func<Task<InstallTarget>> connection,
                                                    Func<InstallTarget, string, Task<string>> run)
    {
        if (work is null) return new BrowserTurn(JobTurn.None, memory, unreached);
        if (work.Digest is not { } digest)
            return new BrowserTurn(JobTurn.None, new BrowserMemory(), unreached);
        if (memory.Digest != digest) memory = new BrowserMemory(digest);
        if (!seenBefore) return new BrowserTurn(JobTurn.SeenOnly, memory, unreached);
        if (unreached is { } held && !held.IsDue(now) || memory.Tries is { } kept && !kept.IsDue(now))
            return new BrowserTurn(JobTurn.SeenOnly, memory, unreached);
        var lines = new List<string>();
        string? nothingRan = null;
        try
        {
            var output = await run(await connection().ConfigureAwait(false), Program(work)).ConfigureAwait(false);
            switch (Outcome(output))
            {
                case BrowserOutcome.StepStarted started:
                    memory = memory.Tried(now, started.Last.Length == 0 ? "started" : "the step before said: " + started.Last);
                    lines.Add($"a step to {(work is BrowserWork.Remove ? "remove" : "put in place")} the parts started"
                              + (started.Last.Length == 0 ? "" : "; the step before it said: " + started.Last));
                    break;
                case BrowserOutcome.StepRuns runs:
                    lines.Add("a step still runs" + (runs.Last.Length == 0 ? "" : $" ({runs.Last})"));
                    break;
                case BrowserOutcome.Failed failed:
                    memory = memory.Tried(now, failed.Said);
                    lines.Add("no step started: " + failed.Said);
                    break;
                case BrowserOutcome.NotStarted missed:
                    nothingRan = missed.Said;
                    break;
            }
        }
        catch (Exception e) when (e is not OutOfMemoryException)
        {
            nothingRan = RootJob.Describe(e);
        }
        if (nothingRan is not null)
        {
            var tries = JobTries.Failed(unreached, now, nothingRan);
            unreached = tries;
            if (tries.GivenUp)
                lines.Add($"nothing ran there in {tries.Failures} tries ({tries.Reason}): left until this app starts again");
        }
        else if (memory.Tries?.GivenUp == true)
        {
            lines.Add($"left after {memory.Failures} tries ({memory.Reason}) until the want changes");
        }
        return new BrowserTurn(new JobTurn(true, lines), memory, unreached);
    }

    // ------------------------------------------------------------ what

    internal const string Mark = "founderizer-browser";
    /// <summary>The program's first line (<see cref="Hardening.Started"/> says why it has one).</summary>
    public const string Started = "founderizer-browser-started";
    /// <summary>The transient unit of the step, its limits, and the step's folder.</summary>
    internal const string StepUnit = "fleet-browser-step";
    internal static readonly IReadOnlyList<string> StepLimits = ["MemoryMax=768M", "Nice=10", "IOSchedulingClass=idle", "RuntimeMaxSec=3600"];
    internal const string Folder = "/var/lib/fleet-browser";
    private const string StepPath = "/usr/sbin:/usr/bin:/sbin:/bin";

    /// <summary>**The program, as root on the server** (the Mac's, byte for byte): its first line, what the step before it
    /// said, and then, unless a step still runs, the step (<see cref="Step"/>) written as root's own file and started in its
    /// transient unit. It waits for nothing: the next round reads the reading, and the next run what the step said.</summary>
    public static string Program(BrowserWork work)
    {
        var r = InstallPlan.Quote("");
        var limits = string.Join(" ", StepLimits.Select(l => "-p " + l));
        var step = InstallPlan.Quote(Step(work));
        return $"printf '\\n%s\\n' {Started} || exit 1\n"
        + $"umask 022\n"
        + $"r={r}; d=\"$r{Folder}\"; s=\"$d/step\"; n=\n"
        + $"l=$(head -n 1 \"$d/result\" 2>/dev/null | tr -cd 'a-z0-9 -')\n"
        + $"if systemctl is-active --quiet {StepUnit}.service 2>/dev/null; then echo \"{Mark} running $l\"; exit 0; fi\n"
        + $"case \"$l\" in *' running') l=\"${{l% running}} stopped\";; esac\n"
        + $"if mkdir -p \"$s\" && chmod 755 \"$d\" && chmod 700 \"$s\" && n=$(mktemp \"$s/.run-XXXXXX\") && printf '%s' {step} > \"$n\" && mv -f \"$n\" \"$s/run.sh\"; then\n"
        + $"  if o=$(systemd-run --quiet --collect --no-block --unit={StepUnit} {limits} /bin/sh \"$s/run.sh\" 2>&1); then\n"
        + $"    echo \"{Mark} started $l\"\n"
        + $"  else printf '%s\\n' \"$o\" | tail -n 2; echo \"{Mark} failed $l\"\n"
        + $"  fi\n"
        + $"else [ -z \"$n\" ] || rm -f \"$n\"; echo \"{Mark} failed $l\"\n"
        + $"fi";
    }

    /// <summary>**The step, in its transient unit as root** (the Mac's <c>step</c>): it says <c>running</c> first, and at its
    /// end one word. Install and Remove in the contract's order, as the Mac's documentation gives it; each file is written
    /// whole and moved into place, and a file that holds the text already is left as it is. **The ports and the table are
    /// checked on the server first** (<c>fits</c>, the Mac's rule of 24 November 2026), as a second guard beside
    /// <see cref="Assign"/> and <see cref="Table"/>: each line of the ports text must be an agent's user with a DevTools port
    /// of 9300 to 9399 and a screen port of 5910 to 5999, each once, and each port that the table names must lie in those
    /// ranges, else <c>ports-refused</c> and nothing changes. An install then holds the worker user to
    /// <see cref="WorkerFits"/> from the server's own users, before anything else and again under the lock
    /// (<c>worker-refused</c>).</summary>
    internal static string Step(BrowserWork work)
    {
        var path = InstallPlan.Quote(StepPath);
        var r = InstallPlan.Quote("");
        var list = string.Join(" ", Packages);
        var keptList = string.Join(" ", KeptPackages);
        var digest = InstallPlan.Quote(work.Digest ?? "-");
        var head = $"set -u\n"
            + $"umask 022\n"
            + $"PATH={path}; export PATH; DEBIAN_FRONTEND=noninteractive; export DEBIAN_FRONTEND; LC_ALL=C; export LC_ALL\n"
            + $"r={r}; v={digest}; d=\"$r{Folder}\"; a=\"$d/added\"; s=\"$d/step\"; w=\n"
            + $"say() {{ printf '%s %s\\n' \"$v\" \"$1\" > \"$d/.result\" && mv -f \"$d/.result\" \"$d/result\"; }}\n"
            + $"own() {{ [ \"$(id -u)\" != 0 ] || chown \"${{2:-root:root}}\" \"$1\"; }}\n"
            + $"put() {{\n"
            + $"  p=\"$r$1\"; g=\"${{2:-${{p%/*}}}}\"; shift 2; n=\n"
            + $"  n=$(mktemp \"$g/.fleet-XXXXXX\") && \"$@\" > \"$n\" && chmod 644 \"$n\" || {{ [ -z \"$n\" ] || rm -f \"$n\"; return 1; }}\n"
            + $"  if [ -f \"$p\" ] && [ ! -L \"$p\" ] && cmp -s \"$n\" \"$p\"; then rm -f \"$n\"; chmod 644 \"$p\"; own \"$p\"; return 0; fi\n"
            + $"  own \"$n\"; mv -f \"$n\" \"$p\" || {{ rm -f \"$n\"; return 1; }}\n"
            + $"}}\n"
            + $"text() {{ printf '%s' \"$1\"; }}\n"
            + $"key() {{ printf '%s' \"$1\" | base64 -d; }}\n"
            + $"merge() {{ {{ cat \"$a\" 2>/dev/null; cat \"$1\"; }} | sort -u > \"$a.new\" && chmod 644 \"$a.new\" && own \"$a.new\" && mv -f \"$a.new\" \"$a\"; }}\n"
            + $"note() {{ printf '%s\\n' \"$1\" > \"$s/one\" && merge \"$s/one\"; }}\n"
            + $"pkgs() {{ dpkg-query -W -f='${{Package}}\\t${{Architecture}}\\t${{db:Status-Abbrev}}\\n' \"$@\" 2>/dev/null; }}\n"
            + $"installed() {{ pkgs \"$@\" | awk -F '\\t' '($2 == \"amd64\" || $2 == \"all\") && $3 ~ /^.i/ {{print $1}}' | sort -u; }}\n"
            + $"removable() {{ pkgs \"$@\" | awk -F '\\t' '($2 == \"amd64\" || $2 == \"all\") && $3 ~ /^i[^nc]/ {{print $1}}' | sort -u; }}\n"
            + $"present() {{ pkgs \"$@\" | awk -F '\\t' '($2 == \"amd64\" || $2 == \"all\") && $3 !~ /^.[nc]/ {{print $1}}' | sort -u; }}\n"
            + $"every() {{\n"
            + $"  pkgs > \"$1.all\" && [ -s \"$1.all\" ] && awk -F '\\t' '($2 == \"amd64\" || $2 == \"all\") && $3 !~ /^.[nc]/ {{print $1}}' \"$1.all\" | sort -u > \"$1\" && [ -s \"$1\" ]\n"
            + $"}}\n"
            + $"ag() {{\n"
            + $"  o=$(apt-get -q -o Dpkg::Use-Pty=0 \"$@\" 2>&1) && return 0\n"
            + $"  case \"$o\" in *'Could not get lock'*|*'is another process using it'*) w=apt-busy;; esac\n"
            + $"  return 1\n"
            + $"}}\n"
            + $"gone() {{ apt-get -s \"$@\" 2>/dev/null | awk '$1 == \"Purg\" || $1 == \"Remv\" {{sub(/:.*/, \"\", $2); print $2}}'; }}\n"
            + $"fits() {{\n"
            + $"  printf '%s' \"$1\" | awk -v b={Broker} 'BEGIN {{k = 1}}\n"
            + $"    {{if (NF != 3 || $0 != ($1 \" \" $2 \" \" $3) || $1 !~ /^fleet-[a-z][a-z0-9-]*$/ || length($1) < 8 ||\n"
            + $"    length($1) > 32 || $1 == b || $2 !~ /^93[0-9][0-9]$/ || $3 !~ /^59[1-9][0-9]$/ || ($1 in u) ||\n"
            + $"    ($2 in u) || ($3 in u)) k = 0; u[$1] = 1; u[$2] = 1; u[$3] = 1}}\n"
            + $"    END {{exit !k}}' || return 1\n"
            + $"  printf '%s' \"$2\" | awk 'function one(t, a, n, lo, hi) {{\n"
            + $"      sub(/,$/, \"\", t); n = split(t, a, \"-\")\n"
            + $"      if (n < 1 || n > 2 || a[1] !~ /^[1-9][0-9]*$/ || a[n] !~ /^[1-9][0-9]*$/) return 0\n"
            + $"      lo = a[1] + 0; hi = a[n] + 0\n"
            + $"      return lo <= hi && (lo >= {ScreenFirst} && hi <= {ScreenLast} ||\n"
            + $"        lo >= {DevtoolsFirst} && hi <= {DevtoolsLast})\n"
            + $"    }}\n"
            + $"    BEGIN {{k = 1}}\n"
            + $"    /^#/ {{next}}\n"
            + $"    {{for (i = 1; i <= NF; i++) if ($i ~ /[ds]port/) {{\n"
            + $"      if ($i != \"dport\" && $i != \"sport\") k = 0\n"
            + $"      else if ($(i + 1) != \"{{\") k = k && one($(i + 1))\n"
            + $"      else {{ for (j = i + 2; j <= NF && $j != \"}}\"; j++) k = k && one($j); if (j > NF || j == i + 2) k = 0 }}\n"
            + $"    }}}}\n"
            + $"    END {{exit !k}}'\n"
            + $"}}\n"
            + $"came() {{\n"
            + $"  every \"$s/after\" && {{ for p in $(comm -13 \"$s/before\" \"$s/after\"); do\n"
            + $"    case ' {keptList} ' in *\" $p \"*) continue;; esac\n"
            + $"    echo \"package $p\"\n"
            + $"    case ' {list} ' in *\" $p \"*) echo \"requested $p\";; esac\n"
            + $"  done; }} > \"$s/new\" && merge \"$s/new\" && rm -f \"$s/before\" \"$s/before.all\" \"$s/after\" \"$s/after.all\" \"$s/new\"\n"
            + $"}}\n"
            + $"chmod 755 \"$d\"\n"
            + $"say running\n"
            + $"[ ! -s \"$s/before\" ] || came || {{ say write-failed; exit 0; }}\n";
        switch (work)
        {
            case BrowserWork.Remove:
            {
                var lockPath = "$r" + LockPath;
                var kept = string.Join(" ", KeptPackages.Select(p => "-e " + p));
                var emptyTable = InstallPlan.Quote(EmptyTable);
                return head + $"P=''; T={emptyTable}\n"
            + $"fits \"$P\" \"$T\" || {{ say ports-refused; exit 0; }}\n"
            + $"if [ -f \"{lockPath}\" ]; then\n"
            + $"  command exec 9<\"{lockPath}\" && flock -w 60 9 || {{ say lock-busy; exit 0; }}\n"
            + $"fi\n"
            + $"if [ -f \"$r{PortsPath}\" ] || [ -f \"$r{TablePath}\" ]; then\n"
            + $"  put {PortsPath} \"\" text \"$P\" && put {TablePath} \"\" text \"$T\" || {{ say write-failed; exit 0; }}\n"
            + $"  systemctl reload-or-restart fleet-browser-ports.service >/dev/null 2>&1   || nft -f \"$r{TablePath}\" >/dev/null 2>&1 || {{ say table-failed; exit 0; }}\n"
            + $"fi\n"
            + $"for u in $(getent passwd | awk -F: '$1 ~ /^fleet-[a-z][a-z0-9-]*$/ {{print $1}}'); do\n"
            + $"  systemctl is-active --quiet \"user@$(id -u \"$u\").service\" 2>/dev/null || continue\n"
            + $"  systemctl --user --machine=\"$u@.host\" stop fleet_browser.service fleet_vnc.service >/dev/null 2>&1\n"
            + $"done\n"
            + $"ss -Htln > \"$s/listening\" 2>/dev/null || {{ rm -f \"$s/listening\"; say ss-failed; exit 0; }}\n"
            + $"l=$(awk '{{n = split($4, a, \":\"); p = a[n] + 0}}\n"
            + $"  p >= {ScreenFirst} && p <= {ScreenLast} || p >= {DevtoolsFirst} && p <= {DevtoolsLast} {{print p}}'   \"$s/listening\" | sort -nu | head -n 5 | tr '\n"
            + $"' ' '); rm -f \"$s/listening\"\n"
            + $"[ -z \"$l\" ] || {{ say \"units-running ${{l% }}\"; exit 0; }}\n"
            + $"rm -f \"$r{DropinPath}\"\n"
            + $"rmdir \"$r{DropinFolder}\" 2>/dev/null\n"
            + $"systemctl daemon-reload >/dev/null 2>&1\n"
            + $"systemctl disable --now fleet-browser-ports.service >/dev/null 2>&1\n"
            + $"nft delete table inet fleet_browser >/dev/null 2>&1\n"
            + $"rm -f \"$r{UnitPath}\" \"$r{TablePath}\" \"$r{PortsPath}\" \"$r{OriginPath}\"\n"
            + $"systemctl daemon-reload >/dev/null 2>&1\n"
            + $"# a record from before keptPackages may name one of them: it stays all the same\n"
            + $"q=$(sed -n 's/^requested //p' \"$a\" 2>/dev/null | grep -vxF {kept}); k=$(sed -n 's/^package //p' \"$a\" 2>/dev/null | grep -vxF {kept})\n"
            + $"f=$(sed -n 's/^file //p' \"$a\" 2>/dev/null); e=; c=; y=$([ -z \"$k\" ] || removable $k)\n"
            + $"[ -z \"$q\" ] || for p in $(removable $q); do\n"
            + $"  x=remove; [ \"$p\" != google-chrome-stable ] || x=purge\n"
            + $"  t=; o=1\n"
            + $"  for g in $(gone $x \"$p\"); do [ \"$g\" != \"$p\" ] || t=1; printf '%s\\n' \"$y\" | grep -qxF \"$g\" || o=; done\n"
            + $"  [ -n \"$t\" ] && [ -n \"$o\" ] || continue\n"
            + $"  if [ $x = purge ]; then c=1; else e=\"$e $p\"; fi\n"
            + $"done\n"
            + $"[ -z \"$c\" ] || ag purge -y google-chrome-stable || {{ say \"${{w:-purge-failed}}\"; exit 0; }}\n"
            + $"[ -z \"$e\" ] || ag remove -y $e || {{ say \"${{w:-remove-failed}}\"; exit 0; }}\n"
            + $"e=; for g in $(gone autoremove); do printf '%s\\n' \"$k\" | grep -qxF \"$g\" && e=\"$e $g\"; done\n"
            + $"[ -z \"$e\" ] || ag remove -y $e || {{ say \"${{w:-remove-failed}}\"; exit 0; }}\n"
            + $"rm -f \"$r{FixedPath}\" \"$r{PolicyPath}\"\n"
            + $"if [ -z \"$(present google-chrome-stable)\" ]; then\n"
            + $"  for x in $f; do\n"
            + $"    case \"$x\" in {DefaultPath}|{SourcePath}|{KeyPath}) rm -f \"$r$x\";; esac\n"
            + $"  done\n"
            + $"fi\n"
            + $"rm -rf \"$d/proof\"; rm -f \"$a\" \"{lockPath}\"; rmdir \"$r{PortsFolder}\" 2>/dev/null\n"
            + $"say ok\n";
            }
            case BrowserWork.Install { Want: var want }:
            {
                var lockPath = "$r" + LockPath;
                var users = InstallPlan.Quote(string.Concat(want.Rows.Select(row =>
                    $"{row.User} {BrowserWant.Number(want.Uids.TryGetValue(row.User, out var uid) ? uid : -1)}\n")));
                var brokerText = InstallPlan.Quote(want.Broker is { } id ? BrowserWant.Number(id) : "");
                var worker = InstallPlan.Quote(want.Worker);
                var workerId = BrowserWant.Number(want.WorkerId);
                var keyText = InstallPlan.Quote(KeyData);
                string defaultText = InstallPlan.Quote(DefaultText), fixedText = InstallPlan.Quote(FixedText),
                       originText = InstallPlan.Quote(OriginText), policyText = InstallPlan.Quote(PolicyText),
                       sourceText = InstallPlan.Quote(SourceText), unitText = InstallPlan.Quote(UnitText),
                       dropinText = InstallPlan.Quote(DropinText), portsText = InstallPlan.Quote(PortsText(want.Rows)),
                       tableText = InstallPlan.Quote(want.Table);
                return head + $"P={portsText}; T={tableText}\n"
            + $"fits \"$P\" \"$T\" || {{ say ports-refused; exit 0; }}\n"
            + $"b={brokerText}; u={worker}; i={workerId}\n"
            + $"worker() {{\n"
            + $"  [ \"$u\" = {ServiceUser} ] && [ \"$i\" != 0 ] && [ \"$i\" != \"$b\" ] || return 1\n"
            + $"  pw=$(getent passwd) && [ -n \"$pw\" ] || return 1\n"
            + $"  printf '%s\\n' \"$pw\" | awk -F: -v i=\"$i\" '$1 ~ /^fleet-[a-z][a-z0-9-]*$/ && $3 == i {{f = 1}} END {{exit f}}'\n"
            + $"}}\n"
            + $"worker || {{ say worker-refused; exit 0; }}\n"
            + $"same() {{ [ \"$(id -u \"$1\" 2>/dev/null)\" = \"$2\" ]; }}\n"
            + $"users() {{\n"
            + $"  c=1\n"
            + $"  printf '%s' {users} | {{ while read -r x y; do same \"$x\" \"$y\" || exit 1; done; }} || c=\n"
            + $"  {{ same \"$u\" \"$i\" && [ \"$i\" != 0 ]; }} || c=\n"
            + $"  if [ -n \"$b\" ]; then same {Broker} \"$b\" || c=; elif id -u {Broker} >/dev/null 2>&1; then c=; fi\n"
            + $"  [ -n \"$c\" ]\n"
            + $"}}\n"
            + $"users || {{ say users-changed; exit 0; }}\n"
            + $"for x in \"$r{PortsFolder}\" \"$r{PoliciesFolder}\" \"$d/proof\" \"$r{DropinFolder}\"; do\n"
            + $"  mkdir -p \"$x\" && chmod 755 \"$x\" || {{ say write-failed; exit 0; }}\n"
            + $"done\n"
            + $"own \"$d/proof\" \"$u:\" || {{ say write-failed; exit 0; }}\n"
            + $"if [ ! -e \"$r{KeyPath}\" ]; then\n"
            + $"  put {KeyPath} \"\" key {keyText} && note 'file {KeyPath}' || {{ say write-failed; exit 0; }}\n"
            + $"fi\n"
            + $"if [ ! -e \"$r{SourcePath}\" ]; then\n"
            + $"  put {SourcePath} \"\" text {sourceText} && note 'file {SourcePath}' || {{ say write-failed; exit 0; }}\n"
            + $"fi\n"
            + $"x=; [ -e \"$r{DefaultPath}\" ] || x=1\n"
            + $"put {DefaultPath} \"\" text {defaultText} && {{ [ -z \"$x\" ] || note 'file {DefaultPath}'; }} && put {FixedPath} \"$r{StageFolder}\" text {fixedText} && put {PolicyPath} \"$r{StageFolder}\" text {policyText} && put {OriginPath} \"\" text {originText} || {{ say write-failed; exit 0; }}\n"
            + $"h=$(installed {list}); m=\n"
            + $"for p in {list}; do printf '%s\\n' \"$h\" | grep -qxF \"$p\" || m=\"$m $p\"; done\n"
            + $"if [ -n \"$m\" ]; then\n"
            + $"  ag update || {{ say \"${{w:-update-failed}}\"; exit 0; }}\n"
            + $"  every \"$s/before\" || {{ say write-failed; exit 0; }}\n"
            + $"  z=0; ag install -y --no-install-recommends --no-remove -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold $m || z=1\n"
            + $"  came || {{ say write-failed; exit 0; }}\n"
            + $"  [ \"$z\" = 0 ] || {{ say \"${{w:-install-failed}}\"; exit 0; }}\n"
            + $"  apt-get clean >/dev/null 2>&1\n"
            + $"fi\n"
            + $"[ -f \"{lockPath}\" ] || ( umask 077 && : > \"{lockPath}\" ) || {{ say write-failed; exit 0; }}\n"
            + $"own \"{lockPath}\" \"root:$(id -gn \"$u\")\" && chmod 640 \"{lockPath}\" || {{ say write-failed; exit 0; }}\n"
            + $"command exec 9<\"{lockPath}\" && flock -w 60 9 || {{ say lock-busy; exit 0; }}\n"
            + $"users || {{ say users-changed; exit 0; }}\n"
            + $"worker || {{ say worker-refused; exit 0; }}\n"
            + $"put {PortsPath} \"\" text \"$P\" && put {TablePath} \"\" text \"$T\" && put {UnitPath} \"\" text {unitText} && put {DropinPath} \"\" text {dropinText} || {{ say write-failed; exit 0; }}\n"
            + $"systemctl daemon-reload >/dev/null 2>&1 || {{ say table-failed; exit 0; }}\n"
            + $"systemctl enable fleet-browser-ports.service >/dev/null 2>&1 && systemctl reload-or-restart fleet-browser-ports.service >/dev/null 2>&1 || {{ say table-failed; exit 0; }}\n"
            + $"say ok\n";
            }
            default:
                return head + "say ok\n";
        }
    }

    /// <summary>The run's output, read from its last <c>founderizer-browser</c> line.</summary>
    public static BrowserOutcome Outcome(string output)
    {
        var all = RootJob.Lines(output);
        var lines = all.Where(l => l != Started).ToList();
        if (lines.FindLast(l => l.StartsWith(Mark + " ", StringComparison.Ordinal)) is not { } last)
        {
            var said = lines.FindLast(l => l.Length > 0) is { } line ? RootJob.Prefix(line, 200) : "nothing";
            return lines.Count == all.Count ? new BrowserOutcome.NotStarted("the program did not start: " + said)
                                            : new BrowserOutcome.Failed("the program started and did not end: " + said);
        }
        var words = last.Split(' ', StringSplitOptions.RemoveEmptyEntries).Skip(1).ToList();
        var before = string.Join(" ", words.Skip(1));
        switch (words.FirstOrDefault())
        {
            case "started": return new BrowserOutcome.StepStarted(before);
            case "running": return new BrowserOutcome.StepRuns(before);
            default:
                var earlier = string.Join(" ", lines.TakeWhile(l => l != last).Where(l => l.Length > 0).TakeLast(2));
                return new BrowserOutcome.Failed("no step started" + (earlier.Length == 0 ? "" : ": " + RootJob.Prefix(earlier, 300)));
        }
    }
}
