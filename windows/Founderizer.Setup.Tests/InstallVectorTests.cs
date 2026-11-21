using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Founderizer.Remote;
using Founderizer.Setup.Install;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace Founderizer.Setup.Tests;

/// <summary>**The install of the PC is the Mac's install** (windows-app-plan-v2.md, 5.6, piece L3): each step, each
/// program, its input and the command that the server gets equal app/vectors/remote-install.json, and each reading of an
/// example output equals app/vectors/install-reads.json. Both files come from FleetCore's own code
/// (RemoteInstallVectorsTests.swift). A sentence of the Mac is the PC's with "PC" for "Mac" (rule 14), but for the
/// differences that this file names.</summary>
[TestClass]
public sealed class InstallVectorTests
{
    private static readonly JsonElement Programs = Vectors.Read("remote-install.json");
    private static readonly JsonElement Reads = Vectors.Read("install-reads.json");

    // ------------------------------------------------------------ the plans

    private static InstallTarget Target(JsonElement inputs) =>
        new(inputs.Text("host")!, inputs.Text("user")!, inputs.GetProperty("port").GetInt32());

    private static MachineCheckout Machine(string raw) => raw switch
    {
        "hub" => MachineCheckout.Hub,
        "linuxWorker" => MachineCheckout.LinuxWorker,
        "macWorker" => MachineCheckout.MacWorker,
        _ => throw new ArgumentException(raw),
    };

    /// <summary>The C# plan for the inputs of one plan of the file.</summary>
    private static InstallPlan Plan(JsonElement inputs, InstallTarget? target = null)
    {
        var to = target ?? Target(inputs);
        return inputs.Text("job") switch
        {
            "hub" => InstallPlan.Hub(to, inputs.Text("source")!, inputs.Text("auth_key"), inputs.Text("manager_name"),
                                     inputs.GetProperty("one_server").GetBoolean(),
                                     inputs.Text("shape") switch { "one" => ServersStep.One, "two" => ServersStep.Two, "each" => ServersStep.Each, _ => null },
                                     inputs.Text("runtime")),
            "join" => InstallPlan.Join(to, inputs.Text("line")!, inputs.Text("code")!, inputs.Text("auth_key")),
            "check" => InstallPlan.Check(to, Machine(inputs.Text("machine")!)),
            "restart" => InstallPlan.Restart(to, Machine(inputs.Text("machine")!)),
            "update" => InstallPlan.Update(to, Machine(inputs.Text("machine")!), inputs.Text("agent")!),
            var job => throw new ArgumentException(job),
        };
    }

    private static (string Kind, IReadOnlyList<string> Programs) Action(StepAction action) => action switch
    {
        StepAction.Check => ("check", ["/bin/sh -s"]),
        StepAction.Run run => ("run", [run.Program]),
        StepAction.Join join => ("join", [InstallPlan.VerifyLater + join.Line]),
        StepAction.SendAuthKey send => ("send_auth_key", [send.Program]),
        StepAction.Detach detach => ("detach", [detach.Program]),
        StepAction.WaitFor wait => ("wait_for", [wait.Program]),
        StepAction.WaitForClaim wait => ("wait_for_claim", [wait.Program]),
        StepAction.SignIn signIn => ("sign_in", [signIn.Start, signIn.Watch]),
        StepAction.Claim => ("claim", []),
        StepAction.Verify verify => ("verify", [verify.Program]),
        _ => throw new ArgumentException("no such action"),
    };

