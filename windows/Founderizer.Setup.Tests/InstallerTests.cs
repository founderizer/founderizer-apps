using System;
using System.Collections.Generic;
using System.Linq;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using Founderizer.Core;
using Founderizer.Remote;
using Founderizer.Setup.Install;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace Founderizer.Setup.Tests;

/// <summary>**The installer over a stand-in server** (piece L3): the order of the steps, the stop at the first failure,
/// the private address after the network step, the claim's address, and no secret in what the page shows.</summary>
[TestClass]
public sealed class InstallerTests
{
    private const string AuthKey = "tskey-auth-kEXAMPLE02-NOTAKEYNOTAKEYNOTAKEY";
    private const string JoinCode = "7KMQ2PRJ4TVW";
    private static readonly InstallTarget Server = new("203.0.113.10");

    /// <summary>A server that answers each program by what it is: the check, the network step, the claim's log, the
    /// installer's end and the checks; "ok" for the rest. <paramref name="claimAt"/>: the address that the log prints.</summary>
    private static StandInRemote Answering(string claimAt = Printed.PrivateAddress, Func<RemoteCall, RemoteResult?>? first = null) =>
        new((call, _) =>
        {
            if (first?.Invoke(call) is { } given) return given;
            var program = call.Program;
            if (program == "/bin/sh -s") return StandInRemote.Said(Printed.Ready());
            if (program.Contains("tailscale ip -4", StringComparison.Ordinal) && !program.Contains("fleet-on-network", StringComparison.Ordinal))
                return StandInRemote.Said(Printed.PrivateAddress);
            if (program.Contains("tail -n 60", StringComparison.Ordinal)) return StandInRemote.Said(Printed.ClaimLog(claimAt));
            if (program.Contains("tail -n 40", StringComparison.Ordinal)) return StandInRemote.Said("READY");
            if (program.Contains("FLEET_JOIN=", StringComparison.Ordinal)) return StandInRemote.Said("READY");
            if (program.Contains("verify --json", StringComparison.Ordinal)) return StandInRemote.Said(Printed.Checklist);
            return StandInRemote.Said("ok");
        });

    private static Installer Hub(InstallPlan plan, List<(string Code, Uri Claim)> claims, Func<Uri, CancellationToken, Task<HubRead>>? readHub = null) =>
        new(plan, AuthKey, null, (code, uri, _) => { claims.Add((code, uri)); return Task.FromResult<string?>(null); }, readHub,
            new StandInClock());

    /// <summary>**The steps run in the plan's order, and every call after the network step goes to the address that the
    /// server got there.** Both installers let SSH in over the private network only, so a step that went on to the
    /// public address would not arrive (the Mac's MachineInstaller.reached).</summary>
    [TestMethod]
    public async Task The_steps_run_in_order_and_each_after_the_network_goes_to_the_servers_private_address()
    {
        var plan = InstallPlan.Hub(Server, InstallPlan.DefaultSource, AuthKey);
        var remote = Answering();
        var seen = new List<InstallProgress>();
        var claims = new List<(string, Uri)>();
        var installer = Hub(plan, claims);
        var checklist = await installer.RunAsync(remote, seen.Add, CancellationToken.None);

        Assert.IsTrue(checklist.IsReady);
        CollectionAssert.AreEqual(plan.Steps.Select(s => s.Id).ToList(),
                                  seen.Where(p => p.State == ProgressState.Running && p.Lines.Count == 0).Select(p => p.Step).ToList());
        CollectionAssert.AreEqual(plan.Steps.Select(s => s.Id).ToList(),
                                  seen.Where(p => p.State == ProgressState.Done).Select(p => p.Step).ToList());
        // read and network go to the address the owner gave; code, plan, start, the two waits and verify to the private one.
        var hosts = remote.Calls.Select(c => c.Target.Host).ToList();
        CollectionAssert.AreEqual(new[] { Server.Host, Server.Host }, hosts.Take(2).ToList());
        Assert.IsTrue(hosts.Skip(2).All(h => h == Printed.PrivateAddress), string.Join(", ", hosts));
        Assert.AreEqual(6, hosts.Count - 2);
        Assert.AreEqual(Printed.PrivateAddress, installer.Reached.Host);
        Assert.AreEqual(new Uri($"http://{Printed.PrivateAddress}:8765/"), installer.ClaimedHub);
    }

