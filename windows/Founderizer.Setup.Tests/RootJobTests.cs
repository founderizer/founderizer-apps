using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Founderizer.Core;
using Founderizer.Owner.Reads;
using Founderizer.Remote;
using Founderizer.Setup.Install;
using Founderizer.Setup.RootJobs;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace Founderizer.Setup.Tests;

/// <summary>**When a root job runs, how often, and what it never does** (windows-app-plan-v2.md, piece L6): the engine that
/// the PC ports from the Mac's OwnerAccessSweep, with stand-ins for the connection and the server, and a clock of the test's
/// own. Each test names the bug that makes it fail.</summary>
[TestClass]
public sealed class RootJobTests
{
    private const double Time = 1_000_000;
    private static readonly Uri Hub = new("http://100.64.0.9:8765/");

    private string folder = "";

    [TestInitialize]
    public void Make() => folder = Directory.CreateTempSubdirectory("root-jobs-").FullName;

    [TestCleanup]
    public void Remove() => Directory.Delete(folder, recursive: true);

    private static JsonElement Json(string text)
    {
        using var document = JsonDocument.Parse(text);
        return document.RootElement.Clone();
    }

    private static ServerEntry Read(string text) => JsonSerializer.Deserialize(Json(text), ReadsJson.Default.ServerEntry)!;

    /// <summary>A Linux server that joined, with a current reading of its own service that says its SSH's and npm's state.
    /// </summary>
    private static string Row(string ssh = "false", string npm = "true", string name = "app-1", string address = "100.80.1.7", double reportedAt = Time - 60,
                              bool added = false) =>
        "{\"name\":\"" + name + "\",\"hub\":false,\"joined\":true,\"kind\":\"linux\",\"agents\":[\"alpha\"],\"address\":\"" + address + "\",\"available\":true," +
        "\"why\":[],\"reading\":{\"source\":\"server\",\"os\":{\"name\":\"Ubuntu 24.04\"},\"runtimes\":{},\"reported_at\":" + reportedAt.ToString(System.Globalization.CultureInfo.InvariantCulture) +
        ",\"stale\":false,\"user\":\"fleet\",\"agents\":{\"alpha\":{\"user\":\"fleet-alpha\",\"uid\":1002}}," +
        "\"browser\":{\"state\":\"missing\",\"missing\":[],\"files\":{},\"unit\":\"inactive\",\"ports\":[],\"added\":" + (added ? "true" : "false") + ",\"worker\":1000,\"broker\":1001}," +
        "\"security\":{\"ssh_keys_only\":" + ssh + ",\"npm_rule\":" + npm + "}}}";

    private static RootFleet Fleet(string row, double time = Time, JoinState? join = null, bool browser = false, IReadOnlyList<BrowserAgent>? agents = null) =>
        new(Hub, time, join, [RootServer.Of(Read(row), Json(row))], browser ? agents ?? [new BrowserAgent("alpha", ["shell", "browser"])] : null,
            browser ? [] : null);

    private const string Good = Hardening.Started + "\nfounderizer-hardening ssh=keys-only npm=made\n";
    private const string Bad = Hardening.Started + "\nfounderizer-hardening ssh=refused npm=held\n";

    /// <summary>A server that answers each program with what the test says, and the calls that it got. The fleet's records
    /// name app-1 at 100.80.1.7 as root, and this PC's Tailscale names that address app-1.</summary>
    private sealed class Server(Func<string, string> answer)
    {
        public int Runs { get; private set; }
        public List<string> Programs { get; } = [];
        public ServerRecords Records { get; set; } = Listed(("app-1", "100.80.1.7"));
        public string? Tailnet { get; set; } = Peers(("app-1", "100.80.1.7"));
        public Task<string> Run(InstallTarget target, string program, TimeSpan limit)
        {
            Runs++;
            Programs.Add(program);
            return Task.FromResult(answer(program));
        }
    }

    private static async Task RoundAsync(RootRound round, RootFleet fleet, Server server, double now) =>
        await round.RunAsync(fleet, server.Records, server.Tailnet, server.Run, () => now);

    /// <summary>The fleet's records, whose list of machines names each of these servers at its address, as root at port 22.
    /// </summary>
    private static ServerRecords Listed(params (string Name, string Address)[] servers) =>
        new(() => Task.FromResult<IReadOnlyList<MachineAccess>?>(servers.Select(s => new MachineAccess(s.Name, s.Address, "root", 22)).ToList()),
            () => Task.FromResult<OwnServer?>(null));

    /// <summary>This PC's <c>tailscale status --json</c>, whose peers are these servers at these addresses.</summary>
    private static string Peers(params (string Name, string Address)[] peers) =>
        "{\"Self\":{\"DNSName\":\"pc.tail1234.ts.net.\",\"TailscaleIPs\":[\"100.64.0.1\"],\"OS\":\"windows\"},\"Peer\":{" +
        string.Join(",", peers.Select((p, i) => $"\"p{i}\":{{\"DNSName\":\"{p.Name}.tail1234.ts.net.\",\"TailscaleIPs\":[\"{p.Address}\"],\"OS\":\"linux\"}}")) +
        "}}";

    private RootRound NewStart() => new(new RootRecords(folder));

    // ------------------------------------------------------------ the two rounds

    /// <summary>The bug: a fault that was read once (a reading in the middle of a join, one hiccup of the server's service)
    /// runs a root program on the server.</summary>
    [TestMethod]
    public async Task A_program_runs_only_after_the_same_fault_in_two_rounds_in_a_row()
    {
        var server = new Server(_ => Bad);
        var round = NewStart();
        await RoundAsync(round, Fleet(Row()), server, Time);
        Assert.AreEqual(0, server.Runs, "the first round that reads the fault runs nothing");
        // A round that reads nothing in between forgets the fault: the next one is a first round again.
        await RoundAsync(round, Fleet(Row(reportedAt: Time - 3600)), server, Time + 300);
        await RoundAsync(round, Fleet(Row()), server, Time + 600);
        Assert.AreEqual(0, server.Runs, "two faults with a round between them are not two in a row");
        await RoundAsync(round, Fleet(Row()), server, Time + 900);
        Assert.AreEqual(1, server.Runs, "two faults in a row run the program");
    }

