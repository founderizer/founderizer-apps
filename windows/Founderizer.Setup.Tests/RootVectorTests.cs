using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.Json;
using Founderizer.Owner.Reads;
using Founderizer.Setup.Install;
using Founderizer.Setup.RootJobs;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace Founderizer.Setup.Tests;

/// <summary>**The root jobs of the PC are the Mac's** (windows-app-plan-v2.md, 5.6, piece L6): each program that the PC runs
/// as root equals app/vectors/remote-root.json and remote-vault.json byte for byte, and each reading of a server and of an
/// answer gives what the Mac's gives. Both files come from FleetCore's own code (RootVectorsTests.swift and
/// RemoteVaultVectorsTests.swift). The bug that each of these tests catches is one changed letter of a program that runs as
/// root on the owner's servers, or an answer that the PC reads in another way than the Mac.</summary>
[TestClass]
public sealed class RootVectorTests
{
    private static readonly JsonElement Root = Vectors.Read("remote-root.json");
    private static readonly JsonElement Vault = Vectors.Read("remote-vault.json");
    private static readonly InstallTarget ThroughSudo = new("100.80.1.7", "admin", 2222, BecomeRoot: true);

    private static string Sudo(string program) => InstallPlan.Command(program, ThroughSudo, Runs.Root);

    /// <summary>The Mac's value (the vector's) is the expected one, and the PC's the actual one. A helper, so that the
    /// analyzer's rule for a constant in the actual place (MSTEST0017) reads the PC's constants as what they are here: the
    /// values under test.</summary>
    private static void Same<T>(T macs, T pcs, string? what = null) => Assert.AreEqual(macs, pcs, what);

    private static ServerEntry Entry(JsonElement row) => JsonSerializer.Deserialize(row, ReadsJson.Default.ServerEntry)!;

    private static JoinState? Join(JsonElement join) =>
        join.ValueKind == JsonValueKind.Null ? null : JsonSerializer.Deserialize(join, ReadsJson.Default.JoinState);

    private static int? IntOrNull(JsonElement value) => value.ValueKind == JsonValueKind.Null ? null : value.GetInt32();

    /// <summary>A number of a reading (a port, a uid), as the Mac's <c>Int</c>: 64 bits.</summary>
    private static long? LongOrNull(JsonElement value) => value.ValueKind == JsonValueKind.Null ? null : value.GetInt64();

    private static Dictionary<string, long> Uids(JsonElement uids) => uids.EnumerateObject().ToDictionary(u => u.Name, u => u.Value.GetInt64());

    // ------------------------------------------------------------ the access line

    [TestMethod]
    public void The_access_line_is_the_Macs()
    {
        var access = Root.GetProperty("access");
        var line = access.Text("public_line")!;
        Assert.AreEqual(access.GetProperty("program").Text("program"), AccessLine.Program(line));
        Assert.AreEqual(access.GetProperty("program").Text("through_sudo"), Sudo(AccessLine.Program(line)));
        Same(access.Text("root_keys"), AccessLine.RootKeys);
        Same(access.Text("in_place"), AccessLine.InPlaceWord);
        foreach (var answer in access.GetProperty("outputs").EnumerateArray())
            Assert.AreEqual(answer.GetProperty("in_place").GetBoolean(), AccessLine.IsInPlace(answer.Text("output")!), answer.ToString());
    }

    // ------------------------------------------------------------ the join's hardening

    [TestMethod]
    public void The_hardening_program_is_the_Macs()
    {
        var hardening = Root.GetProperty("hardening");
        Assert.AreEqual(hardening.GetProperty("program").Text("program"), Hardening.Program());
        Assert.AreEqual(hardening.GetProperty("program").Text("through_sudo"), Sudo(Hardening.Program()));
        Same(hardening.Text("started"), Hardening.Started);
        Same(hardening.GetProperty("join_grace").GetDouble(), RootJob.JoinGrace);
        Same(hardening.GetProperty("tries").GetProperty("wait").GetDouble(), JobTries.Wait);
        Same(hardening.GetProperty("tries").GetProperty("most").GetInt32(), JobTries.Most);
    }