    /// <summary>A step whose program, words or waits differ from the Mac's: a wrong word in a program makes a server
    /// that the Mac would install another way (a tailscale up with no --reset, a sudo that eats the program).</summary>
    [TestMethod]
    public void Each_step_of_each_plan_is_the_Macs_step()
    {
        Assert.AreEqual(ServerCheck.Script, Programs.Text("check_script"), "the check's script is not the Mac's");
        var plans = Programs.GetProperty("plans").EnumerateArray().ToList();
        Assert.IsTrue(plans.Count >= 19, "the file lost plans");
        Assert.IsTrue(plans.Any(p => p.GetProperty("steps").EnumerateArray().Any(s => s.GetProperty("programs").EnumerateArray()
                          .Any(x => x.Text("program")!.Contains("--manager-name juno --runtime codex", StringComparison.Ordinal)))),
                      "no plan of the file holds a manager's name that the installer takes");
        foreach (var expected in plans)
        {
            var name = expected.Text("name");
            var plan = Plan(expected.GetProperty("inputs"));
            Assert.AreEqual(expected.Text("job"), plan.Job == InstallJob.Hub ? "hub" : "join", name);
            Assert.AreEqual(expected.GetProperty("installs").GetBoolean(), plan.Installs, name);
            CollectionAssert.AreEqual(expected.GetProperty("redactions").Texts(), plan.Redactions.ToList(), name);
            var steps = expected.GetProperty("steps").EnumerateArray().ToList();
            Assert.AreEqual(steps.Count, plan.Steps.Count, name);
            for (var i = 0; i < steps.Count; i++)
            {
                var (want, step) = (steps[i], plan.Steps[i]);
                var at = $"{name}, step {want.Text("id")}";
                Assert.AreEqual(want.Text("id"), step.Id, at);
                Assert.AreEqual(Vectors.Pc(want.Text("title")!), step.Title, at);
                Assert.AreEqual(Vectors.Pc(want.Text("says")!), step.Says, at);
                var (kind, programs) = Action(step.Action);
                Assert.AreEqual(want.Text("action"), kind, at);
                CollectionAssert.AreEqual(want.GetProperty("programs").EnumerateArray().Select(p => p.Text("program")).ToList(),
                                          programs.ToList(), at);
                switch (step.Action)
                {
                    case StepAction.Check c: AssertWaits(want, c.Every, c.Within, at); break;
                    case StepAction.WaitFor w: AssertWaits(want, w.Every, w.Within, at); Assert.AreEqual(want.Text("mark"), w.Mark, at); break;
                    case StepAction.WaitForClaim w: AssertWaits(want, w.Every, w.Within, at); Assert.AreEqual(ClaimCode.LogMark, want.Text("mark"), at); break;
                    case StepAction.SignIn s: AssertWaits(want, s.Every, s.Within, at); break;
                    case StepAction.Join j: Assert.AreEqual(want.Text("line"), j.Line, at); break;
                }
            }
        }
    }

    private static void AssertWaits(JsonElement want, double every, double within, string at)
    {
        Assert.AreEqual(want.GetProperty("every").GetDouble(), every, at);
        Assert.AreEqual(want.GetProperty("within").GetDouble(), within, at);
    }

    /// <summary>The time limit of each call, by the step's action (the Mac's MachineInstaller.perform): with the default
    /// of 600 seconds a join of a slow server, a clone or the checks would be cut in their middle.</summary>
    private static double Limit(string action, int program) => action switch
    {
        "check" or "detach" or "wait_for" or "wait_for_claim" => 120,
        "run" or "verify" => 1800,
        "join" => 3600,
        "send_auth_key" => 3000,
        "sign_in" => program == 0 ? 900 : 60,
        _ => throw new ArgumentException(action),
    };

