using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Text.Json;
using System.Threading.Tasks;
using Founderizer.Owner.Reads;
using Founderizer.Remote;
using Founderizer.Setup.Agents;
using Founderizer.Setup.Cloud;
using Founderizer.Setup.FirstRun;
using Founderizer.Setup.Install;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace Founderizer.Setup.Tests;

/// <summary>**The first run's and the agent setup's sentences and rules are the Mac's** (windows-app-plan-v2.md, 5.6 and
/// piece L4): each case of <c>app/vectors/setup-words.json</c> and <c>remote-password.json</c>, which FleetCore's own code
/// writes (<c>Tests/FleetCoreTests/SetupWordsVectorsTests.swift</c>), with "PC" where the Mac says "Mac".</summary>
[TestClass]
public sealed class SetupWordsVectorTests
{
    private static readonly JsonElement Words = Vectors.Read("setup-words.json");
    private static readonly JsonElement Password = Vectors.Read("remote-password.json");

    private static T Decoded<T>(JsonElement json, System.Text.Json.Serialization.Metadata.JsonTypeInfo<T> type) =>
        JsonSerializer.Deserialize(json.GetRawText(), type)!;

    private static string PageWord(AgentPage page) => page.Kind switch
    {
        AgentSetupPage.SignIn => "signIn",
        var kind => kind.ToString()[..1].ToLowerInvariant() + kind.ToString()[1..],
    };

    private static void Page(JsonElement expected, AgentPage actual, string where)
    {
        Assert.AreEqual(expected.Text("page"), PageWord(actual), where);
        Assert.AreEqual(expected.TryGetProperty("runtime", out var runtime) ? runtime.GetString() : null, actual.Runtime, where);
    }