    /// <summary>The bug: an agent's box that goes on between two rounds installs at once what the second round has not seen
    /// twice; or a browser want that changed counts as the one before it.</summary>
    [TestMethod]
    public async Task A_browser_program_runs_only_after_the_same_want_in_two_rounds_in_a_row()
    {
        var server = new Server(_ => Browser.Started + "\nfounderizer-browser started\n");
        var round = NewStart();
        // The hardening holds on this server, so each program is the browser's.
        var row = Row(ssh: "true");
        var alpha = new BrowserAgent("alpha", ["shell", "browser"]);
        await RoundAsync(round, Fleet(row, browser: true), server, Time);
        Assert.AreEqual(0, server.Runs);
        // No agent wants a browser any more: nothing to put there, and the want of the first round is no longer the same.
        await RoundAsync(round, Fleet(row, browser: true, agents: [new BrowserAgent("alpha", ["shell"])]), server, Time + 300);
        await RoundAsync(round, Fleet(row, browser: true, agents: [alpha]), server, Time + 600);
        Assert.AreEqual(0, server.Runs, "the want came back, and only one round has read it since");
        await RoundAsync(round, Fleet(row, browser: true, agents: [alpha]), server, Time + 900);
        Assert.AreEqual(1, server.Runs, "the same want in two rounds in a row");
        StringAssert.Contains(server.Programs[0], "fleet-browser-step", "the program is the browser's, as root");

        // Two wants in a row are two first rounds: an install that one round read, then the removal of parts that the
        // step added, when the agent's Browser box goes off.
        var next = NewStart();
        var changed = new Server(_ => Browser.Started + "\nfounderizer-browser started\n");
        var added = Row(ssh: "true", added: true);
        var closed = new BrowserAgent("alpha", ["shell"]);
        await RoundAsync(next, Fleet(added, browser: true, agents: [alpha]), changed, Time + 2000);
        await RoundAsync(next, Fleet(added, browser: true, agents: [closed]), changed, Time + 2300);
        Assert.AreEqual(0, changed.Runs, "a removal right after an install is a first round, not a second one");
        await RoundAsync(next, Fleet(added, browser: true, agents: [closed]), changed, Time + 2600);
        Assert.AreEqual(1, changed.Runs, "the same removal in two rounds in a row");
        StringAssert.Contains(changed.Programs[0], "systemctl disable --now fleet-browser-ports.service", "the program removes the parts");
    }

    // ------------------------------------------------------------ the tries

    /// <summary>The bug: a server whose run leaves the fault gets a root program at every round for ever, or six more at each
    /// start of the app.</summary>
    [TestMethod]
    public async Task Six_tries_at_most_ten_minutes_apart_and_kept_between_starts()
    {
        var server = new Server(_ => Bad);
        var round = NewStart();
        var runs = new List<double>();
        var now = Time;
        async Task Rounds(RootRound current, int count)
        {
            for (var n = 0; n < count; n++)
            {
                var before = server.Runs;
                await RoundAsync(current, Fleet(Row()), server, now);
                if (server.Runs > before) runs.Add(now);
                now += 60;
            }
        }
        // The first round sees the fault; then one run at each ten minutes: three of them in this start.
        await Rounds(round, 1 + 25);
        Assert.AreEqual(3, server.Runs, "a run each ten minutes");
        for (var n = 1; n < runs.Count; n++) Assert.IsTrue(runs[n] - runs[n - 1] >= 600, "runs are ten minutes apart at least");
        // A new start of the app reads the count back: three more runs, and no more.
        await Rounds(NewStart(), 1 + 60);
        Assert.AreEqual(6, server.Runs, "the six tries are in all the starts, not in each");
        await Rounds(NewStart(), 1 + 60);
        Assert.AreEqual(6, server.Runs, "and then never again");
    }

    /// <summary>The bug: a server whose connection is down for an hour loses its six tries, and then is left for good when
    /// the connection comes back (the Mac's first fleets had this).</summary>
    [TestMethod]
    public async Task A_try_that_reached_no_server_is_not_in_the_kept_count()
    {
        var unreached = new Server(_ => throw new InvalidOperationException("no program runs on a server that is not reached"))
        {
            Records = Listed(),
        };
        var round = NewStart();
        var now = Time;
        for (var n = 0; n < 200; n++, now += 60) await RoundAsync(round, Fleet(Row()), unreached, now);
        Assert.AreEqual(0, unreached.Runs);
        var kept = new RootRecords(folder).Sweep(RootRecords.Hardening, RootRecords.NameOf(Hub, Read(Row())));
        Assert.AreEqual(0, kept.Failures, "nothing of a try that ran nothing is kept");
        // After six of them this start leaves the server; the next start tries again, and then the connection works.
        var good = new Server(_ => Good);
        await RoundAsync(round, Fleet(Row()), good, now);
        Assert.AreEqual(0, good.Runs, "six tries that ran nothing are the most for one start");
        var fresh = NewStart();
        await RoundAsync(fresh, Fleet(Row()), good, now);
        await RoundAsync(fresh, Fleet(Row()), good, now + 300);
        Assert.AreEqual(1, good.Runs, "the next start reaches the server");
    }

    /// <summary>The bug: a server whose host key this PC does not know, or whose login was refused, or that did not answer,
    /// counts as a run that failed, so that it is left for good: the PC must learn the key or the login before its six tries
    /// are gone; or such a try is not counted at all, so that the server gets a call at every round for ever. The call's own
    /// failure is the output's last line, and the program's first line is not in it. Six such tries are the most in one
    /// start, for the hardening and for the browser parts each.</summary>
    [TestMethod]
    public async Task A_call_that_did_not_start_the_program_is_not_in_the_kept_count_and_six_are_the_most_in_a_start()
    {
        var reach = new Server(_ => "");
        foreach (var failure in new[] { RemoteFailure.HostKeyUnknown, RemoteFailure.HostKeyChanged, RemoteFailure.LoginRefused,
                                        RemoteFailure.NoAnswer, RemoteFailure.NotFound, RemoteFailure.Refused, RemoteFailure.Closed })
        {
            var records = new RootRecords(Path.Combine(folder, failure.ToString()));
            var name = RootRecords.NameOf(Hub, Read(Row()));
            // The hardening: the fault in two rounds in a row, then a try at each round ten minutes apart.
            var remote = new StandInRemote((_, _) => StandInRemote.Failed(failure));
            var round = new RootRound(records);
            for (var n = 0; n < 16; n++)
                await round.RunAsync(Fleet(Row()), reach.Records, reach.Tailnet,
                                     (target, program, limit) => RootCall.RunAsync(remote, target, program, limit), () => Time + n * 600);
            Assert.AreEqual(6, remote.Calls.Count, failure + ": six tries that ran nothing, and no more in this start");
            Assert.AreEqual(0, records.Sweep(RootRecords.Hardening, name).Failures, failure + ": the program did not start on the server");

            // The browser parts, on a server whose hardening holds.
            var parts = new StandInRemote((_, _) => StandInRemote.Failed(failure));
            var browser = new RootRound(records);
            for (var n = 0; n < 16; n++)
                await browser.RunAsync(Fleet(Row(ssh: "true"), browser: true), reach.Records, reach.Tailnet,
                                       (target, program, limit) => RootCall.RunAsync(parts, target, program, limit), () => Time + n * 600);
            Assert.AreEqual(6, parts.Calls.Count, failure + ": six browser tries that ran nothing, and no more in this start");
            Assert.IsTrue(parts.Calls.All(c => c.Program.Contains("fleet-browser-step", StringComparison.Ordinal)));
            Assert.AreEqual(0, records.BrowserOf(name).Failures, failure + ": no browser step started on the server");
        }
    }