    [TestMethod]
    public void A_server_reads_for_hardening_as_on_the_Mac()
    {
        foreach (var read in Root.GetProperty("hardening").GetProperty("readings").EnumerateArray())
        {
            var entry = Entry(read.GetProperty("server"));
            Assert.AreEqual(read.GetProperty("applies").GetBoolean(), Hardening.Applies(entry), read.Text("name"));
            var reading = Hardening.ReadingOf(entry, Join(read.GetProperty("join")), read.GetProperty("time").GetDouble());
            Assert.AreEqual(read.Text("reading"), reading.ToString().ToLowerInvariant(), read.Text("name"));
        }
    }

    [TestMethod]
    public void A_round_does_with_a_server_what_the_Mac_does()
    {
        foreach (var step in Root.GetProperty("hardening").GetProperty("steps").EnumerateArray())
        {
            var memory = step.GetProperty("memory");
            var kept = new SweepMemory(memory.GetProperty("failures").GetInt32(), memory.GetProperty("last").GetDouble(),
                                       memory.Text("reason")!, memory.GetProperty("settled").GetBoolean());
            JobTries? unreached = step.GetProperty("unreached") is { ValueKind: JsonValueKind.Object } t
                ? new JobTries(t.GetProperty("failures").GetInt32(), t.GetProperty("last").GetDouble(), t.Text("reason")!) : null;
            var reading = Enum.Parse<SweepReading>(step.Text("reading")!, ignoreCase: true);
            var gave = RootJob.Step(reading, kept, step.GetProperty("seen_before").GetBoolean(), step.GetProperty("now").GetDouble(), unreached);
            Assert.AreEqual(step.Text("step"), gave.ToString().ToLowerInvariant(), step.Text("name"));
        }
    }

    [TestMethod]
    public void A_runs_output_reads_as_on_the_Mac()
    {
        foreach (var example in Root.GetProperty("hardening").GetProperty("outcomes").EnumerateArray())
        {
            var (word, said) = Hardening.Outcome(example.Text("output")!) switch
            {
                SweepOutcome.Holds => ("holds", null),
                SweepOutcome.LeftAsItIs => ("left_as_it_is", null),
                SweepOutcome.Failed failed => ("failed", (string?)failed.Said),
                SweepOutcome.NotStarted missed => ("not_started", missed.Said),
                _ => ("?", null),
            };
            Assert.AreEqual(example.Text("outcome"), word, example.Text("output"));
            if (example.TryGetProperty("said", out var expected)) Assert.AreEqual(expected.GetString(), said, example.Text("output"));
        }
    }

    // ------------------------------------------------------------ the browser parts

    private static List<BrowserPorts> PortRows(JsonElement rows) =>
        rows.EnumerateArray().Select(r => new BrowserPorts(r.Text("user")!, r.GetProperty("devtools").GetInt64(), r.GetProperty("screen").GetInt64())).ToList();

    [TestMethod]
    public void The_contracts_texts_are_the_Macs()
    {
        var browser = Root.GetProperty("browser");
        var texts = browser.GetProperty("texts");
        Same(texts.Text("unit"), Browser.UnitText);
        Same(texts.Text("dropin"), Browser.DropinText);
        Same(texts.Text("default"), Browser.DefaultText);
        Same(texts.Text("origin"), Browser.OriginText);
        Same(texts.Text("fixed"), Browser.FixedText);
        Same(texts.Text("source"), Browser.SourceText);
        Assert.AreEqual(texts.Text("policy"), Browser.PolicyText);
        Same(texts.Text("key"), Browser.KeyData);
        Assert.AreEqual(texts.Text("empty_table"), Browser.EmptyTable);
        Same(browser.Text("started"), Browser.Started);
        CollectionAssert.AreEqual(browser.GetProperty("packages").Texts(), Browser.Packages.ToList());
        CollectionAssert.AreEqual(browser.GetProperty("kept_packages").Texts(), Browser.KeptPackages.ToList());
        CollectionAssert.AreEqual(browser.GetProperty("sites").Texts(), Browser.Sites.ToList());
        CollectionAssert.AreEqual(browser.GetProperty("key_sites").Texts(), Browser.KeySites.ToList());
        var parts = browser.GetProperty("parts").EnumerateObject().ToDictionary(p => p.Name, p => p.Value.GetString()!);
        CollectionAssert.AreEquivalent(parts.ToList(), Browser.Parts.ToList());
    }