    /// <summary>**Each program reaches the server as the Mac sends it**: the plan run over a stand-in server, for root, for
    /// a user whose sudo asks nothing (the installer holds a password, which must never reach that sudo), and for one
    /// whose sudo asks for it (its first line of input, before the step's own input). Each call's program equals the
    /// command that the Mac's ssh gets, its input the Mac's, and its limit the Mac's. A wrong wrap through sudo -i loses
    /// a "$" of the program (the access line of 11 November 2026 went into no file); a password fed to a sudo that does
    /// not ask for it is read by the program as its input.</summary>
    [TestMethod]
    public async Task Each_program_reaches_the_server_as_the_Mac_sends_it()
    {
        var targets = Programs.GetProperty("targets");
        var asRoot = Target(targets.GetProperty("as_root"));
        var sudoUser = Target(targets.GetProperty("through_sudo")) with { BecomeRoot = true };
        const string password = "pa55 wörd é";
        foreach (var expected in Programs.GetProperty("plans").EnumerateArray())
        foreach (var variant in new[] { "as_root", "through_sudo", "with_password" })
        {
            var name = $"{expected.Text("name")} ({variant})";
            var inputs = expected.GetProperty("inputs");
            var target = variant == "as_root" ? asRoot : sudoUser;
            var plan = Plan(inputs, target);
            var feeds = variant == "with_password" && plan.Steps.Any(s => s.Action is StepAction.Check);
            var check = variant switch
            {
                "as_root" => Printed.Ready(),
                "through_sudo" => Printed.Ready("user=admin", "uid=1000", "sudo=nopasswd"),
                _ => Printed.Ready("user=admin", "uid=1000", "sudo=password"),
            };
            var calls = new Queue<(string Program, byte[]? Input, double Limit, string Answer)>();
            foreach (var step in expected.GetProperty("steps").EnumerateArray())
            {
                var action = step.Text("action")!;
                var programs = step.GetProperty("programs").EnumerateArray().ToList();
                for (var n = 0; n < programs.Count; n++)
                {
                    var p = programs[n];
                    var root = p.Text("runs") == "root";
                    var wire = variant == "with_password" && !feeds ? p.Text("through_sudo")! : p.Text(variant)!;
                    var stdin = p.Text("input") is { } text ? Encoding.UTF8.GetBytes(text) : null;
                    var input = feeds && root ? Encoding.UTF8.GetBytes(password + "\n").Concat(stdin ?? []).ToArray() : stdin;
                    var answer = action switch
                    {
                        "check" => check,
                        "send_auth_key" => Printed.PrivateAddress,
                        "run" when step.Text("id") == "network" => Printed.PrivateAddress,
                        "join" => "READY",
                        "wait_for" => step.Text("mark")!,
                        "wait_for_claim" => Printed.ClaimLog(Printed.PrivateAddress),
                        "sign_in" => n == 0 ? "" : "fleet-machine-name=web-1\nfleet-on-network\n" + Printed.PrivateAddress,
                        "verify" => Printed.Checklist,
                        _ => "ok",
                    };
                    calls.Enqueue((wire, input, Limit(action, n), answer));
                }
            }
            var remote = new StandInRemote((call, input) =>
            {
                Assert.IsTrue(calls.Count > 0, $"{name}: a call that the Mac does not make");
                var want = calls.Dequeue();
                Assert.AreEqual(want.Program, call.Program, name);
                CollectionAssert.AreEqual(want.Input, input, $"{name}: the input of {want.Program[..Math.Min(40, want.Program.Length)]}");
                Assert.AreEqual(TimeSpan.FromSeconds(want.Limit), call.Limit, name);
                Assert.IsInstanceOfType<RemoteLogin.AppKey>(call.Login, name);
                Assert.AreEqual(HostKeyRule.TakeNew, call.HostKey, name);
                return StandInRemote.Said(want.Answer);
            });
            var claimed = new List<(string, Uri)>();
            var installer = new Installer(plan, inputs.TryGetProperty("auth_key", out var key) ? key.Text() : null,
                                          variant == "as_root" ? null : password.ToCharArray(),
                                          (code, uri, _) => { claimed.Add((code, uri)); return Task.FromResult<string?>(null); },
                                          clock: new StandInClock());
            var checklist = await installer.RunAsync(remote, _ => { }, CancellationToken.None);
            Assert.IsTrue(checklist.IsReady, name);
            Assert.AreEqual(0, calls.Count, $"{name}: a call of the Mac that the PC did not make");
            Assert.AreEqual(plan.Steps.Any(s => s.Action is StepAction.Claim) ? 1 : 0, claimed.Count, name);
        }
    }

    // ------------------------------------------------------------ the reads

    /// <summary>A code or an address read in another way: a server's log could point the PC at an address of its own
    /// choosing, or a code with a letter that the hub never makes would be sent.</summary>
    [TestMethod]
    public void The_link_code_and_its_address_are_read_as_the_Mac_reads_them()
    {
        var claim = Reads.GetProperty("claim_code");
        Assert.AreEqual(ClaimCode.LogMark, claim.Text("log_mark"));
        Assert.AreEqual(ClaimCode.Alphabet, claim.Text("alphabet"));
        foreach (var c in claim.GetProperty("found").EnumerateArray())
        {
            var found = ClaimCode.Found(c.Text("log")!);
            Assert.AreEqual(c.Text("code"), found?.Code, c.Text("log"));
            Assert.AreEqual(c.Text("claim"), found?.Claim.AbsoluteUri, c.Text("log"));
        }
        foreach (var c in claim.GetProperty("read").EnumerateArray()) Assert.AreEqual(c.Text("code"), ClaimCode.Read(c.Text("given")!), c.Text("given"));
        foreach (var c in claim.GetProperty("grouped").EnumerateArray()) Assert.AreEqual(c.Text("grouped"), ClaimCode.Grouped(c.Text("code")!));
        foreach (var c in claim.GetProperty("private").EnumerateArray())
            Assert.AreEqual(c.GetProperty("private").GetBoolean(), ClaimCode.IsPrivateAddress(c.Text("host")!), c.Text("host"));
    }