    /// <summary>**The slider's sentences, the counts, the steps on Back's line, and the build page's rows.** Bug: a step
    /// whose risk names what the other step does, a count that says "1 servers", a page that shows the steps after a
    /// first run that opened on it with no name, or a bar that goes back when the install begins.</summary>
    [TestMethod]
    public void The_shape_the_steps_and_the_build_rows_are_the_Macs()
    {
        foreach (var step in Words.GetProperty("servers_steps").EnumerateArray())
        {
            var s = ServersSteps.FromRaw(step.Text("step"))!.Value;
            Assert.AreEqual(step.Text("fact"), s.Fact());
            Assert.AreEqual(step.Text("risk"), s.Risk());
            Assert.AreEqual(step.Text("means"), s.Means());
            Assert.AreEqual(step.Text("first_press"), s.FirstPress());
            Assert.AreEqual(step.GetProperty("managers_own_server").GetBoolean(), s.ManagersOwnServer());
            Assert.AreEqual(step.Text("words"), ServersSketch.Words(s));
        }
        foreach (var count in Words.GetProperty("fleet_counts").EnumerateArray())
        {
            var c = new FleetCount(count.GetProperty("servers").GetInt32(), count.GetProperty("macs").GetInt32());
            Assert.AreEqual((count.Text("server_words"), count.Text("words")), (c.ServerWords, c.Words));
        }
        CollectionAssert.AreEqual(Words.GetProperty("first_run_steps").Texts(), FirstRunSteps.Names.ToList());
        foreach (var of in Words.GetProperty("first_run_step_of").EnumerateArray())
            Assert.AreEqual(of.Text("step"), FirstRunSteps.Of(of.Text("page")!, of.GetProperty("named").GetBoolean())?.Name(),
                            $"{of.Text("page")} named {of.GetProperty("named")}");
        CollectionAssert.AreEqual(Words.GetProperty("manager_setup_steps").Texts(), ManagerSetupSteps.Names.ToList());
        foreach (var current in Words.GetProperty("manager_setup_current").EnumerateArray())
        {
            var page = Enum.Parse<AgentSetupPage>(current.Text("page")!, ignoreCase: true);
            Assert.AreEqual(current.GetProperty("current").GetInt32(), ManagerSetupSteps.Current(page), current.Text("page"));
        }
        var hubPlan = Words.GetProperty("hub_plan").Texts();
        var joinPlan = Words.GetProperty("join_plan").Texts();
        CollectionAssert.AreEqual(hubPlan, InstallPlan.Hub(new InstallTarget("server"), "", null).Steps.Select(s => s.Id).ToList());
        CollectionAssert.AreEqual(joinPlan, InstallPlan.Join(new InstallTarget("server"), "", "", null).Steps.Select(s => s.Id).ToList());
        var rows = new Dictionary<string, FleetBuildRow>
        {
            ["building"] = FleetBuildRow.Building(false, hubPlan), ["joining"] = FleetBuildRow.Building(true, hubPlan),
            ["waits for the hub"] = FleetBuildRow.WaitsForHub(joinPlan), ["starting after a build"] = FleetBuildRow.Starting(joinPlan, true),
            ["starting"] = FleetBuildRow.Starting(hubPlan, false), ["setting up"] = FleetBuildRow.SettingUp("Claude Code"),
            ["sign-in"] = FleetBuildRow.SignIn, ["ready"] = FleetBuildRow.Ready,
            ["installing"] = FleetBuildRow.Installing(InstallPhases.Of([], hubPlan)!, afterBuild: true),
        };
        foreach (var row in Words.GetProperty("build_rows").EnumerateArray())
        {
            var name = row.Text("name")!;
            var expected = row.GetProperty("row");
            var actual = rows[name];
            Assert.AreEqual(expected.Text("words"), actual.Words, name);
            Assert.AreEqual(expected.GetProperty("minutes").ValueKind == JsonValueKind.Null ? null : expected.GetProperty("minutes").GetInt32(), actual.Minutes, name);
            Assert.AreEqual(expected.GetProperty("owners_turn").GetBoolean(), actual.OwnersTurn, name);
            var parts = expected.GetProperty("parts");
            if (parts.ValueKind == JsonValueKind.Null) Assert.IsNull(actual.Parts, name);
            else CollectionAssert.AreEqual(parts.EnumerateArray().Select(p => p.GetDouble()).ToList(), actual.Parts!.ToList(), name);
        }
    }

    /// <summary>**A machine's sign-in, its line and its link, as the Mac reads them**: the link is opened only for the
    /// provider's own hosts, over HTTPS, with no port and no user. Bug: a link that a machine prints for a page of its
    /// own (another host, a port, plain HTTP) opened in the owner's browser; a sign-in that only waited for the owner
    /// said in orange; a stale reading taken for a sign-in.</summary>
    [TestMethod]
    public void The_sign_in_its_line_and_its_link_are_the_Macs_and_the_link_is_the_providers_own_only()
    {
        foreach (var one in Words.GetProperty("sign_ins").EnumerateArray())
        {
            var name = one.Text("name")!;
            var machine = Decoded(one.GetProperty("machine"), ReadsJson.Default.MachineStatus);
            var line = SignIn.Line(machine, working: false);
            var said = SignIn.Line(machine, working: false, alreadySaid: true);
            void Same(JsonElement e, SignInLine? l, string what)
            {
                if (e.ValueKind == JsonValueKind.Null) { Assert.IsNull(l, what); return; }
                Assert.AreEqual((Vectors.Pc(e.Text("says")!), e.GetProperty("warn").GetBoolean()), (l!.Says, l.Warn), what);
            }
            Same(one.GetProperty("line"), line, name);
            Same(one.GetProperty("line_already_said"), said, name + ", said already");
            Assert.AreEqual(one.Text("summary"), machine.Login?.Summary, name);
            Assert.AreEqual(one.Text("reason"), machine.Login?.Reason, name);
            Assert.AreEqual(one.Text("link"), machine.Login?.SignInUrl?.OriginalString, name);
            Assert.AreEqual(one.Text("device_code"), machine.Login?.DeviceCode, name);
            Assert.AreEqual(one.GetProperty("waits_for_code").GetBoolean(), machine.Login?.WaitsForCode ?? false, name);
            Assert.AreEqual(one.GetProperty("signed_in").GetBoolean(), AgentSetupFlow.SignedIn("claude", machine), name);
            Page(one.GetProperty("page"), AgentSetupFlow.Page("claude", null, machine, null), name);
            Assert.AreEqual(one.Text("stopped"), AgentSetupFlow.Stopped("claude", null, machine), name);
            // The page of the setup links nothing else than the reading's own link.
            var page = SignIn.Page(machine.Login?.Runtime ?? "claude", null, machine, null, null);
            Assert.AreEqual(one.Text("link"), page.Link?.OriginalString, name + ": the page's link");
            if (page.Link is { } shown) Assert.IsFalse(page.ToString().Contains(shown.OriginalString, StringComparison.Ordinal), name + ": its text names no link");
            if (page.ShownCode is { } code) Assert.IsFalse(page.ToString().Contains(code, StringComparison.Ordinal), name + ": its text names no code");
        }
        foreach (var code in Words.GetProperty("codes").EnumerateArray())
            Assert.AreEqual(code.Text("code"), MachineLogin.CodeOf(code.Text("given")!), code.Text("given"));
    }