    [TestMethod]
    public void The_ports_and_the_table_are_the_Macs()
    {
        var browser = Root.GetProperty("browser");
        foreach (var example in browser.GetProperty("tables").EnumerateArray())
        {
            var rows = PortRows(example.GetProperty("rows"));
            var uids = Uids(example.GetProperty("uids"));
            Assert.AreEqual(example.Text("ports_text"), Browser.PortsText(rows), example.Text("name"));
            Assert.AreEqual(example.Text("table"), Browser.Table(rows, uids, LongOrNull(example.GetProperty("broker")), example.GetProperty("worker").GetInt64()), example.Text("name"));
        }
        foreach (var example in browser.GetProperty("assign").EnumerateArray())
            CollectionAssert.AreEqual(PortRows(example.GetProperty("rows")),
                                      Browser.Assign(PortRows(example.GetProperty("current")), example.GetProperty("wanted").Texts()).ToList(),
                                      example.ToString());
    }

    /// <summary>**The rules that hold a reading's ports and its worker user are the Mac's** (app/vectors/server-browser-ports.json,
    /// made by the Mac's own ServerBrowserVectorsTests.swift, 24 November 2026): a reading's row with a port outside 9300-9399
    /// or 5910-5999, or with a port or a user that an earlier row has, is no row; no table names a port outside those ranges;
    /// and the worker user is the server service's own, <c>fleet</c>, with a uid that is not 0, not the broker's and no
    /// agent's. Bugs: a broken-in hub's reading of port 22 for an agent (or of 65558, which a 16-bit number reads as 22)
    /// makes the step write the table's rules for that port; a cloud image's login user, or the uid of an agent's user, gets
    /// every agent's screen port and the live proof's folder.</summary>
    [TestMethod]
    public void The_rules_of_a_readings_ports_and_worker_user_are_the_Macs()
    {
        var ports = Vectors.Read("server-browser-ports.json");
        var assign = ports.GetProperty("assign").EnumerateArray().ToList();
        var tables = ports.GetProperty("table").EnumerateArray().ToList();
        var workers = ports.GetProperty("worker").EnumerateArray().ToList();
        Assert.IsTrue(assign.Count >= 9 && tables.Count >= 16 && workers.Count >= 15, "the Mac's cases of 24 November 2026");
        foreach (var example in assign)
            CollectionAssert.AreEqual(PortRows(example.GetProperty("rows")),
                                      Browser.Assign(PortRows(example.GetProperty("current")), example.GetProperty("wanted").Texts()).ToList(),
                                      example.Text("what"));
        foreach (var example in tables)
            Assert.AreEqual(example.GetProperty("table") is { ValueKind: JsonValueKind.String } table ? table.GetString() : null,
                            Browser.Table(PortRows(example.GetProperty("rows")), Uids(example.GetProperty("uids")),
                                          LongOrNull(example.GetProperty("broker")), example.GetProperty("worker").GetInt64()),
                            example.Text("what"));
        foreach (var example in workers)
            Assert.AreEqual(example.GetProperty("fits").GetBoolean(),
                            Browser.WorkerFits(example.Text("user")!, example.GetProperty("uid").GetInt64(), Uids(example.GetProperty("uids")),
                                               LongOrNull(example.GetProperty("broker"))),
                            example.Text("what"));
    }

    private static RootServer RootOf(JsonElement row) => RootServer.Of(Entry(row), row);