    /// <summary>**A step that fails stops the install**, with the server's last line, and no step after it runs: a clone
    /// that failed must not be followed by the installer that needs it.</summary>
    [TestMethod]
    public async Task A_step_that_fails_stops_the_install_and_nothing_after_it_runs()
    {
        var plan = InstallPlan.Hub(Server, InstallPlan.DefaultSource, AuthKey);
        var remote = Answering(first: call => call.Program.Contains("git clone", StringComparison.Ordinal)
            ? StandInRemote.Said("Cloning into '/root/fleet-kit'...\nfatal: unable to access the repository", 128) : null);
        var seen = new List<InstallProgress>();
        var claims = new List<(string, Uri)>();
        var error = await Assert.ThrowsExactlyAsync<InstallError>(() => Hub(plan, claims).RunAsync(remote, seen.Add, CancellationToken.None));

        Assert.AreEqual(InstallErrorKind.Step, error.Kind);
        Assert.AreEqual("The Founderizer code", error.Title);
        Assert.AreEqual("fatal: unable to access the repository", error.Says);
        Assert.AreEqual(InstallStop.StepFailed, InstallStops.Of(error));
        Assert.AreEqual("code", seen.Last().Step);
        Assert.AreEqual(ProgressState.Failed, seen.Last().State);
        Assert.AreEqual(3, remote.Calls.Count, "the plan's step ran after the code failed");
        Assert.IsFalse(seen.Any(p => p.Step is "plan" or "start"));
        Assert.AreEqual(0, claims.Count);
    }

    /// <summary>**A server that IRemote did not reach stops the step with the PC's sentence for that way**, and the kind
    /// that decides a retry: a refused port read as a step that failed would never be tried again at the hub's code.</summary>
    [TestMethod]
    public async Task A_server_not_reached_stops_with_its_way_and_its_kind()
    {
        var plan = InstallPlan.Hub(Server, InstallPlan.DefaultSource, AuthKey);
        var remote = Answering(first: call => call.Program.Contains("git clone", StringComparison.Ordinal)
            ? StandInRemote.Failed(RemoteFailure.Dropped) : null);
        var error = await Assert.ThrowsExactlyAsync<InstallError>(() => Hub(plan, []).RunAsync(remote, _ => { }, CancellationToken.None));
        Assert.AreEqual(RemoteFailure.Dropped, error.Failure);
        Assert.AreEqual(InstallStop.ServerUnreached, InstallStops.Of(error));
        Assert.IsNotNull(InstallRetry.Decision(InstallStops.Of(error), InstallCauses.Of(error), InstallJob.Hub, "code", 1, false, false));
        Assert.AreEqual($"This PC could not reach {Printed.PrivateAddress} over SSH.", error.Plain(Printed.PrivateAddress));

        var refused = Answering(first: call => call.Program == "/bin/sh -s" ? StandInRemote.Failed(RemoteFailure.Refused) : null);
        var first = await Assert.ThrowsExactlyAsync<InstallError>(() => Hub(plan, []).RunAsync(refused, _ => { }, CancellationToken.None));
        Assert.AreEqual($"{Server.Host} refused SSH on port 22. Check that SSH runs on that port and lets this PC in.", first.Plain(Server.Host));
        Assert.AreEqual(1, refused.Calls.Count);
    }

    /// <summary>**A failure says the same words in the step's detail and in the page's line**: after the first run, a
    /// changed host key sends the owner to remove the server and add it again, never to start again, which would delete
    /// his fleet's servers.</summary>
    [TestMethod]
    public async Task A_failures_words_are_the_same_in_the_steps_detail_and_the_pages_line()
    {
        var plan = InstallPlan.Hub(Server, InstallPlan.DefaultSource, AuthKey);
        var changed = Answering(first: call => call.Program.Contains("git clone", StringComparison.Ordinal)
            ? StandInRemote.Failed(RemoteFailure.HostKeyChanged) : null);
        var seen = new List<InstallProgress>();
        var later = new Installer(plan, AuthKey, clock: new StandInClock(), firstRun: false);
        var error = await Assert.ThrowsExactlyAsync<InstallError>(() => later.RunAsync(changed, seen.Add, CancellationToken.None));
        var words = ServerCheck.HostKeyChanged(Printed.PrivateAddress, firstRun: false);
        StringAssert.Contains(seen.Last().Detail, words);
        Assert.AreEqual(words, error.Plain(Printed.PrivateAddress));
        Assert.AreEqual(words, InstallRecord.WordsOf(error, Printed.PrivateAddress));
        Assert.IsFalse(seen.Last().Detail!.Contains("start again", StringComparison.Ordinal));
    }