    /// <summary>**The pages of an agent's setup from the server's job, and the words of a stop.** Bug: an install that
    /// only waited for the owner said as a failure, an offline install said with the system's code, a failed
    /// preparation of the other provider that keeps the owner waiting on its switch.</summary>
    [TestMethod]
    public void The_agent_setups_pages_and_words_of_a_stop_are_the_Macs()
    {
        foreach (var one in Words.GetProperty("setups").EnumerateArray())
        {
            var name = one.Text("name")!;
            var job = Decoded(one.GetProperty("job"), ReadsJson.Default.ServerJob);
            var switching = one.Text("switching_to");
            Page(one.GetProperty("page"), AgentSetupFlow.Page("claude", job, null, switching), name);
            Assert.AreEqual(one.Text("stopped"), AgentSetupFlow.Stopped("claude", job, null), name);
            Assert.AreEqual(one.Text("start_claude"), Start(AgentSetupFlow.StartOf("claude", "claude", job, null)), name);
            Assert.AreEqual(one.Text("start_codex"), Start(AgentSetupFlow.StartOf("codex", "claude", job, null)), name);
            var bar = AgentSetupFlow.InstallBar(job, onMac: false);
            var expected = one.GetProperty("bar");
            if (expected.ValueKind == JsonValueKind.Null) Assert.IsNull(bar, name);
            else
            {
                CollectionAssert.AreEqual(expected.GetProperty("steps").Texts(), bar!.Value.Steps.ToList(), name);
                var running = expected.GetProperty("running");
                Assert.AreEqual(running.ValueKind == JsonValueKind.Null ? null : running.GetInt32(), bar.Value.Running, name);
            }
        }
        CollectionAssert.AreEqual(Words.GetProperty("install_bar_no_job").Texts(), AgentSetupFlow.InstallBar(null, false)!.Value.Steps.ToList());
        foreach (var one in Words.GetProperty("blockers").EnumerateArray())
            Assert.AreEqual(one.Text("blocker"), AgentSetupFlow.Blocker(Decoded(one.GetProperty("verify"), Verification)), one.Text("name"));
        foreach (var one in Words.GetProperty("offline").EnumerateArray())
            Assert.AreEqual(one.Text("words"), AgentSetupFlow.Offline(one.Text("detail"), "codex", one.Text("server")), one.Text("detail"));
        Assert.AreEqual(Words.Text("installing"), AgentSetupFlow.Installing("Claude Code", "worker-2"));
        foreach (var one in Words.GetProperty("provider_names").EnumerateArray())
            Assert.AreEqual(one.Text("name"), SignIn.ProviderName(one.Text("runtime")!));
    }