    /// <summary>A sign-in read in another way: a link to another site would open in the owner's browser, where he is an
    /// admin of his tailnet, or an end of the sign-in would be read as a wait.</summary>
    [TestMethod]
    public void The_sign_in_of_a_server_is_read_as_the_Mac_reads_it()
    {
        var signIn = Reads.GetProperty("network_sign_in");
        foreach (var c in signIn.GetProperty("read").EnumerateArray())
        {
            var lines = c.GetProperty("lines").Texts();
            var at = string.Join(" | ", lines);
            var found = NetworkSignIn.Found(lines);
            Assert.AreEqual(c.Text("url"), found?.Url.AbsoluteUri, at);
            Assert.AreEqual(c.Text("server"), found?.Server, at);
            var reading = c.GetProperty("reading");
            switch (NetworkSignIn.Read(lines))
            {
                case NetworkSignIn.Reading.On: Assert.AreEqual("on", reading.Text("state"), at); break;
                case NetworkSignIn.Reading.Ended ended:
                    Assert.AreEqual("ended", reading.Text("state"), at);
                    Assert.AreEqual(reading.Text("says"), ended.Says, at);
                    break;
                case NetworkSignIn.Reading.Waiting waiting:
                    Assert.AreEqual("waiting", reading.Text("state"), at);
                    Assert.AreEqual(reading.Text("url"), waiting.Link?.Url.AbsoluteUri, at);
                    break;
            }
        }
        foreach (var c in signIn.GetProperty("tags").EnumerateArray())
            CollectionAssert.AreEqual(c.GetProperty("tags").Texts(), NetworkSignIn.Tags(c.Text("line")!).ToList(), c.Text("line"));
        var words = signIn.GetProperty("words");
        Assert.AreEqual(NetworkSignIn.NotOnNetwork, words.Text("not_on_network"));
        Assert.AreEqual(NetworkSignIn.NotApproved, words.Text("not_approved"));
        Assert.AreEqual(NetworkSignIn.NotStarted, words.Text("not_started"));
    }

    /// <summary>An address, a stop or a need for the network key read in another way: an install would go on to an address
    /// that is not the server's, or ask for a key it does not need.</summary>
    [TestMethod]
    public void The_plans_reads_of_a_servers_lines_are_the_Macs()
    {
        var plan = Reads.GetProperty("plan");
        foreach (var c in plan.GetProperty("private_address").EnumerateArray())
            Assert.AreEqual(c.Text("address"), InstallPlan.PrivateAddress(c.GetProperty("lines").Texts()));
        foreach (var c in plan.GetProperty("needs_network_key").EnumerateArray())
            Assert.AreEqual(c.GetProperty("needs").GetBoolean(), InstallPlan.NeedsNetworkKey(c.Text("says")!), c.Text("says"));
        foreach (var c in plan.GetProperty("stop_line").EnumerateArray())
            Assert.AreEqual(c.Text("line"), InstallPlan.StopLine(c.GetProperty("lines").Texts()));
        CollectionAssert.AreEqual(plan.GetProperty("stop_marks").Texts(), InstallPlan.StopMarks.ToList());
        Assert.AreEqual(plan.Text("hub_systems"), InstallPlan.HubSystems);
        Assert.AreEqual(plan.Text("join_systems"), InstallPlan.JoinSystems);
    }

    /// <summary>A stop sentence read as another cause: a retry for a stop that no retry repairs, or none for one that
    /// passes.</summary>
    [TestMethod]
    public void Each_stop_sentence_gives_the_Macs_cause()
    {
        foreach (var c in Reads.GetProperty("install_cause").EnumerateArray())
            Assert.AreEqual(c.Text("cause"), InstallCauses.Of(c.Text("sentence")!).Name(), c.Text("sentence"));
        CollectionAssert.AreEqual(Reads.GetProperty("causes").Texts(), Enum.GetValues<InstallCause>().Select(c => c.Name()).ToList());
        CollectionAssert.AreEqual(Reads.GetProperty("stops").Texts(), Enum.GetValues<InstallStop>().Select(s => s.Name()).ToList());
        CollectionAssert.AreEqual(Reads.GetProperty("step_ids").Texts(), InstallStepIds.All.ToList());
    }