    /// <summary>The bug: a want whose step starts and never puts the parts in place starts a step at every round for ever,
    /// or six more at each start of the app; a step that still runs counts as a try, so that a slow install uses up the
    /// six; or a want that changed waits for the count of the one before it.</summary>
    [TestMethod]
    public async Task Browser_steps_six_at_most_for_one_want_ten_minutes_apart_and_a_running_step_is_no_try()
    {
        var says = "running";
        var server = new Server(_ => Browser.Started + "\nfounderizer-browser " + says + "\n");
        var row = Row(ssh: "true");
        var name = RootRecords.NameOf(Hub, Read(row));
        var runs = new List<double>();
        var now = Time;
        async Task Rounds(RootRound current, int count, string? from = null)
        {
            for (var n = 0; n < count; n++)
            {
                var before = server.Runs;
                await RoundAsync(current, Fleet(from ?? row, browser: true), server, now);
                if (server.Runs > before) runs.Add(now);
                now += 60;
            }
        }
        // A step that still runs is no try: the program asks again at each round, and nothing is counted.
        var round = NewStart();
        await Rounds(round, 1 + 5);
        Assert.AreEqual(5, server.Runs, "a running step is asked again at each round");
        Assert.AreEqual(0, new RootRecords(folder).BrowserOf(name).Failures);
        // Each start of a step is a try: one each ten minutes, three in this start.
        says = "started";
        runs.Clear();
        await Rounds(round, 25);
        Assert.AreEqual(3, runs.Count, "a step each ten minutes");
        for (var n = 1; n < runs.Count; n++) Assert.IsTrue(runs[n] - runs[n - 1] >= 600, "steps are ten minutes apart at least");
        // A new start of the app reads the count back: three more, and then none for this want.
        await Rounds(NewStart(), 1 + 60);
        Assert.AreEqual(6, runs.Count, "the six tries are in all the starts, not in each");
        await Rounds(NewStart(), 1 + 60);
        Assert.AreEqual(6, runs.Count, "and then never again for this want");
        // A new want (the agent's user has another uid) starts the count again.
        var other = Row(ssh: "true").Replace("\"uid\":1002", "\"uid\":1005");
        await Rounds(NewStart(), 2, other);
        Assert.AreEqual(7, runs.Count, "a new want has six tries of its own");
    }

    /// <summary>The bug: a round that a cancel ended part of the way counts as a round, so the next round runs a program on
    /// a fault or a want that only one whole round read; or a cancel does not end the round before a server, or between a
    /// server's hardening and its browser parts.</summary>
    [TestMethod]
    public async Task A_cancelled_round_is_no_round_and_the_next_one_is_a_first_round()
    {
        // Round A reads the fault, round B is cancelled before the server, round C is a first round again.
        var server = new Server(_ => Bad);
        var round = NewStart();
        await RoundAsync(round, Fleet(Row()), server, Time);
        using (var cancel = new CancellationTokenSource())
        {
            cancel.Cancel();
            await round.RunAsync(Fleet(Row()), server.Records, server.Tailnet, server.Run, () => Time + 300, cancel.Token);
        }
        Assert.AreEqual(0, server.Runs, "a cancelled round runs nothing");
        await RoundAsync(round, Fleet(Row()), server, Time + 600);
        Assert.AreEqual(0, server.Runs, "the round after a cancelled one is a first round");
        await RoundAsync(round, Fleet(Row()), server, Time + 900);
        Assert.AreEqual(1, server.Runs);

        // The same between a server's hardening and its browser parts: the cancel comes as the hardening's turn reads the
        // clock.
        var parts = new Server(_ => Browser.Started + "\nfounderizer-browser started\n");
        var next = new RootRound(new RootRecords(Path.Combine(folder, "parts")));
        var row = Row(ssh: "true");
        await RoundAsync(next, Fleet(row, browser: true), parts, Time);
        using (var cancel = new CancellationTokenSource())
            await next.RunAsync(Fleet(row, browser: true), parts.Records, parts.Tailnet, parts.Run, () => { cancel.Cancel(); return Time + 300; },
                                cancel.Token);
        Assert.AreEqual(0, parts.Runs, "no browser step after the cancel");
        await RoundAsync(next, Fleet(row, browser: true), parts, Time + 600);
        Assert.AreEqual(0, parts.Runs, "the round after a cancelled one is a first round");
        await RoundAsync(next, Fleet(row, browser: true), parts, Time + 900);
        Assert.AreEqual(1, parts.Runs);
    }

    /// <summary>The bug: a connection that broke while the program ran (its first line was read) is not counted, so a server
    /// whose run breaks each time gets a root program at every round for ever.</summary>
    [TestMethod]
    public async Task A_run_that_broke_after_it_started_is_in_the_kept_count()
    {
        var remote = new StandInRemote((_, _) => new RemoteResult(null, "\n" + Hardening.Started + "\n", "", RemoteFailure.Dropped));
        var round = NewStart();
        var now = Time;
        for (var n = 0; n < 3; n++, now += 300)
            await round.RunAsync(Fleet(Row()), Listed(("app-1", "100.80.1.7")), Peers(("app-1", "100.80.1.7")),
                                 (target, program, limit) => RootCall.RunAsync(remote, target, program, limit), () => now);
        var kept = new RootRecords(folder).Sweep(RootRecords.Hardening, RootRecords.NameOf(Hub, Read(Row())));
        Assert.AreEqual(1, kept.Failures);
        StringAssert.Contains(kept.Reason, "started and did not end");
    }