    private static readonly System.Text.Json.Serialization.Metadata.JsonTypeInfo<MachineVerification> Verification = ReadsJson.Default.MachineVerification;

    private static string Start(AgentSetupFlow.Start start) => start.ToString()[..1].ToLowerInvariant() + start.ToString()[1..];

    /// <summary>**What the manager's first setup shows before its server's page, the hand-over of the first run, and the
    /// manager's name.** Bug: the slider asked again of a fleet whose first run kept a step; a manager put on the hub's
    /// own server before that server takes agents; a sign-in asked twice; a name with an accent sent to the installer.</summary>
    [TestMethod]
    public void The_managers_first_pages_the_handover_and_the_name_are_the_Macs()
    {
        foreach (var one in Words.GetProperty("manager_starts").EnumerateArray())
        {
            var name = one.Text("name")!;
            var servers = one.GetProperty("servers");
            var list = servers.ValueKind == JsonValueKind.Null ? null : Decoded(servers, ReadsJson.Default.ServerList);
            var start = ManagerSetupStart.Page(one.GetProperty("features").Texts(), one.GetProperty("named").GetBoolean(), list);
            var expected = one.GetProperty("start");
            var word = start switch
            {
                ManagerSetupStart.Name => "name", ManagerSetupStart.Servers => "servers", ManagerSetupStart.Sharing => "sharing",
                ManagerSetupStart.OnHub => "onHub", ManagerSetupStart.Server => "server", _ => "unread",
            };
            Assert.AreEqual(expected.Text("start"), word, name);
            if (start is ManagerSetupStart.Sharing sharing) Assert.AreEqual(expected.GetProperty("root_step").GetBoolean(), sharing.RootStep, name);
            if (start is ManagerSetupStart.OnHub hub) Assert.AreEqual(expected.Text("server"), hub.Machine, name);
            foreach (var page in one.GetProperty("pages").EnumerateArray())
                Page(page.GetProperty("page"), start.PageOf(false, page.Text("provider"), page.Text("place_on"), page.GetProperty("refused").GetBoolean()),
                     $"{name}: {page.Text("provider")} on {page.Text("place_on")}");
            Page(one.GetProperty("renaming"), start.PageOf(true, "claude", null, false), name + ", renaming");
        }
        foreach (var one in Words.GetProperty("handovers").EnumerateArray())
        {
            var actual = FirstRunHandover.Of(one.Text("chosen"), one.GetProperty("placed").GetBoolean(), one.Text("runtime"),
                                             one.GetProperty("installed_one_server").GetBoolean(), one.GetProperty("writes").GetBoolean(),
                                             one.GetProperty("asked").GetBoolean());
            var expected = one.GetProperty("handover");
            var word = actual switch
            {
                FirstRunHandover.Keep k => "keep " + k.Provider,
                FirstRunHandover.SignIn s => "sign_in " + s.Provider,
                _ => "none",
            };
            var said = expected.ValueKind == JsonValueKind.String ? expected.GetString()
                : expected.EnumerateObject().Select(p => p.Name + " " + p.Value.GetString()).Single();
            Assert.AreEqual(said, word, one.GetRawText());
        }
        foreach (var one in Words.GetProperty("manager_names").EnumerateArray())
        {
            Assert.AreEqual(one.Text("agent_name"), ManagerName.AgentName(one.Text("typed")!), one.Text("typed"));
            Assert.AreEqual(one.Text("shown"), ManagerName.Shown(one.Text("typed")!), one.Text("typed"));
        }
    }