    /// <summary>Another retry than the Mac's: a used join code sent again (the hub's lock comes nearer), or a lost
    /// tailscale up run again beside the first.</summary>
    [TestMethod]
    public void Each_retry_decision_is_the_Macs()
    {
        var retry = Reads.GetProperty("install_retry");
        foreach (var c in retry.GetProperty("decisions").EnumerateArray())
        {
            var made = InstallRetry.Decision(InstallStops.Named(c.Text("stop")!),
                                             c.Text("cause") is { } cause ? InstallCauses.Named(cause) : null,
                                             c.Text("job") == "hub" ? InstallJob.Hub : InstallJob.Join, c.Text("step"),
                                             c.GetProperty("tries").GetInt32(), c.GetProperty("needs_network_key").GetBoolean(),
                                             c.GetProperty("used_sudo_password").GetBoolean());
            var at = c.GetRawText();
            var want = c.GetProperty("retry");
            if (want.ValueKind == JsonValueKind.Null) { Assert.IsNull(made, at); continue; }
            Assert.IsNotNull(made, at);
            Assert.AreEqual(want.GetProperty("fresh_code").GetBoolean(), made.FreshCode, at);
            var wait = want.GetProperty("wait");
            if (wait.Text("kind") == "nothing") Assert.IsInstanceOfType<InstallRetry.Wait.Nothing>(made.Waits, at);
            else
            {
                var reads = (InstallRetry.Wait.Reads)made.Waits;
                Assert.AreEqual(wait.GetProperty("count").GetInt32(), reads.Count, at);
                Assert.AreEqual(wait.GetProperty("until_answer").GetBoolean(), reads.UntilAnswer, at);
            }
        }
        foreach (var c in retry.GetProperty("keeps_code").EnumerateArray())
            Assert.AreEqual(c.GetProperty("keeps").GetBoolean(),
                            InstallRetry.KeepsCode(c.GetProperty("expires_at").GetDouble(), c.GetProperty("now").GetDouble()));
        Assert.AreEqual(InstallRetry.Most, retry.GetProperty("most").GetInt32());
        Assert.AreEqual(InstallRetry.CodeLeftAtLeast, retry.GetProperty("code_left_at_least").GetDouble());
        Assert.AreEqual(InstallRetry.ReadEvery, retry.GetProperty("read_every").GetDouble());
    }

    /// <summary>Other steps or minutes under the build's title than the Mac shows for the same install.</summary>
    [TestMethod]
    public void The_four_steps_and_the_minutes_left_are_the_Macs()
    {
        var phases = Reads.GetProperty("install_phases");
        CollectionAssert.AreEqual(phases.GetProperty("names").Texts(), InstallPhases.Names.ToList());
        Assert.AreEqual(InstallPhases.OtherStep, phases.GetProperty("other_step").GetInt32());
        var seconds = phases.GetProperty("seconds").EnumerateObject().ToDictionary(p => p.Name, p => p.Value.GetInt32());
        CollectionAssert.AreEquivalent(seconds.ToList(), InstallPhases.Seconds.ToList());
        foreach (var c in phases.GetProperty("cases").EnumerateArray())
        {
            var reported = c.GetProperty("reported").EnumerateArray().Select(r => new InstallProgress(
                r.Text("step")!, r.Text("step")!, "", Enum.Parse<ProgressState>(r.Text("state")!, ignoreCase: true),
                r.GetProperty("lines").Texts())).ToList();
            var made = InstallPhases.Of(reported, c.GetProperty("planned").Texts(), c.GetProperty("running_for").GetDouble());
            var want = c.GetProperty("phases");
            var at = c.Text("name");
            if (want.ValueKind == JsonValueKind.Null) { Assert.IsNull(made, at); continue; }
            Assert.IsNotNull(made, at);
            Assert.AreEqual(want.GetProperty("current").GetInt32(), made.Current, at);
            Assert.AreEqual(want.GetProperty("minutes_left").GetInt32(), made.MinutesLeft, at);
            Assert.AreEqual(want.Text("status") is { } status ? Vectors.Pc(status) : null, made.Status, at);
            Assert.AreEqual(want.Text("step"), made.Step, at);
            CollectionAssert.AreEqual(want.GetProperty("parts").EnumerateArray().Select(p => p.GetDouble()).ToList(), made.Parts.ToList(), at);
        }
        foreach (var c in phases.GetProperty("installer_step").EnumerateArray())
            Assert.AreEqual(c.Text("words"), InstallPhases.InstallerStep(c.Text("line")!), c.Text("line"));
    }