    /// <summary>**A program that a signal ended fails its step with its own last line**, as the Mac's: it is no
    /// connection that broke, and no retry runs it again beside itself. With no line at all, the connection broke.</summary>
    [TestMethod]
    public async Task A_program_that_a_signal_ended_fails_with_its_last_line()
    {
        var plan = InstallPlan.Hub(Server, InstallPlan.DefaultSource, AuthKey);
        var killed = Answering(first: call => call.Program.Contains("git clone", StringComparison.Ordinal)
            ? new RemoteResult(null, "Cloning into '/root/fleet-kit'...\nKilled", "", null) : null);
        var error = await Assert.ThrowsExactlyAsync<InstallError>(() => Hub(plan, []).RunAsync(killed, _ => { }, CancellationToken.None));
        Assert.AreEqual("Killed", error.Says);
        Assert.IsNull(error.Failure);
        Assert.AreEqual(InstallStop.StepFailed, InstallStops.Of(error));

        var silent = Answering(first: call => call.Program.Contains("git clone", StringComparison.Ordinal)
            ? new RemoteResult(null, "", "", null) : null);
        var broke = await Assert.ThrowsExactlyAsync<InstallError>(() => Hub(plan, []).RunAsync(silent, _ => { }, CancellationToken.None));
        Assert.AreEqual(RemoteFailure.Dropped, broke.Failure);
        Assert.AreEqual(InstallStop.ServerUnreached, InstallStops.Of(broke));
    }

    /// <summary>**The claim goes only to an address of 100.64.0.0/10 and the path /claim**: the log comes from a server,
    /// and a server must not point the PC's claim, which proves the owner's computer, at an address of its own choosing.</summary>
    [TestMethod]
    public async Task The_claim_goes_only_to_the_private_network_and_its_claim_path()
    {
        var plan = InstallPlan.Hub(Server, InstallPlan.DefaultSource, AuthKey);
        foreach (var elsewhere in new[] { "203.0.113.9", "100.128.0.1", "10.0.0.1", "127.0.0.1" })
        {
            var claims = new List<(string, Uri)>();
            var error = await Assert.ThrowsExactlyAsync<InstallError>(() =>
                Hub(plan, claims).RunAsync(Answering(claimAt: elsewhere), _ => { }, CancellationToken.None));
            Assert.AreEqual(InstallErrorKind.NoClaimCode, error.Kind, elsewhere);
            Assert.AreEqual(0, claims.Count, elsewhere);
        }
        var sent = new List<(string Code, Uri Claim)>();
        await Hub(plan, sent).RunAsync(Answering(), _ => { }, CancellationToken.None);
        Assert.AreEqual(1, sent.Count);
        Assert.AreEqual("ABCDEFGHJKLM", sent[0].Code);
        Assert.AreEqual(new Uri($"http://{Printed.PrivateAddress}:8765/claim"), sent[0].Claim);

        foreach (var (address, target) in new[]
                 {
                     ("http://100.64.0.9:8765/claim", true), ("http://100.127.255.254:9000/claim", true),
                     ("https://100.64.0.9:8765/claim", false), ("http://100.64.0.9:8765/claim/more", false),
                     ("http://100.64.0.9:8765/", false), ("http://100.64.0.9:8765/claim?x=1", false),
                     ("http://user@100.64.0.9:8765/claim", false), ("http://203.0.113.9:8765/claim", false),
                     ("http://hub.example:8765/claim", false), ("http://100.128.0.1:8765/claim", false),
                 })
            Assert.AreEqual(target, Claim.IsTarget(new Uri(address)), address);

        // The claim to an address that is not on the private network sends nothing at all.
        using var listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        var port = ((IPEndPoint)listener.LocalEndpoint).Port;
        using var http = new HubClient();
        var said = await Claim.SendAsync(http, new MemorySecretBox(), new Uri($"http://127.0.0.1:{port}/claim"), "ABCDEFGHJKLM");
        Assert.AreEqual(OwnerPcKey.NotOnYourNetwork, said);
        await Task.Delay(200);
        Assert.IsFalse(listener.Pending(), "the claim reached an address off the private network");
    }