    [TestMethod]
    public void A_round_finds_the_work_that_the_Mac_finds()
    {
        foreach (var example in Root.GetProperty("browser").GetProperty("works").EnumerateArray())
        {
            var name = example.Text("name");
            var server = RootOf(example.GetProperty("server"));
            var agents = example.GetProperty("agents").EnumerateArray().Select(a => new BrowserAgent(a.Text("name")!, a.GetProperty("can").Texts())).ToList();
            var tasks = example.GetProperty("tasks").EnumerateArray().Select(t => new BrowserTask(t.Text("owner")!, t.Text("state")!,
                t.GetProperty("works") is { ValueKind: JsonValueKind.True or JsonValueKind.False } w ? w.GetBoolean() : null)).ToList();
            var wanted = example.GetProperty("wanted");
            var found = Browser.Wanted(server.Entry, server.Users, agents);
            Assert.AreEqual(wanted.ValueKind == JsonValueKind.Null ? null : string.Join(" ", wanted.Texts()),
                            found is null ? null : string.Join(" ", found), name + ": the wanted users");
            var work = Browser.WorkFor(server, agents, tasks, Join(example.GetProperty("join")), example.GetProperty("time").GetDouble());
            CheckWork(example.GetProperty("work"), work, name!);
        }
    }

    private static void CheckWork(JsonElement expected, BrowserWork? work, string name)
    {
        if (expected.ValueKind == JsonValueKind.Null) { Assert.IsNull(work, name); return; }
        if (expected.ValueKind == JsonValueKind.String)
        {
            Assert.AreEqual(expected.GetString(), work switch { BrowserWork.Nothing => "nothing", BrowserWork.Remove => "remove", _ => "?" }, name);
            return;
        }
        var install = expected.GetProperty("install");
        Assert.IsInstanceOfType<BrowserWork.Install>(work, name);
        var want = ((BrowserWork.Install)work!).Want;
        CollectionAssert.AreEqual(PortRows(install.GetProperty("rows")), want.Rows.ToList(), name);
        Assert.AreEqual(install.Text("table"), want.Table, name);
        CollectionAssert.AreEquivalent(Uids(install.GetProperty("uids")).ToList(), want.Uids.ToList(), name);
        Assert.AreEqual(LongOrNull(install.GetProperty("broker")), want.Broker, name);
        Assert.AreEqual(install.Text("worker"), want.Worker, name);
        Assert.AreEqual(install.GetProperty("worker_id").GetInt64(), want.WorkerId, name);
        Assert.AreEqual(install.Text("digest"), want.Digest, name);
    }

    private static BrowserWork WorkOf(JsonElement work)
    {
        if (work.ValueKind == JsonValueKind.String) return work.GetString() == "remove" ? new BrowserWork.Remove() : new BrowserWork.Nothing();
        var install = work.GetProperty("install");
        return new BrowserWork.Install(new BrowserWant(
            PortRows(install.GetProperty("rows")), install.Text("table")!,
            Uids(install.GetProperty("uids")), LongOrNull(install.GetProperty("broker")), install.Text("worker")!,
            install.GetProperty("worker_id").GetInt64()));
    }

    [TestMethod]
    public void The_browser_programs_are_the_Macs()
    {
        var programs = Root.GetProperty("browser").GetProperty("programs").EnumerateArray().ToList();
        Assert.IsTrue(programs.Count >= 3, "an install with a broker, an install of the next want, and the removal");
        foreach (var example in programs)
        {
            var work = WorkOf(example.GetProperty("work"));
            Assert.AreEqual(example.GetProperty("program").Text("program"), Browser.Program(work), example.Text("name"));
            Assert.AreEqual(example.GetProperty("program").Text("through_sudo"), Sudo(Browser.Program(work)), example.Text("name"));
        }
    }

    [TestMethod]
    public void A_browser_runs_output_reads_as_on_the_Mac()
    {
        foreach (var example in Root.GetProperty("browser").GetProperty("outcomes").EnumerateArray())
        {
            var (word, said) = Browser.Outcome(example.Text("output")!) switch
            {
                BrowserOutcome.StepStarted started => ("started", started.Last),
                BrowserOutcome.StepRuns runs => ("running", runs.Last),
                BrowserOutcome.Failed failed => ("failed", failed.Said),
                BrowserOutcome.NotStarted missed => ("not_started", missed.Said),
                _ => ("?", ""),
            };
            Assert.AreEqual(example.Text("outcome"), word, example.Text("output"));
            Assert.AreEqual(example.Text("said"), said, example.Text("output"));
        }
    }