    /// <summary>Checks read in another way: a server whose list the Mac reads as not ready would be ready on the PC, or a
    /// program's error read as a list of checks.</summary>
    [TestMethod]
    public void The_checks_of_a_server_are_read_as_the_Mac_reads_them()
    {
        var lists = Reads.GetProperty("verify_checklist");
        CollectionAssert.AreEqual(lists.GetProperty("ids").Texts(), VerifyChecklist.Ids.ToList());
        Assert.AreEqual(VerifyChecklist.ReadyLine, lists.Text("ready_line"));
        foreach (var c in lists.GetProperty("titles").EnumerateArray())
            Assert.AreEqual(c.Text("title"), VerifyChecklist.Title(c.Text("id")!), c.Text("id"));
        foreach (var c in lists.GetProperty("outputs").EnumerateArray())
        {
            var output = c.Text("output")!;
            Assert.AreEqual(c.GetProperty("holds_list").GetBoolean(), VerifyChecklist.HoldsList(output), output);
            var made = VerifyChecklist.Read(output);
            var want = c.GetProperty("read");
            if (want.ValueKind == JsonValueKind.Null) { Assert.IsNull(made, output); continue; }
            Assert.IsNotNull(made, output);
            CollectionAssert.AreEqual(want.GetProperty("ids").Texts(), made.Checks.Select(x => x.Check).ToList(), output);
            Assert.AreEqual(want.Text("line"), made.Line, output);
            Assert.AreEqual(want.GetProperty("ready").GetBoolean(), made.IsReady, output);
            Assert.AreEqual(want.GetProperty("only_needs_sign_in").GetBoolean(), made.OnlyNeedsSignIn, output);
            Assert.AreEqual(want.Text("summary"), made.Summary, output);
            CollectionAssert.AreEqual(want.GetProperty("said").Texts(), made.Said.Select(x => x.Check).ToList(), output);
            Assert.AreEqual(want.GetProperty("our_own_passed").GetInt32(), made.OurOwnPassed, output);
            CollectionAssert.AreEqual(want.GetProperty("fixes").EnumerateArray().Select(f => f.Text()).ToList(),
                                      made.Checks.Select(x => x.Fix).ToList(), output);
            CollectionAssert.AreEqual(want.GetProperty("commands").EnumerateArray().Select(f => f.Text()).ToList(),
                                      made.Checks.Select(x => x.Command).ToList(), output);
        }
    }

    /// <summary>A server read or judged in another way: an install that the Mac stops before anything changes would
    /// start on the PC, or one that the Mac starts would stop.</summary>
    [TestMethod]
    public void The_check_of_a_server_reads_and_judges_as_the_Macs()
    {
        var checks = Reads.GetProperty("server_check");
        CollectionAssert.AreEqual(checks.GetProperty("hosts").Texts(), ServerCheck.Hosts.ToList());
        foreach (var c in checks.GetProperty("readings").EnumerateArray())
        {
            var output = c.Text("output")!;
            var made = ServerCheck.Read(output);
            var want = c.GetProperty("reading");
            if (want.ValueKind == JsonValueKind.Null) { Assert.IsNull(made, output); continue; }
            Assert.IsNotNull(made, output);
            Assert.AreEqual(want.Text("user"), made.User, output);
            Assert.AreEqual(want.GetProperty("uid").GetInt32(), made.Uid, output);
            Assert.AreEqual(want.Text("sudo"), made.Sudo.ToString().ToLowerInvariant(), output);
            Assert.AreEqual(want.Text("system"), made.System, output);
            Assert.AreEqual(want.Text("version"), made.Version, output);
            Assert.AreEqual(want.Text("system_name"), made.SystemName, output);
            Assert.AreEqual(want.Text("arch"), made.Arch, output);
            Assert.AreEqual(Number(want.GetProperty("memory_mb")), made.MemoryMB, output);
            Assert.AreEqual(Number(want.GetProperty("disk_free_mb")), made.DiskFreeMB, output);
            Assert.AreEqual(want.GetProperty("systemd").GetBoolean(), made.Systemd, output);
            Assert.AreEqual(want.GetProperty("ipv4_route").GetBoolean(), made.Ipv4Route, output);
            CollectionAssert.AreEquivalent(want.GetProperty("reach").EnumerateObject().Select(p => $"{p.Name}={p.Value.GetString()}").ToList(),
                                           made.Reaches.Select(p => $"{p.Key}={p.Value.ToString().ToLowerInvariant()}").ToList(), output);
            Assert.AreEqual(want.Text("cloud_init"), made.CloudInit.ToString().ToLowerInvariant(), output);
            Assert.AreEqual(want.GetProperty("dpkg_lock").GetBoolean(), made.DpkgLock, output);
            CollectionAssert.AreEqual(want.GetProperty("listeners").EnumerateArray()
                                          .Select(l => $"{l.Text("proto")}/{l.GetProperty("port").GetInt32()}/{l.Text("process")}").ToList(),
                                      made.Listeners.Select(l => $"{l.Proto}/{l.Port}/{l.Process}").ToList(), output);
            Assert.AreEqual(want.Text("firewall"), made.Firewall.ToString().ToLowerInvariant(), output);
            Assert.AreEqual(want.Text("tailscale"), made.Tailscale.ToString().ToLowerInvariant(), output);
            Assert.AreEqual(want.Text("tailnet"), made.Tailnet, output);
        }
        foreach (var c in checks.GetProperty("verdicts").EnumerateArray())
        {
            var at = c.Text("name");
            var reading = ServerCheck.Read(c.Text("output")!)!;
            var made = ServerCheck.VerdictOf(reading, c.Text("job") == "hub" ? InstallJob.Hub : InstallJob.Join,
                                             c.GetProperty("ssh_port").GetInt32(), c.GetProperty("holds_sudo_password").GetBoolean(),
                                             c.Text("tailnet"));
            var want = c.GetProperty("verdict");
            switch (made)
            {
                case ServerCheck.Verdict.Ready ready:
                    Assert.AreEqual("ready", want.Text("kind"), at);
                    Assert.AreEqual(want.Text("summary"), ready.Summary, at);
                    Assert.AreEqual(want.Text("changes"), ready.Changes, at);
                    break;
                case ServerCheck.Verdict.Wait wait:
                    Assert.AreEqual("wait", want.Text("kind"), at);
                    Assert.AreEqual(want.Text("says"), wait.Says, at);
                    break;
                case ServerCheck.Verdict.NeedsPassword need:
                    Assert.AreEqual("needs_password", want.Text("kind"), at);
                    Assert.AreEqual(want.Text("need"), need.Need.ToString().ToLowerInvariant(), at);
                    break;
                case ServerCheck.Verdict.Stop stop:
                    Assert.AreEqual("stop", want.Text("kind"), at);
                    Assert.AreEqual(Vectors.Pc(want.Text("says")!), stop.Says, at);
                    break;
            }
        }
    }