    /// <summary>**The Tailscale key and the one-time codes are in no line that the page shows**: not in a step's lines,
    /// not in its detail, and not in the error. A server that prints them back (a join line that echoes its code, a
    /// program that prints its input, the installer's claim line) must not put them on the owner's screen.</summary>
    [TestMethod]
    public async Task The_auth_key_and_the_codes_are_in_no_progress_line()
    {
        var shown = new List<string>();
        void Keep(InstallProgress p) { shown.AddRange(p.Lines); if (p.Detail is not null) shown.Add(p.Detail); }

        var hub = InstallPlan.Hub(Server, InstallPlan.DefaultSource, AuthKey);
        var echo = Answering(first: call => call.Input is { } input && call.Program.Contains("cat > /root/fleet-authkey", StringComparison.Ordinal)
            ? StandInRemote.Said("got " + Encoding.UTF8.GetString(input) + "\n" + Printed.PrivateAddress) : null);
        await Hub(hub, []).RunAsync(echo, Keep, CancellationToken.None);

        var join = InstallPlan.Join(Server, $"curl -fsS http://100.64.0.1:8765/join | FLEET_JOIN={JoinCode} sh", JoinCode, AuthKey);
        var failing = Answering(first: call => call.Program.Contains("FLEET_JOIN=", StringComparison.Ordinal)
            ? StandInRemote.Said($"+ FLEET_JOIN={JoinCode} sh\nFounderizer join stopped: The join code {JoinCode} expired.", 1) : null);
        var error = await Assert.ThrowsExactlyAsync<InstallError>(() =>
            new Installer(join, AuthKey, clock: new StandInClock()).RunAsync(failing, Keep, CancellationToken.None));
        shown.Add(error.Message);
        shown.Add(error.Plain(Server.Host));

        Assert.IsTrue(shown.Count > 10);
        foreach (var secret in new[] { AuthKey, JoinCode, "ABCD-EFGH-JKLM", "ABCDEFGHJKLM" })
            Assert.IsFalse(shown.Any(line => line.Contains(secret, StringComparison.Ordinal)), $"a line holds {secret}: " +
                           shown.FirstOrDefault(line => line.Contains(secret, StringComparison.Ordinal)));
        Assert.IsTrue(shown.Any(line => line.Contains("got (not shown)", StringComparison.Ordinal)));
    }

    /// <summary>**A hub that serves this PC already needs no claim**: an install made again after its claim waits for no
    /// code (the installer makes none), and a hub that refused two reads after the installer said so stops the install
    /// with the PC's words, not after its whole time.</summary>
    [TestMethod]
    public async Task A_hub_that_is_this_PCs_already_is_not_claimed_again()
    {
        var plan = InstallPlan.Hub(Server, InstallPlan.DefaultSource, AuthKey);
        var noCode = Answering(first: call => call.Program.Contains("tail -n 60", StringComparison.Ordinal)
            ? StandInRemote.Said("this hub belongs to the Mac at 100.64.0.2 already, so no code was made") : null);
        var claims = new List<(string, Uri)>();
        var reads = new List<Uri>();
        var owned = Hub(plan, claims, (hub, _) => { reads.Add(hub); return Task.FromResult(HubRead.Serves); });
        Assert.IsTrue((await owned.RunAsync(noCode, _ => { }, CancellationToken.None)).IsReady);
        Assert.AreEqual(0, claims.Count);
        CollectionAssert.AreEqual(new[] { new Uri($"http://{Printed.PrivateAddress}:8765/") }, reads);
        Assert.AreEqual(new Uri($"http://{Printed.PrivateAddress}:8765/"), owned.ClaimedHub);

        var another = Hub(plan, claims, (_, _) => Task.FromResult(HubRead.Refuses));
        var error = await Assert.ThrowsExactlyAsync<InstallError>(() => another.RunAsync(noCode, _ => { }, CancellationToken.None));
        Assert.AreEqual(Installer.NotThisPcs, error.Says);
        Assert.AreEqual(InstallStop.HubNotOurs, InstallStops.Of(error));
        Assert.AreEqual(0, claims.Count);
    }