    /// <summary>The bug: the first minutes of a server, in which its join still hardens it, count as a fault of its SSH, and a
    /// program runs on it in the middle of the join.</summary>
    [TestMethod]
    public async Task No_job_runs_in_the_hour_after_a_join()
    {
        var server = new Server(_ => Good);
        var round = NewStart();
        JoinState Joined(double created) => new("", "linux", created, created + 3600, "joined", "app-1");
        var join = Joined(Time - 600);
        for (var n = 0; n < 4; n++) await RoundAsync(round, Fleet(Row(), join: join, browser: true), server, Time + n * 300);
        Assert.AreEqual(0, server.Runs);
        var row = Row(reportedAt: Time + 3600 - 60);
        await RoundAsync(round, Fleet(row, time: Time + 3600, join: Joined(Time - 600), browser: true), server, Time + 3600);
        await RoundAsync(round, Fleet(row, time: Time + 3600, join: Joined(Time - 600), browser: true), server, Time + 3900);
        Assert.IsTrue(server.Runs >= 1, "an hour after its join the server is as another server");
    }

    /// <summary>The bug: a settled server's later change of its SSH (a choice of somebody's) is put back by this PC.</summary>
    [TestMethod]
    public async Task A_settled_server_is_left_alone_also_after_a_new_start()
    {
        var server = new Server(_ => Good);
        var round = NewStart();
        await RoundAsync(round, Fleet(Row(ssh: "true")), server, Time);
        Assert.AreEqual(0, server.Runs);
        Assert.IsTrue(new RootRecords(folder).Sweep(RootRecords.Hardening, RootRecords.NameOf(Hub, Read(Row()))).Settled);
        // Somebody lets passwords in later, and the app starts again.
        var later = NewStart();
        for (var n = 0; n < 4; n++) await RoundAsync(later, Fleet(Row()), server, Time + 600 + n * 300);
        Assert.AreEqual(0, server.Runs);
    }

    // ------------------------------------------------------------ the call

    /// <summary>The bug: a root job accepts a server that this PC has not met, or sends its program with another login than the
    /// app's own key, or not as root.</summary>
    [TestMethod]
    public async Task A_root_call_takes_known_servers_only_with_the_apps_key_as_root()
    {
        RemoteCall? made = null;
        var remote = new StandInRemote((call, _) => { made = call; return StandInRemote.Said("ok\n"); });
        var said = await RootCall.RunAsync(remote, new InstallTarget("100.80.1.7", "admin", 2222, BecomeRoot: true), "id -u", TimeSpan.FromSeconds(60));
        Assert.AreEqual("ok\n", said);
        Assert.AreEqual(HostKeyRule.Known, made!.HostKey);
        Assert.IsInstanceOfType<RemoteLogin.AppKey>(made.Login);
        Assert.AreEqual("sudo -n -i -- /bin/sh -c 'id -u'", made.Program);
        Assert.AreEqual(new RemoteTarget("100.80.1.7", 2222, "admin"), made.Target);
        Assert.IsNull(made.Input);
        Assert.AreEqual(TimeSpan.FromSeconds(60), made.Limit);
    }

    /// <summary>The bug: a call to a server that the PC has no host key of (a PC that took over a fleet) is sent all the same,
    /// or the failure does not reach the job's log. The two sentences of a server read for its vault key are the PC's
    /// own (the Mac's names a Terminal, which the PC has not).</summary>
    [TestMethod]
    public async Task A_server_with_an_unknown_host_key_gives_the_words_of_its_vault_read()
    {
        var ask = new PinAsk("app-1", "age1x", new InstallTarget("100.80.1.7"));
        async Task<string> Says(RemoteFailure? failure)
        {
            var outcome = await VaultPins.TrustAsync(ask, "0123456789abcdef", Status("app-1", "100.80.1.7"), null, new Key(), 1,
                                                     (_, _, _) => Task.FromResult(new RootCall.Answer("", failure)));
            return ((PinOutcome.Stop)outcome).Says;
        }
        Assert.AreEqual(ServerCheck.HostKeyUnknown("app-1", firstRun: false), await Says(RemoteFailure.HostKeyUnknown));
        Assert.AreEqual(ServerCheck.HostKeyChanged("app-1", firstRun: false), await Says(RemoteFailure.HostKeyChanged));
        Assert.AreEqual("Founderizer could not read its vault key on app-1.", await Says(RemoteFailure.NoAnswer));
        Assert.AreEqual("Founderizer could not read its vault key on app-1.", await Says(null));
    }

    // ------------------------------------------------------------ the pin

    private sealed class Key : IOwnerKey
    {
        public string PublicKey => "BA==";
        public string Sign(string statement) => "signed " + statement.Length;
    }

    private static string Status(string name, string address, string os = "linux") =>
        "{\"Self\":{\"DNSName\":\"pc.tail1234.ts.net.\",\"TailscaleIPs\":[\"100.64.0.1\"],\"OS\":\"windows\"},\"Peer\":{\"p\":{\"DNSName\":\"" + name +
        ".tail1234.ts.net.\",\"TailscaleIPs\":[\"" + address + "\"],\"OS\":\"" + os + "\"},\"q\":{\"DNSName\":\"other-1.tail1234.ts.net.\",\"TailscaleIPs\":[\"100.64.0.31\"]}}}";