    private static int? Number(JsonElement value) => value.ValueKind == JsonValueKind.Null ? null : value.GetInt32();

    /// <summary>**The ways of not reaching a server have the Mac's sentences, with "PC"**: the Mac reads them from ssh's
    /// words, the PC from the way IRemote failed. A refused port said as a silent one sends the owner to the wrong
    /// place. The two sentences of the PC's own (a changed host key, the app's key refused) are its known differences:
    /// the Mac sends the owner to a console and to a key file, and the PC has neither.</summary>
    [TestMethod]
    public void Each_way_of_not_reaching_a_server_has_the_Macs_sentence()
    {
        var checks = Reads.GetProperty("server_check");
        foreach (var c in checks.GetProperty("unreached").EnumerateArray())
        {
            var said = c.Text("said")!;
            var port = said.Contains("port 2222", StringComparison.Ordinal) ? 2222 : 22;
            var failure = c.Text("kind") switch
            {
                "refused" => RemoteFailure.Refused,
                "no_answer" => RemoteFailure.NoAnswer,
                "not_found" => RemoteFailure.NotFound,
                "closed" => RemoteFailure.Closed,
                _ => RemoteFailure.Dropped,
            };
            Assert.AreEqual(Vectors.Pc(c.Text("words")!), ServerCheck.Unreached(c.Text("server")!, port, failure), said);
        }
        var words = checks.GetProperty("words");
        Assert.AreEqual(ServerCheck.Title, words.Text("title"));
        Assert.AreEqual(words.Text("not_root"), ServerCheck.NotRoot("ada"));
        Assert.AreEqual(Vectors.Pc(words.Text("unreached")!), ServerCheck.Unreached("203.0.113.9"));
        Assert.AreEqual(words.Text("no_answer"), ServerCheck.NoAnswer("203.0.113.9"));
        Assert.AreEqual(Vectors.Pc(words.Text("dropped_on_the_private_network")!),
                        ServerCheck.Unreached("100.64.0.9", 22, RemoteFailure.NoAnswer));
        // The known differences: the Mac's words name a console command and the owner's own key file.
        StringAssert.Contains(words.Text("host_key_changed"), "ssh-keygen -R");
        StringAssert.Contains(words.Text("key_refused"), "Choose its key");
        Assert.IsFalse(ServerCheck.HostKeyChanged("203.0.113.9", true).Contains("ssh-keygen", StringComparison.Ordinal));
        Assert.IsFalse(ServerCheck.KeyRefused("203.0.113.9").Contains("Choose", StringComparison.Ordinal));
        // A server with no key on record is not one whose key changed: under the rule of known servers, the PC lost it.
        Assert.AreEqual(ServerCheck.HostKeyUnknown("203.0.113.9", false),
                        ServerCheck.Failed("203.0.113.9", 22, "root", RemoteFailure.HostKeyUnknown, new RemoteLogin.AppKey(), false));
    }