    /// <summary>**Only a call of the checks that never reached the server is made again**: one that broke after it began
    /// may still run its checks there, and a second beside it proves nothing.</summary>
    [TestMethod]
    public async Task The_checks_are_asked_again_only_when_the_call_never_began()
    {
        var plan = InstallPlan.Join(Server, $"curl -fsS http://100.64.0.1:8765/join | FLEET_JOIN={JoinCode} sh", JoinCode, AuthKey);
        var tries = 0;
        var late = Answering(first: call =>
            call.Program.Contains("verify --json", StringComparison.Ordinal) && ++tries < 3 ? StandInRemote.Failed(RemoteFailure.NoAnswer) : null);
        Assert.IsTrue((await new Installer(plan, AuthKey, clock: new StandInClock()).RunAsync(late, _ => { }, CancellationToken.None)).IsReady);
        Assert.AreEqual(3, tries);

        var broke = 0;
        var dropped = Answering(first: call =>
            call.Program.Contains("verify --json", StringComparison.Ordinal) && ++broke > 0 ? StandInRemote.Failed(RemoteFailure.Dropped) : null);
        var error = await Assert.ThrowsExactlyAsync<InstallError>(() =>
            new Installer(plan, AuthKey, clock: new StandInClock()).RunAsync(dropped, _ => { }, CancellationToken.None));
        Assert.AreEqual(1, broke);
        Assert.AreEqual(RemoteFailure.Dropped, error.Failure);
    }

    /// <summary>**The wait's read of the hub carries the PC's key for that hub: the kept one, and after its refusal the
    /// one that waits** (the Mac's rule of two keys). A read with no key, or with the kept key alone, is refused by the
    /// PC's own hub after a claim whose answer was lost, and two such refusals stop the install as "not this PC's".</summary>
    [TestMethod]
    public async Task The_hub_is_read_with_the_kept_key_and_then_the_one_that_waits()
    {
        using var listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        var hub = new Uri($"http://127.0.0.1:{((IPEndPoint)listener.LocalEndpoint).Port}/");
        var box = new MemorySecretBox();
        string kept = OwnerPcKey.Make(), waiting = OwnerPcKey.Make();
        OwnerPcKey.Promote(box, hub, kept);
        OwnerPcKey.KeepWaiting(box, hub, waiting);
        using var http = new HubClient();

        var seen = new List<string?>();
        var answering = AnswerAsync(listener, 403, seen, 2);
        Assert.AreEqual(HubRead.Refuses, await Claim.ReadHubAsync(http, box, hub));
        await answering.WaitAsync(TimeSpan.FromSeconds(10));
        CollectionAssert.AreEqual(new[] { "Bearer " + kept, "Bearer " + waiting }, seen);

        answering = AnswerAsync(listener, 503, seen, 1);
        Assert.AreEqual(HubRead.Silent, await Claim.ReadHubAsync(http, box, hub));
        await answering.WaitAsync(TimeSpan.FromSeconds(10));
        listener.Stop();
        Assert.AreEqual(HubRead.Silent, await Claim.ReadHubAsync(http, box, hub));
    }

    /// <summary>Answers <paramref name="count"/> requests with <paramref name="status"/>, and keeps each one's
    /// Authorization header.</summary>
    private static async Task AnswerAsync(TcpListener listener, int status, List<string?> seen, int count)
    {
        for (var n = 0; n < count; n++)
        {
            using var client = await listener.AcceptTcpClientAsync();
            var stream = client.GetStream();
            var head = new StringBuilder();
            var one = new byte[1];
            while (!head.ToString().EndsWith("\r\n\r\n", StringComparison.Ordinal) && await stream.ReadAsync(one) == 1)
                head.Append((char)one[0]);
            seen.Add(head.ToString().Split("\r\n").FirstOrDefault(l => l.StartsWith("Authorization: ", StringComparison.OrdinalIgnoreCase))?["Authorization: ".Length..]);
            var body = "{\"error\": \"no\", \"auth\": \"owner_key_mismatch\"}";
            await stream.WriteAsync(Encoding.ASCII.GetBytes($"HTTP/1.1 {status} No\r\nContent-Type: application/json\r\nContent-Length: {body.Length}\r\nConnection: close\r\n\r\n{body}"));
        }
    }
}