    /// <summary>The bug: a pin is signed for the machine that the hub names, at an address that the hub's record gives, with
    /// no word of this PC about who is there: a broken-in hub sends the PC to its own server, reads the key that it wants
    /// pinned from there, and the owner's signature makes the vault seal to it. Or the hub calls a Linux server a Mac, or
    /// names an agent's user in its record, and the key is read as a user whose forced command prints what it likes.</summary>
    [TestMethod]
    public async Task A_pin_is_signed_only_when_this_PCs_own_Tailscale_names_the_address_as_that_server()
    {
        var answered = 0;
        string? read = null;
        InstallTarget? reached = null;
        async Task<PinOutcome> Trust(string? status, string? clock = null, string reported = "", string machine = "app-1", string output = "",
                                     string kind = "linux", string user = "root", bool kept = false)
        {
            var ask = new PinAsk(machine, reported.Length > 0 ? reported : Valid, new InstallTarget("100.80.1.7", user, 22, BecomeRoot: user != "root"),
                                 kind, kept);
            return await VaultPins.TrustAsync(ask, "0123456789abcdef", status, clock, new Key(), 1_000_000, (target, program, _) =>
            {
                answered++;
                (read, reached) = (program, target);
                return Task.FromResult(new RootCall.Answer(output.Length > 0 ? output : "# public key: " + Valid + "\n", null));
            });
        }
        // The PC's own Tailscale names the address as that server: the pin is signed, for the key that was read there, as root.
        var pinned = (PinOutcome.Signed)await Trust(Status("app-1", "100.80.1.7"));
        Assert.AreEqual(Valid, pinned.Recipient);
        Assert.AreEqual(OwnerStatement.Pin("0123456789abcdef", "app-1", Valid, 1_000_000), pinned.Statement);
        Assert.AreEqual("signed " + pinned.Statement.Length, pinned.Signature);
        Assert.AreEqual(1, answered);
        Assert.AreEqual(VaultPins.ReadBrokerKey, read);
        // A kept connection of another user reads as root through sudo.
        Assert.IsInstanceOfType<PinOutcome.Signed>(await Trust(Status("app-1", "100.80.1.7"), user: "admin", kept: true));
        Assert.IsTrue(reached!.BecomeRoot);
        // A Mac by the hub's word and by this PC's Tailscale both: its vault is asked as the user that it serves, with no sudo.
        Assert.IsInstanceOfType<PinOutcome.Signed>(await Trust(Status("app-1", "100.80.1.7", "macOS"), kind: "mac", user: "admin"));
        Assert.AreEqual(VaultPins.ReadMacVaultKey, read);
        Assert.IsFalse(reached!.BecomeRoot);
        // The hub calls a Linux server a Mac: it is read as root, never as the record's user.
        answered = 0;
        Assert.IsInstanceOfType<PinOutcome.Signed>(await Trust(Status("app-1", "100.80.1.7"), kind: "mac"));
        Assert.AreEqual(VaultPins.ReadBrokerKey, read);
        // The hub's record names a user that is not root, for a server that is no Mac by both words: no connection, no read.
        Assert.AreEqual("The fleet has no SSH connection to app-1 on record. Record one on its page in Servers.",
                        ((PinOutcome.Stop)await Trust(Status("app-1", "100.80.1.7"), kind: "mac", user: "fleet-alpha")).Says);
        Assert.IsInstanceOfType<PinOutcome.Stop>(await Trust(Status("app-1", "100.80.1.7", "macOS"), user: "fleet"));
        Assert.AreEqual(1, answered, "a record's user that is not root reads nothing");

        // Another server has that address, the address is nobody's, Tailscale does not answer: no SSH call, no statement.
        answered = 0;
        foreach (var status in new[] { Status("app-2", "100.80.1.7"), Status("app-1", "100.80.1.8"), "{\"Self\":{}}", "not json", null })
        {
            var stop = (PinOutcome.Stop)await Trust(status);
            Assert.AreEqual("This PC's Tailscale does not say that 100.80.1.7 is app-1. Founderizer pinned nothing.", stop.Says);
        }
        // The hub asks for another server's pin with this server's address: the address is app-1's, and not app-3's.
        Assert.IsInstanceOfType<PinOutcome.Stop>(await Trust(Status("app-1", "100.80.1.7"), machine: "app-3"));
        // A clock that is an hour off: no call at all.
        Assert.AreEqual("the clocks differ", ((PinOutcome.Stop)await Trust(Status("app-1", "100.80.1.7"), clock: "the clocks differ")).Says);
        Assert.AreEqual(0, answered, "nothing was read from a server that is not the one that Tailscale names");

        // Right server, another key than the hub reports, or no key: nothing is signed.
        Assert.AreEqual("The vault key on app-1 is not the one the hub reports for it. Founderizer pinned nothing.",
                        ((PinOutcome.Stop)await Trust(Status("app-1", "100.80.1.7"), reported: Other)).Says);
        Assert.IsInstanceOfType<PinOutcome.Stop>(await Trust(Status("app-1", "100.80.1.7"), output: "sudo: a password is required\n"));
        Assert.IsInstanceOfType<PinOutcome.Stop>(await Trust(Status("app-1", "100.80.1.7"), output: "# public key: " + Valid + "\n# public key: " + Other + "\n"));
    }

    /// <summary>Two age recipients of the tests (Bech32 of 32 bytes of 7 and of 9), from the vector.</summary>
    private static readonly string Valid = Vectors.Read("remote-vault.json").GetProperty("broker_keys")[0].GetProperty("key").GetString()!;
    private static readonly string Other = Vectors.Read("remote-vault.json").GetProperty("broker_keys")[3].GetProperty("output").GetString()!
        .Split('\n')[1]["# public key: ".Length..];

    // ------------------------------------------------------------ the owner's access line

    /// <summary>The bug: the line of the owner's access key goes to each server at each round, or a new server that has the
    /// name of a removed one (with another address) never gets it; or a mark names another key than the one whose line
    /// went, so that the fleet's next key never goes to a server that has the earlier one.</summary>
    [TestMethod]
    public async Task The_access_line_goes_once_to_each_server_and_again_to_a_new_server_of_that_name()
    {
        var calls = new List<string>();
        var good = true;
        Task<string> Run(InstallTarget target, string program, TimeSpan limit)
        {
            calls.Add(program);
            return Task.FromResult(good ? AccessLine.InPlaceWord + "\n" : "sudo: a password is required\n");
        }
        List<ServerEntry> Servers(string address) => [Read(Row(address: address)), Read(Row(name: "hub").Replace("\"hub\":false", "\"hub\":true"))];
        ServerRecords Records(string address) => Listed(("app-1", address), ("hub", "100.80.1.2"));
        string Tailnet(string address) => Peers(("app-1", address), ("hub", "100.80.1.2"));
        const string One = "ssh-ed25519 AAAA founderizer-owner-access", Two = "ssh-ed25519 BBBB founderizer-owner-access";
        var line = new AccessLine(new RootRecords(folder));
        good = false;
        await line.RoundAsync(Hub, Servers("100.80.1.7"), One, Records("100.80.1.7"), Tailnet("100.80.1.7"), Run, Time);
        Assert.AreEqual(2, calls.Count, "the hub's server and the Linux server");
        Assert.IsTrue(calls.All(c => c.Contains(One)));
        // A failure is tried again only after ten minutes, and each server has its own tries.
        await line.RoundAsync(Hub, Servers("100.80.1.7"), One, Records("100.80.1.7"), Tailnet("100.80.1.7"), Run, Time + 300);
        Assert.AreEqual(2, calls.Count);
        good = true;
        await line.RoundAsync(Hub, Servers("100.80.1.7"), One, Records("100.80.1.7"), Tailnet("100.80.1.7"), Run, Time + 600);
        Assert.AreEqual(4, calls.Count);
        Assert.IsTrue(new RootRecords(folder).Marks().InPlace("app-1", "100.80.1.7", Hub, AccessLine.Fingerprint(One)),
                      "the mark is of the key whose line went");
        // The line is in place: a new start of the app and any number of rounds send it no more.
        var later = new AccessLine(new RootRecords(folder));
        for (var n = 0; n < 5; n++)
            await later.RoundAsync(Hub, Servers("100.80.1.7"), One, Records("100.80.1.7"), Tailnet("100.80.1.7"), Run, Time + 2000 + n * 900);
        Assert.AreEqual(4, calls.Count);
        // A new server of that name at another address, and another key of the fleet, each get the line again.
        await later.RoundAsync(Hub, Servers("100.80.1.8"), One, Records("100.80.1.8"), Tailnet("100.80.1.8"), Run, Time + 9000);
        Assert.AreEqual(5, calls.Count);
        await later.RoundAsync(Hub, Servers("100.80.1.8"), Two, Records("100.80.1.8"), Tailnet("100.80.1.8"), Run, Time + 18000);
        Assert.AreEqual(7, calls.Count);
        Assert.IsTrue(calls.Skip(5).All(c => c.Contains(Two)), "the line of the other key goes to both servers");
    }