    /// <summary>The C# error of each case of the file, built as the Swift writer built the Mac's.</summary>
    private static InstallError Error(string name) => name switch
    {
        "an installer's stop" => InstallError.Step("The plan", "Founderizer install stopped: Could not clone the Founderizer repository from its address: git did not finish. Check the address, then run the line again."),
        "a join's stop in the old brand" => InstallError.Step("Join the fleet", "Fleet join stopped:   the join code expired."),
        "a stop mark with no reason" => InstallError.Step("Join the fleet", "Founderizer join stopped:"),
        "a hub that serves another computer" => InstallError.Step("Wait for the link code", Installer.NotThisPcs),
        "a server that printed no user" => InstallError.Step(ServerCheck.Title, Installer.NoUser),
        "an address off the network" => InstallError.Step("Claim the hub", Founderizer.Core.OwnerPcKey.NotOnYourNetwork),
        "a refused code" => InstallError.Step("Claim the hub", Founderizer.Core.OwnerPcKey.CodeRefused),
        "a link not approved" => InstallError.Step("The private network", NetworkSignIn.NotApproved),
        "Tailscale not started" => InstallError.Step("The private network", NetworkSignIn.NotStarted),
        "a join that did not reach the checks" => InstallError.Step("Join the fleet", Installer.JoinNoChecks),
        "the systems of an install" => InstallError.Step(ServerCheck.Title, InstallPlan.HubSystems),
        "a program's own words" => InstallError.Step("The Founderizer code", "fatal: unable to access 'https://github.com/': timed out"),
        "a status with no words" => InstallError.Step("The plan", "The server answered 2."),
        "not root" => InstallError.NotRoot("ada"),
        "too long" => InstallError.TimedOut("Wait for the link code"),
        "no link code" => InstallError.NoClaimCode(),
        "no checklist" => InstallError.NoChecklist(),
        "the check stopped" => InstallError.CheckStopped("This server does not run systemd, and this install needs a full VPS that does."),
        "a sudo password" => InstallError.NeedsPassword(ServerCheck.PasswordNeed.Sudo),
        "an SSH password" => InstallError.NeedsPassword(ServerCheck.PasswordNeed.Ssh),
        "a step that cannot start" => InstallError.CannotStart("The hub gave no join line."),
        _ => throw new ArgumentException(name),
    };

    /// <summary>The stops whose words are the PC's own: the Mac's send the owner to a console ("Read its log on the
    /// server") or speak of the owner's own SSH keys, and the PC has neither (new words for set 8).</summary>
    private static readonly Dictionary<string, (string Mac, string Pc)> OwnStopWords = new()
    {
        ["no link code"] = ("Read its log on the server", "The installer did not print a link code for this PC. Try again."),
        ["an SSH password"] = ("SSH keys", "That server does not take this PC's SSH key, and asks for a password."),
    };

    /// <summary>A stop said, kept or named in another way than the Mac's: the record's kind decides a retry, and its
    /// kept words must be this app's own and never a server's.</summary>
    [TestMethod]
    public void Each_stop_is_said_kept_and_named_as_the_Macs()
    {
        foreach (var c in Reads.GetProperty("install_errors").EnumerateArray())
        {
            var at = c.Text("name")!;
            var error = Error(at);
            string Said(string name)
            {
                var mac = c.Text(name)!;
                if (!OwnStopWords.TryGetValue(at, out var own)) return Vectors.Pc(mac);
                StringAssert.Contains(mac, own.Mac, at);
                return own.Pc;
            }
            Assert.AreEqual(Said("description"), error.Description, at);
            Assert.AreEqual(Said("plain"), error.Plain("203.0.113.9"), at);
            Assert.AreEqual(Said("plain_with_no_host"), error.Plain(""), at);
            Assert.AreEqual(c.Text("stop"), InstallStops.Of(error).Name(), at);
            Assert.AreEqual(c.Text("cause"), InstallCauses.Of(error)?.Name(), at);
            Assert.AreEqual(c.Text("kept_words") is not null ? Said("kept_words") : null, InstallRecord.WordsOf(error, "203.0.113.9"), at);
        }
    }
}