    // ------------------------------------------------------------ the vault

    [TestMethod]
    public void The_vaults_install_is_the_Macs()
    {
        foreach (var install in Vault.GetProperty("installs").EnumerateArray())
        {
            // The vector's bridge is this build's keys of the Mac app: the PC's keys are the same ones, and its test gives them as
            // the Mac's vector names them.
            var keys = Vault.GetProperty("bridges").EnumerateArray().Single(b => b.Text("name") == "this build's keys").Text("keys")!;
            var program = VaultInstall.Program(install.Text("owner_key")!, install.GetProperty("keep_owner").GetBoolean(), keys);
            Assert.AreEqual(install.Text("program"), program, install.Text("name"));
            if (program is not null) Assert.AreEqual(install.Text("through_sudo"), Sudo(program), install.Text("name"));
        }
        foreach (var bridge in Vault.GetProperty("bridges").EnumerateArray())
            Assert.AreEqual(bridge.Text("bridge"), VaultInstall.Bridge(bridge.Text("keys")!), bridge.Text("name"));
        Same(Vault.Text("root_kit"), VaultInstall.RootKit);
        Same(Vault.Text("hub_kit"), InstallPlan.HubKit);
        Same(Vault.Text("broker_config"), VaultInstall.BrokerConfig);
    }

    [TestMethod]
    public void The_installs_answer_reads_as_on_the_Mac()
    {
        foreach (var example in Vault.GetProperty("installed").EnumerateArray())
        {
            var answer = example.GetProperty("answer");
            var gave = VaultInstall.Installed(example.Text("output")!);
            switch (answer.ValueKind == JsonValueKind.Null ? "null" : answer.Text("kind"))
            {
                case "null": Assert.IsNull(gave, example.Text("output")); break;
                case "installed":
                    Assert.AreEqual(new VaultInstalled.Ready(answer.Text("recipient")!, answer.Text("fleet")!), gave, example.Text("output"));
                    break;
                case "refused": Assert.AreEqual(new VaultInstalled.Refused(answer.Text("says")!), gave, example.Text("output")); break;
                default: Assert.AreEqual(new VaultInstalled.OtherOwner(), gave, example.Text("output")); break;
            }
        }
    }

    [TestMethod]
    public void The_reads_of_a_servers_vault_key_are_the_Macs()
    {
        Same(Vault.GetProperty("read_broker_key").Text("program"), VaultPins.ReadBrokerKey);
        Assert.AreEqual(Vault.GetProperty("read_broker_key").Text("through_sudo"), Sudo(VaultPins.ReadBrokerKey));
        Same(Vault.GetProperty("read_mac_vault_key").Text("program"), VaultPins.ReadMacVaultKey);
        Assert.AreEqual(Vault.GetProperty("read_mac_vault_key").Text("as_login"), InstallPlan.Command(VaultPins.ReadMacVaultKey, ThroughSudo with { BecomeRoot = false }, Runs.Root));
        foreach (var example in Vault.GetProperty("broker_keys").EnumerateArray())
            Assert.AreEqual(example.Text("key"), VaultPins.BrokerKey(example.Text("output")!), example.Text("output"));
    }

    /// <summary>The bug: a root job takes a record's user that is not root (whose forced command prints what it likes), or
    /// reaches a kept server at a public address that lets no SSH in.</summary>
    [TestMethod]
    public void A_root_job_reaches_a_server_as_the_Mac_does()
    {
        static InstallTarget? TargetOf(JsonElement value) => value.ValueKind == JsonValueKind.Null
            ? null
            : new InstallTarget(value.Text("host")!, value.Text("user")!, value.GetProperty("port").GetInt32(), value.GetProperty("become_root").GetBoolean());
        foreach (var example in Root.GetProperty("targets").EnumerateArray())
        {
            var entry = Entry(JsonDocument.Parse("{\"name\":\"app-1\",\"hub\":false,\"joined\":true,\"agents\":[],\"available\":true,\"why\":[],\"address\":\"" +
                                                 example.Text("address") + "\"}").RootElement);
            var record = example.GetProperty("record") is { ValueKind: JsonValueKind.Object } r
                ? new MachineReach(r.Text("address"), r.Text("user"), IntOrNull(r.GetProperty("port")))
                : null;
            Assert.AreEqual(TargetOf(example.GetProperty("target")),
                            ServerRecords.Target(entry, TargetOf(example.GetProperty("kept")), record, example.GetProperty("root_only").GetBoolean()),
                            example.Text("name"));
        }
    }