    /// <summary>The bug: the PC gets the line of the fleet's access key as text, where the Mac makes it from the key: a text
    /// with a new line puts a second line of its own into root's <c>authorized_keys</c> (<c>grep -F</c> and <c>printf</c>
    /// take each line), and a text that starts with "-" is an option of <c>grep</c>.</summary>
    [TestMethod]
    public async Task Only_a_line_of_the_fleets_access_key_makes_a_program_or_reaches_a_server()
    {
        StringAssert.Contains(AccessLine.Program("ssh-ed25519 AAAAC3Nz+/0= founderizer-owner-access"), AccessLine.InPlaceWord);
        var reached = 0;
        foreach (var bad in new[] { "ssh-ed25519 AAAA founderizer-owner-access\nssh-ed25519 BBBB other", "-e ssh-ed25519 AAAA founderizer-owner-access",
                                    "ssh-ed25519 AAAA founderizer-owner-access\n", "command=\"sh\" ssh-ed25519 AAAA founderizer-owner-access",
                                    "ssh-ed25519 AAAA founderizer-owner-access ", "ssh-rsa AAAA founderizer-owner-access", "",
                                    "ssh-ed25519 AAAAA founderizer-owner-access" })
        {
            Assert.ThrowsExactly<ArgumentException>(() => AccessLine.Program(bad), bad);
            await Assert.ThrowsExactlyAsync<ArgumentException>(() => new AccessLine(new RootRecords(folder)).RoundAsync(
                Hub, [Read(Row())], bad, Listed(("app-1", "100.80.1.7")), Peers(("app-1", "100.80.1.7")),
                (_, _, _) => { reached++; return Task.FromResult(AccessLine.InPlaceWord); }, Time));
        }
        Assert.AreEqual(0, reached, "no server is reached with a text that is not the key's line");
    }

    // ------------------------------------------------------------ the records and the connection

    /// <summary>The bug: two servers of one name, or one server of two hubs, share a record, so a new server inherits the
    /// settled mark of the server that it replaced and never gets its program.</summary>
    [TestMethod]
    public void A_record_is_of_one_hub_one_name_and_one_address()
    {
        var records = new RootRecords(folder);
        records.KeepSweep(RootRecords.Hardening, RootRecords.NameOf(Hub, Read(Row())), new SweepMemory(Settled: true));
        Assert.IsFalse(records.Sweep(RootRecords.Hardening, RootRecords.NameOf(Hub, Read(Row(address: "100.80.1.8")))).Settled);
        Assert.IsFalse(records.Sweep(RootRecords.Hardening, RootRecords.NameOf(Hub, Read(Row(name: "app-2")))).Settled);
        Assert.IsFalse(records.Sweep(RootRecords.Hardening, RootRecords.NameOf(new Uri("http://100.64.0.10:8765/"), Read(Row()))).Settled);
        Assert.IsTrue(new RootRecords(folder).Sweep(RootRecords.Hardening, RootRecords.NameOf(Hub, Read(Row()))).Settled, "kept between two starts");
        // A file that does not read is an empty record, and a new one takes its place.
        var path = Path.Combine(folder, "records", "root-jobs.json");
        var name = RootRecords.NameOf(Hub, Read(Row()));
        File.WriteAllText(path, "not json");
        Assert.IsFalse(new RootRecords(folder).Sweep(RootRecords.Hardening, name).Settled);
        // So is a member or a server's record that is null (a file of a later build, or one that a hand changed).
        File.WriteAllText(path, "{\"sweeps\":{\"hardening\":null,\"browser\":{\"x\":null}},\"browser\":{\"" + name + "\":null},\"access\":{\"x\":null}}");
        var nulls = new RootRecords(folder);
        Assert.AreEqual(new SweepMemory(), nulls.Sweep(RootRecords.Hardening, name));
        Assert.AreEqual(new BrowserMemory(), nulls.BrowserOf(name));
        Assert.AreEqual(0, nulls.Marks().All.Count);
        nulls.KeepSweep(RootRecords.Hardening, name, new SweepMemory(Settled: true));
        Assert.IsTrue(new RootRecords(folder).Sweep(RootRecords.Hardening, name).Settled);
    }

    /// <summary>The bug: the round's records and the access line's, two objects of one folder, each write their own copy of
    /// the file, so that each write drops what the other kept: a server's count of tries is lost (six more tries), or its
    /// access mark (the line again at each round).</summary>
    [TestMethod]
    public void Two_records_of_one_folder_never_write_over_each_others_records()
    {
        var round = new RootRecords(folder);
        var access = new RootRecords(folder);
        var name = RootRecords.NameOf(Hub, Read(Row()));
        Assert.AreEqual(0, round.Sweep(RootRecords.Hardening, name).Failures);
        Assert.AreEqual(0, access.Marks().All.Count);
        round.KeepSweep(RootRecords.Hardening, name, new SweepMemory(2, Time, "held"));
        var marks = access.Marks();
        marks.Keep("SHA256:one", "app-1", "100.80.1.7", Hub);
        access.KeepMarks(marks);
        round.KeepBrowser(name, new BrowserMemory("d", 1, Time, "started"));
        var later = new RootRecords(folder);
        Assert.AreEqual(new SweepMemory(2, Time, "held"), later.Sweep(RootRecords.Hardening, name));
        Assert.IsTrue(later.Marks().InPlace("app-1", "100.80.1.7", Hub, "SHA256:one"));
        Assert.AreEqual(new BrowserMemory("d", 1, Time, "started"), later.BrowserOf(name));
    }