    /// <summary>**The words of Start again**, with "PC" for "Mac". Bug: a row that names Founderizer's SSH key at Akamai,
    /// which keeps none, or a count of firewalls in the words of one.</summary>
    [TestMethod]
    public void The_words_of_start_again_are_the_Macs()
    {
        var words = Words.GetProperty("start_again");
        var fixedWords = words.GetProperty("fixed");
        Assert.AreEqual((fixedWords.Text("start"), fixedWords.Text("starting"), fixedWords.Text("press"), fixedWords.Text("still_costs")),
                        (StartAgain.Words.Start, StartAgain.Words.Starting, StartAgain.Words.Press, StartAgain.Words.StillCosts));
        foreach (var one in words.GetProperty("deleted_at").EnumerateArray())
            Assert.AreEqual(one.Text("words"), StartAgain.Words.DeletedAt(CloudProviders.FromRaw(one.Text("provider")!)!.Value));
        foreach (var one in words.GetProperty("firewalls").EnumerateArray())
        {
            var provider = CloudProviders.FromRaw(one.Text("provider")!)!.Value;
            var count = one.GetProperty("count").GetInt32();
            Assert.AreEqual(one.Text("words"), StartAgain.Words.Firewalls(count, provider));
            Assert.AreEqual(one.Text("made_for"), StartAgain.Words.MadeFor(count, provider));
            var servers = Enumerable.Repeat(new StartAgain.Server(provider, "1", "worker-1", CloudServerUse.Hub), count).ToList();
            Assert.AreEqual(one.Text("title"), StartAgain.Words.Title(new StartAgain.StepKind.Firewalls(provider, servers)));
        }
        foreach (var one in words.GetProperty("machines").EnumerateArray())
        {
            var names = one.GetProperty("names").Texts();
            Assert.AreEqual(one.Text("words"), StartAgain.Words.MachinesOf(names));
            Assert.AreEqual(one.Text("title"), StartAgain.Words.Title(new StartAgain.StepKind.MachinesStep(names.Count)));
        }
        Assert.AreEqual(words.Text("server_title"), StartAgain.Words.Title(new StartAgain.StepKind.ServerStep(new StartAgain.Server(CloudProvider.Hetzner, "1", "worker-1", CloudServerUse.Hub))));
        Assert.AreEqual(words.Text("app_title"), StartAgain.Words.Title(new StartAgain.StepKind.App()));
        foreach (var one in words.GetProperty("states").EnumerateArray())
            Assert.AreEqual(one.Text("words"), StartAgain.Words.Word(Enum.Parse<StartAgain.StepState>(one.Text("state")!, ignoreCase: true)));
        foreach (var one in words.GetProperty("details").EnumerateArray())
        {
            var server = new StartAgain.Server(CloudProviders.FromRaw(one.Text("provider")!)!.Value, "1", "worker-1",
                                               one.Text("use") == "hub" ? CloudServerUse.Hub : CloudServerUse.Agent, one.Text("type"));
            Assert.AreEqual(one.Text("detail"), StartAgain.Words.Detail(server));
        }
        foreach (var one in words.GetProperty("sentences").EnumerateArray())
            Assert.AreEqual(one.Text("sentence"), StartAgain.Words.Sentence(one.Text("words")!));
    }