    /// <summary>The bug: this PC takes a host for another device of its Tailscale than the Mac would (a first label that two
    /// nodes share, a name with its last dot), reads a Linux server as a Mac by the hub's word alone, or lets an update move a
    /// pin that it holds.</summary>
    [TestMethod]
    public void The_vaults_trust_rules_are_the_Macs()
    {
        var tailnet = Vault.GetProperty("tailnet");
        var status = tailnet.Text("status");
        foreach (var example in tailnet.GetProperty("hosts").EnumerateArray())
        {
            var host = example.Text("host")!;
            Assert.AreEqual(example.Text("node"), TailnetNodes.Node(host, status), host);
            Assert.AreEqual(example.Text("device"), TailnetNodes.DeviceOf(host, status), host);
            var os = example.GetProperty("os");
            Assert.AreEqual(os.ValueKind == JsonValueKind.Null ? null : string.Join(",", os.Texts()),
                            TailnetNodes.Peer(host, status) is { } peer ? string.Join(",", peer.Os.Order(StringComparer.Ordinal)) : null, host);
        }
        foreach (var example in Vault.GetProperty("hub_machine_stops").EnumerateArray())
        {
            var hub = new Uri(example.Text("hub")!);
            string? Pc(string name) => example.Text(name) is { } words ? Vectors.Pc(words) : null;
            Assert.AreEqual(Pc("stop"), VaultInstall.HubMachineStop(example.Text("host")!, hub, example.Text("machine")!, status), example.ToString());
            Assert.AreEqual(Pc("stop_without_tailscale"), VaultInstall.HubMachineStop(example.Text("host")!, hub, example.Text("machine")!, null),
                            example.ToString());
        }
        foreach (var example in Vault.GetProperty("trust_reads").EnumerateArray())
        {
            var read = VaultPins.ReadOf(example.Text("kind"), example.GetProperty("os").Texts().ToHashSet(StringComparer.Ordinal),
                                        example.Text("user")!, example.GetProperty("kept").GetBoolean());
            Assert.AreEqual(example.Text("read"), read?.ToString().ToLowerInvariant(), example.ToString());
        }
        foreach (var example in Vault.GetProperty("pin_refusals").EnumerateArray())
            Assert.AreEqual(example.Text("refusal") is { } words ? Vectors.Pc(words) : null,
                            VaultInstall.PinRefusal(example.Text("printed")!, example.Text("held"), example.GetProperty("set_up").GetBoolean()),
                            example.ToString());
    }

    [TestMethod]
    public void The_proof_read_is_the_Macs()
    {
        var proof = Vault.GetProperty("proof");
        Same(proof.Text("file"), OwnerKeyProof.ProofFile);
        foreach (var example in proof.GetProperty("paths").EnumerateArray())
            Assert.AreEqual(example.Text("path"), OwnerKeyProof.Path(example.Text("said")), example.Text("said"));
        foreach (var example in proof.GetProperty("programs").EnumerateArray())
        {
            var program = OwnerKeyProof.Program(example.Text("path")!);
            Assert.AreEqual(example.Text("program"), program, example.Text("path"));
            Assert.AreEqual(example.Text("as_login"), InstallPlan.Command(program, ThroughSudo, Runs.Login), example.Text("path"));
            Assert.AreEqual(example.Text("through_sudo"), Sudo(program), example.Text("path"));
        }
        foreach (var example in proof.GetProperty("values").EnumerateArray())
            Assert.AreEqual(example.Text("value"), OwnerKeyProof.Value(example.Text("output")!), example.Text("output"));
    }
}