    /// <summary>The bug: a job reaches a server with another user, port or address than the fleet's record of it, or without
    /// sudo for a kept user that is not root; it takes a record's user that is not root (whose forced command prints what it
    /// likes for the whole session); it runs as root at an address that this PC's own Tailscale does not name as that
    /// server; or it reads a page that it needs no more.</summary>
    [TestMethod]
    public async Task The_connection_is_the_one_that_this_PC_keeps_else_the_fleets_record()
    {
        var listed = new List<MachineAccess> { new("app-1", "100.80.1.7", "root", 2222), new("app-4", "100.80.1.3", "fleet", 22) };
        var reads = 0;
        var own = 0;
        var records = new ServerRecords(() => { reads++; return Task.FromResult<IReadOnlyList<MachineAccess>?>(listed); },
                                        () => { own++; return Task.FromResult<OwnServer?>(new OwnServer("hub", "100.80.1.2", "root", 22)); });
        var server = Read(Row());
        // Kept from an install: its user and port, with sudo for a user that is not root, and no page read.
        var kept = await records.ConnectionAsync(server, new InstallTarget("100.80.1.7", "admin", 22));
        Assert.AreEqual(new InstallTarget("100.80.1.7", "admin", 22, BecomeRoot: true), kept);
        Assert.AreEqual(0, reads);
        Assert.AreEqual(new InstallTarget("100.80.1.7"), ServerRecords.Target(server, new InstallTarget("100.80.1.7"), null), "root needs no sudo");
        // A kept public address: the private address that the fleet reports.
        Assert.AreEqual("100.80.1.7", ServerRecords.Target(server, new InstallTarget("203.0.113.9", "admin"), null)!.Host);
        // The fleet's record of the server: the list of machines, read once in a round.
        var first = await records.ConnectionAsync(server, null);
        Assert.AreEqual(new InstallTarget("100.80.1.7", "root", 2222), first);
        await records.ConnectionAsync(server, null);
        Assert.AreEqual(1, reads);
        // A record's user that is not root is no connection of a root job; the key registration reads as that user.
        var fleetUser = Read(Row(name: "app-4", address: "100.80.1.3"));
        Assert.AreEqual("noConnection", (await Assert.ThrowsExactlyAsync<RootUnreached>(() => records.ConnectionAsync(fleetUser, null))).Message);
        Assert.AreEqual(new InstallTarget("100.80.1.3", "fleet", 22, BecomeRoot: true),
                        ServerRecords.Target(fleetUser, null, new MachineReach("100.80.1.3", "fleet", 22), rootOnly: false));
        // A root job only where this PC's Tailscale names the connection's address as that server.
        Assert.AreEqual(first, await records.RootConnectionAsync(server, Status("app-1", "100.80.1.7")));
        foreach (var status in new[] { Status("app-2", "100.80.1.7"), Status("app-1", "100.80.1.8"), null })
        {
            var refused = await Assert.ThrowsExactlyAsync<RootUnreached>(() => records.RootConnectionAsync(server, status));
            StringAssert.Contains(refused.Message, "Tailscale does not name");
        }
        // The address is the connection's, never the row's: the list says 100.80.1.8, which Tailscale names app-2, while
        // the row's 100.80.1.7 is app-1's.
        var elsewhere = await Assert.ThrowsExactlyAsync<RootUnreached>(
            () => Listed(("app-1", "100.80.1.8")).RootConnectionAsync(server, Peers(("app-1", "100.80.1.7"), ("app-2", "100.80.1.8"))));
        StringAssert.Contains(elsewhere.Message, "Tailscale does not name");
        // A root job takes the connection that the PC keeps, under the same check.
        var keeps = new ServerRecords(() => throw new InvalidOperationException("no page is read"), () => throw new InvalidOperationException(),
                                      _ => new InstallTarget("100.80.1.7", "admin", 22));
        Assert.AreEqual(new InstallTarget("100.80.1.7", "admin", 22, BecomeRoot: true), await keeps.RootConnectionAsync(server, Status("app-1", "100.80.1.7")));
        // A server that the list does not name: its own row, then for the hub's own server the hub's page; a page that did
        // not answer says nothing, which is not the same as a record of none.
        var hub = Read(Row(name: "hub").Replace("\"hub\":false", "\"hub\":true"));
        Assert.AreEqual(new InstallTarget("100.80.1.2"), await records.ConnectionAsync(hub, null));
        Assert.AreEqual(1, own);
        var withRow = JsonSerializer.Deserialize(Json(Row(name: "app-2").Replace("\"why\":[]", "\"why\":[],\"access\":{\"ssh\":{\"user\":\"root\",\"port\":2200}}")), ReadsJson.Default.ServerEntry)!;
        Assert.AreEqual(new InstallTarget("100.80.1.7", "root", 2200), await records.ConnectionAsync(withRow, null));
        Assert.AreEqual(1, own);
        var noRow = Read(Row(name: "app-3"));
        var unnamed = await Assert.ThrowsExactlyAsync<RootUnreached>(() => records.ConnectionAsync(noRow, null));
        Assert.AreEqual("noConnection", unnamed.Message, "the pages that hold the record answered, and it is none");
        var blind = new ServerRecords(() => Task.FromResult<IReadOnlyList<MachineAccess>?>(null), () => throw new InvalidOperationException("no answer"));
        var thrown = await Assert.ThrowsExactlyAsync<RootUnreached>(() => blind.ConnectionAsync(noRow, null));
        Assert.AreEqual("recordNotRead", thrown.Message);
    }

    // ------------------------------------------------------------ the owner's computer key