    /// <summary>**The program that puts the app's key on a server with the password once is the Mac's, byte for byte, and
    /// the password goes only as the login and as the first line of the input.** Bug: a program that adds the key twice,
    /// changes the owner's own file's mode, or reads sudo's password from anywhere but its first line; a password in the
    /// program's text.</summary>
    [TestMethod]
    public async Task The_password_once_program_is_the_Macs_and_the_password_is_only_the_login_and_the_input()
    {
        var line = Password.Text("public_line")!;
        Assert.AreEqual(Password.Text("add_key"), PasswordOnce.AddKey(line));
        Assert.AreEqual(Password.Text("command"), PasswordOnce.Program(line));
        Assert.AreEqual((Password.Text("key_added"), Password.Text("sudo_mark"), Password.Text("key_works"), Password.Text("works")),
                        (PasswordOnce.KeyAdded, PasswordOnce.SudoMark, PasswordOnce.KeyWorks, PasswordOnce.WorksProgram));

        var remote = new StandInRemote((call, _) => call.Program == PasswordOnce.WorksProgram
            ? StandInRemote.Said(PasswordOnce.KeyWorks)
            : StandInRemote.Said($"{PasswordOnce.KeyAdded}\n{PasswordOnce.SudoMark}password"));
        var password = "correct horse".ToCharArray();
        var target = new InstallTarget("203.0.113.10", "admin", 22, true);
        var outcome = await PasswordOnce.RunAsync(remote, target, ServerCheck.PasswordNeed.Ssh, password, line);
        Assert.AreEqual(new PasswordOnce.Outcome.Ready(true), outcome);
        Assert.AreEqual("correct horse", new string(password), "the sudo of that user asks for it: the install that follows keeps it");
        Assert.IsInstanceOfType<RemoteLogin.PasswordOnce>(remote.Calls[0].Login);
        Assert.AreEqual(PasswordOnce.Program(line), remote.Calls[0].Program);
        Assert.AreEqual("correct horse\n", Encoding.UTF8.GetString(remote.Inputs[0]!));
        Assert.IsInstanceOfType<RemoteLogin.AppKey>(remote.Calls[1].Login, "the proof uses the app's key alone");
        Assert.IsTrue(remote.Calls.All(c => !c.Program.Contains("correct horse", StringComparison.Ordinal)));

        // A root user: nothing keeps the password.
        var root = new StandInRemote((call, _) => call.Program == PasswordOnce.WorksProgram
            ? StandInRemote.Said(PasswordOnce.KeyWorks) : StandInRemote.Said($"{PasswordOnce.KeyAdded}\n{PasswordOnce.SudoMark}root"));
        var once = "hunter22".ToCharArray();
        Assert.AreEqual(new PasswordOnce.Outcome.Ready(false), await PasswordOnce.RunAsync(root, new InstallTarget("203.0.113.10"), ServerCheck.PasswordNeed.Ssh, once, line));
        Assert.IsTrue(once.All(c => c == '\0'), "the password is cleared");

        // The refusals, in the PC's words.
        async Task<string> Refused(Func<RemoteCall, RemoteResult> answer, ServerCheck.PasswordNeed need = ServerCheck.PasswordNeed.Ssh)
        {
            var given = "hunter22".ToCharArray();
            var outcome = await PasswordOnce.RunAsync(new StandInRemote((c, _) => answer(c)), target, need, given, line);
            Assert.IsTrue(given.All(c => c == '\0'), "a refusal clears the password");
            return ((PasswordOnce.Outcome.Refused)outcome).Says;
        }
        Assert.AreEqual(ServerCheck.KeysOnly("203.0.113.10"), await Refused(_ => StandInRemote.Failed(RemoteFailure.LoginNotOffered)));
        Assert.AreEqual("203.0.113.10 did not take that password for admin.", await Refused(_ => StandInRemote.Failed(RemoteFailure.LoginRefused)));
        Assert.AreEqual(ServerCheck.NotRoot("admin"), await Refused(_ => StandInRemote.Said(PasswordOnce.SudoMark + "refused")));
        Assert.AreEqual("sudo on 203.0.113.10 did not take that password.",
                        await Refused(_ => StandInRemote.Said(PasswordOnce.SudoMark + "refused"), ServerCheck.PasswordNeed.Sudo));
        Assert.AreEqual("This PC could not add its key to admin's ~/.ssh/authorized_keys on 203.0.113.10.", await Refused(_ => StandInRemote.Said("nothing")));
        Assert.AreEqual("203.0.113.10 still asks for a password with this PC's key in admin's authorized_keys, so its SSH server reads keys from elsewhere.",
                        await Refused(c => c.Program == PasswordOnce.WorksProgram ? StandInRemote.Failed(RemoteFailure.LoginRefused)
                                                                                 : StandInRemote.Said($"{PasswordOnce.KeyAdded}\n{PasswordOnce.SudoMark}nopasswd")));
    }
}