    /// <summary>The bug: the key is told to the hub before it stands in the box (a lost answer loses the key); a path that
    /// the hub names is read though the rule of the path says no; or a hub that refused makes the PC's key.</summary>
    [TestMethod]
    public async Task The_registration_keeps_the_key_waiting_before_the_hub_gets_its_digest()
    {
        var value = new string('A', 43);
        var box = new MemorySecretBox();
        var posts = new List<IReadOnlyDictionary<string, string>>();
        string? waitingAtSecond = null;
        Func<string, (int, byte[])> answers = _ => (200, "{\"registered\":true}"u8.ToArray());
        async Task<ProofFailure?> Register(Func<IReadOnlyDictionary<string, string>, (int, byte[])> answer, Func<string, string>? read = null, ISecretBox? inBox = null)
        {
            posts.Clear();
            return await OwnerKeyProof.RunAsync(Hub, inBox ?? box, body =>
            {
                posts.Add(body);
                if (body.Count > 0) waitingAtSecond = OwnerPcKey.Waiting(inBox ?? box, Hub);
                return Task.FromResult(answer(body));
            }, program =>
            {
                StringAssert.Contains(program, "/home/fleet/owner-key.proof");
                return Task.FromResult(read is null ? "founderizer-proof:" + value + "\n" : read(program));
            });
        }
        (int, byte[]) Normal(IReadOnlyDictionary<string, string> body) =>
            body.Count == 0 ? (200, "{\"registered\":false,\"proof_file\":\"/home/fleet/owner-key.proof\"}"u8.ToArray()) : answers("");

        Assert.IsNull(await Register(Normal));
        Assert.AreEqual(2, posts.Count);
        Assert.AreEqual(0, posts[0].Count, "the first call carries no proof");
        Assert.AreEqual(value, posts[1]["proof"]);
        var key = OwnerPcKey.Read(box, Hub)!;
        Assert.AreEqual(OwnerPcKey.Digest(key), posts[1]["sha256"], "the hub gets the digest, and never the key");
        Assert.AreEqual(key, waitingAtSecond, "the key stands in the box before the call that tells the hub its digest");
        Assert.IsFalse(posts[1].Values.Any(v => v == key));

        // Each stop of its own step.
        var none = new MemorySecretBox();
        Assert.AreEqual(ProofFailure.NoPath, await Register(_ => (403, []), inBox: none));
        Assert.AreEqual(ProofFailure.NoPath, await Register(_ => (200, "{\"registered\":true}"u8.ToArray()), inBox: none));
        Assert.AreEqual(ProofFailure.NoPath, await Register(_ => (200, "{\"registered\":false,\"proof_file\":\"/etc/shadow\"}"u8.ToArray()), inBox: none));
        Assert.AreEqual(ProofFailure.NoPath, await Register(_ => (200, "{\"registered\":false,\"proof_file\":\"/home/../owner-key.proof\"}"u8.ToArray()), inBox: none));
        Assert.AreEqual(ProofFailure.NoValue, await Register(Normal, _ => "Permission denied\n", none));
        Assert.AreEqual(ProofFailure.NoValue, await Register(Normal, _ => throw new IOException("no connection"), none));
        Assert.IsNull(OwnerPcKey.Waiting(none, Hub), "nothing was made for a hub that gave no value");
        Assert.AreEqual(ProofFailure.Refused, await Register(b => b.Count == 0 ? Normal(b) : (403, []), inBox: none));
        Assert.IsNull(OwnerPcKey.Read(none, Hub), "a hub that refused makes no key");
        Assert.IsNotNull(OwnerPcKey.Waiting(none, Hub), "the key waits: the hub can hold it all the same");
        Assert.AreEqual(ProofFailure.NotKept, await OwnerKeyProof.RunAsync(new Uri("http://hub.example/"), none, _ => throw new InvalidOperationException(), _ => throw new InvalidOperationException()));

        // An answer that is lost: the key waits, and the hub's 2xx to the next read makes it the key.
        var lost = new MemorySecretBox();
        Assert.AreEqual(ProofFailure.NoAnswer, await Register(b => b.Count == 0 ? Normal(b) : throw new IOException("the answer is lost"), inBox: lost));
        Assert.IsNotNull(OwnerPcKey.Waiting(lost, Hub));
        Assert.IsNull(OwnerPcKey.Read(lost, Hub));
    }

    /// <summary>The bug: a PC that reads its hub and has no key registers one at each poll, or registers when the place of its
    /// key is not known, or again ten seconds after one that went through.</summary>
    [TestMethod]
    public void When_the_PC_registers_its_key()
    {
        OwnerKeyPlan.Step Step(bool held, bool refused = false, bool takesKeys = true, bool fresh = true, bool remembered = true, JobTries? tries = null,
                               double? registered = null, bool known = true) =>
            OwnerKeyPlan.StepOf(held, refused, takesKeys, fresh, remembered, tries, registered, Time, known);
        Assert.AreEqual(OwnerKeyPlan.Step.Nothing, Step(held: true));
        Assert.AreEqual(OwnerKeyPlan.Step.Remember, Step(held: true, remembered: false));
        Assert.AreEqual(OwnerKeyPlan.Step.Register, Step(held: false));
        Assert.AreEqual(OwnerKeyPlan.Step.Register, Step(held: true, refused: true));
        Assert.AreEqual(OwnerKeyPlan.Step.Nothing, Step(held: false, takesKeys: false), "a hub from before the key takes none");
        Assert.AreEqual(OwnerKeyPlan.Step.Nothing, Step(held: false, fresh: false));
        Assert.AreEqual(OwnerKeyPlan.Step.Nothing, Step(held: false, known: false), "nothing is registered while the place of the key is not known");
        Assert.AreEqual(OwnerKeyPlan.Step.Nothing, Step(held: false, tries: new JobTries(1, Time - 60, "noValue")));
        Assert.AreEqual(OwnerKeyPlan.Step.Register, Step(held: false, tries: new JobTries(1, Time - 600, "noValue")));
        Assert.AreEqual(OwnerKeyPlan.Step.Nothing, Step(held: false, tries: new JobTries(6, Time - 6000, "noValue")));
        Assert.AreEqual(OwnerKeyPlan.Step.Nothing, Step(held: false, registered: Time - 599));
        Assert.AreEqual(OwnerKeyPlan.Step.Register, Step(held: false, registered: Time - 600));
        Assert.IsTrue(OwnerKeyPlan.Cannot(new OwnerKeyPlan.Reach.None(), 0));
        Assert.IsFalse(OwnerKeyPlan.Cannot(new OwnerKeyPlan.Reach.Unknown(), 1));
        Assert.IsTrue(OwnerKeyPlan.Cannot(new OwnerKeyPlan.Reach.Unknown(), 2));
        Assert.IsInstanceOfType<OwnerKeyPlan.Reach.Target>(OwnerKeyPlan.Without(new FleetRecord.None(), new InstallTarget("100.80.1.2")));
        Assert.IsInstanceOfType<OwnerKeyPlan.Reach.None>(OwnerKeyPlan.Without(new FleetRecord.None(), null));
        Assert.IsInstanceOfType<OwnerKeyPlan.Reach.Unknown>(OwnerKeyPlan.Without(new FleetRecord.Unknown(), null));
    }
}
