using System;
using System.Text;
using System.Text.Json.Nodes;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace Founderizer.Core.Tests;

/// <summary>The decoders refuse what the Swift decoders refuse, and take what they take: a missing or null field that is
/// not optional, a number as text, two rows with one id, another schema, generation, agent or task, and a body over its
/// cap. A field that this side does not know is skipped.</summary>
[TestClass]
public sealed class DecoderTests
{
    private static JsonObject Need(long id) => new()
    {
        ["id"] = id, ["title"] = "Pick one", ["why"] = "w", ["todo"] = "t", ["raised"] = 1.5, ["by"] = "manager",
        ["answer"] = null, ["options"] = new JsonArray("A", "B"), ["talk"] = new JsonArray(),
    };

    private static JsonObject Head(long id) => new()
    {
        ["id"] = id, ["title"] = "Task", ["state"] = "working", ["owner"] = "vps", ["requester"] = "manager",
        ["attempt"] = 1, ["created"] = 1.0, ["goal"] = null, ["stalled_since"] = null,
    };

    private static JsonObject Snapshot() => new()
    {
        ["schema_version"] = 1, ["db"] = "gen", ["time"] = 100.25, ["manager_warning"] = null,
        ["ui_features"] = new JsonArray("mobile", "live_changes", "direct_chat"),
        ["agents"] = new JsonArray(new JsonObject
        {
            ["name"] = "manager", ["role"] = "manager", ["runtime"] = "claude", ["open_tasks"] = 2,
            ["usage"] = new JsonArray(new JsonObject { ["label"] = "5 hours", ["used_percent"] = 41.5, ["resets_at"] = 9.0 }),
            ["last"] = new JsonObject { ["ts"] = 3.0, ["side"] = "agent", ["preview"] = "Done." },
            ["limit"] = null, ["a field of a later hub"] = new JsonObject(),
        }),
        ["needs"] = new JsonArray(Need(1)),
        ["answered_needs"] = new JsonArray(Need(2)),
        ["tasks"] = new JsonArray(Head(1)),
        ["recent"] = new JsonArray(Head(2)),
        ["holds"] = new JsonArray(new JsonObject { ["id"] = 1, ["task"] = 1, ["kind"] = "pause", ["state"] = "requested", ["attempt"] = 1 }),
        ["outcomes"] = new JsonArray(),
        ["counts"] = new JsonObject { ["tasks_open"] = 1, ["needs_open"] = 1, ["messages"] = 0, ["reports"] = 0 },
        ["token"] = "boot.1.2",
    };

    private static byte[] Bytes(JsonNode node) => Encoding.UTF8.GetBytes(node.ToJsonString());

    private static void Refused(Action decode, string why)
    {
        var e = Expect.Hub(decode);
        Assert.AreEqual(HubErrorKind.InvalidResponse, e.Kind, why);
        Assert.IsNotNull(e.Read, why);
    }

    [TestMethod]
    public void TheSnapshotReadsWithItsTokenAndItsFeatures()
    {
        var s = HubDecode.Snapshot(Bytes(Snapshot()));
        Assert.AreEqual("gen", s.Db);
        Assert.AreEqual(41.5, s.Agents[0].Usage[0].UsedPercent);
        Assert.AreEqual("boot", s.LiveToken!.Boot);
        Assert.IsTrue(s.Offers(LiveChanges.Feature));
        Assert.IsTrue(s.CanChat("manager"));
        Assert.IsFalse(s.CanChat("nobody"));
        Assert.AreEqual(2, s.Needs[0].Choices.Count);
        Assert.IsTrue(s.Needs[0].IsOpen);
    }

    [TestMethod]
    public void AFieldThatIsNotOptionalMustBeThereAndNotNull()
    {
        foreach (var (path, value) in new (string, JsonNode?)[] { ("runtime", null), ("open_tasks", "2"), ("role", 5) })
        {
            var s = Snapshot();
            s["agents"]![0]![path] = value;
            Refused(() => HubDecode.Snapshot(Bytes(s)), path);
        }
        var missing = Snapshot();
        missing["agents"]![0]!.AsObject().Remove("usage");
        Refused(() => HubDecode.Snapshot(Bytes(missing)), "usage missing");
        var noNeeds = Snapshot();
        noNeeds.Remove("needs");
        Refused(() => HubDecode.Snapshot(Bytes(noNeeds)), "needs missing");
        // An optional one may be absent or null.
        var older = Snapshot();
        older.Remove("token");
        older.Remove("answered_needs");
        older.Remove("counts");
        older["agents"]![0]!.AsObject().Remove("last");
        Assert.IsNull(HubDecode.Snapshot(Bytes(older)).LiveToken);
    }

    [TestMethod]
    public void TheSnapshotsOwnRulesHold()
    {
        var schema = Snapshot();
        schema["schema_version"] = 2;
        Refused(() => HubDecode.Snapshot(Bytes(schema)), "schema");
        var empty = Snapshot();
        empty["db"] = "";
        Refused(() => HubDecode.Snapshot(Bytes(empty)), "db");
        var agents = Snapshot();
        agents["agents"]!.AsArray().Add(agents["agents"]![0]!.DeepClone());
        Refused(() => HubDecode.Snapshot(Bytes(agents)), "two agents");
        var needs = Snapshot();
        needs["needs"]!.AsArray().Add(Need(1));
        Refused(() => HubDecode.Snapshot(Bytes(needs)), "two needs");
        var recent = Snapshot();
        recent["recent"]!.AsArray().Add(Head(2));
        Refused(() => HubDecode.Snapshot(Bytes(recent)), "two recent");
        var secret = Snapshot();
        secret["needs"]![0]!["secret"] = "a key";
        Refused(() => HubDecode.Snapshot(Bytes(secret)), "a secret that is no object");
        Refused(() => HubDecode.Snapshot(new byte[HubDecode.SnapshotLimit + 1]), "too large");
        Refused(() => HubDecode.Snapshot("[]"u8), "not an object");
        Refused(() => HubDecode.Snapshot("null"u8), "null");
    }

    [TestMethod]
    public void ASecretRequestIsReadLeniently()
    {
        var s = Snapshot();
        s["needs"]![0]!["kind"] = "secret";
        s["needs"]![0]!["secret"] = new JsonObject
        {
            ["kind"] = "something new", ["env"] = "lower_case", ["site"] = "https://example.com/login",
            ["give"] = new JsonObject { ["vps"] = "use", ["dev"] = "write" }, ["saved"] = "not a reference",
        };
        var secret = HubDecode.Snapshot(Bytes(s)).Needs[0].Secret!;
        Assert.AreEqual("api_key", secret.Kind);
        Assert.IsNull(secret.Env);
        Assert.AreEqual("https://example.com/login", secret.Site);
        Assert.AreEqual(1, secret.Give.Count);
        Assert.AreEqual("use", secret.Give["vps"]);
        Assert.IsNull(secret.Saved);
        Assert.IsTrue(HubDecode.Snapshot(Bytes(s)).Needs[0].AsksForSecret);
    }

    private static JsonObject ChatPage() => new()
    {
        ["db"] = "gen", ["agent"] = "manager", ["cursor"] = 5.5,
        ["items"] = new JsonArray(
            new JsonObject { ["kind"] = "message", ["ts"] = 1.0, ["id"] = "0b5f6c8e-1111-4222-8333-444455556666",
                             ["text"] = "hi", ["client"] = "pc", ["read_at"] = null, ["answer_to"] = 3 },
            new JsonObject { ["kind"] = "report", ["ts"] = 2.0, ["id"] = 17, ["text"] = "Done", ["about"] = "T-1",
                             ["pushed"] = true,
                             ["attachments"] = new JsonArray(new JsonObject
                             {
                                 ["id"] = 4, ["name"] = "a.png", ["mime"] = "image/png", ["size"] = 3,
                                 ["sha256"] = new string('a', 64), ["created"] = 1.0, ["kept"] = null,
                             })
                           }),
    };

    [TestMethod]
    public void AChatPageKnowsAMessageByItsTextIdAndAReportByItsNumber()
    {
        var page = HubDecode.ChatPage(Bytes(ChatPage()), "gen", "manager");
        Assert.AreEqual("0b5f6c8e-1111-4222-8333-444455556666", page.Items[0].Key);
        Assert.AreEqual("17", page.Items[1].Key);
        Assert.AreEqual("report-17", page.Items[1].Id);
        Assert.AreEqual(0, page.Items[0].Attachments.Count);
        Assert.AreEqual(1, page.Items[1].Attachments.Count);
        Assert.IsTrue(page.Items[1].Attachments[0].IsValid);
        Assert.IsTrue(page.Items[1].IsPushed);
        Assert.AreEqual(3, page.Items[0].AnswerTo);
    }

    [TestMethod]
    public void AChatPageOfAnotherAgentOrGenerationOrWithAStrangeItemIsRefused()
    {
        Refused(() => HubDecode.ChatPage(Bytes(ChatPage()), "other", "manager"), "generation");
        Refused(() => HubDecode.ChatPage(Bytes(ChatPage()), "gen", "vps"), "agent");
        var kind = ChatPage();
        kind["items"]![0]!["kind"] = "note";
        Refused(() => HubDecode.ChatPage(Bytes(kind), "gen", "manager"), "kind");
        var id = ChatPage();
        id["items"]![0]!["id"] = true;
        Refused(() => HubDecode.ChatPage(Bytes(id), "gen", "manager"), "id");
        var text = ChatPage();
        text["items"]![0]!["text"] = null;
        Refused(() => HubDecode.ChatPage(Bytes(text), "gen", "manager"), "text");
    }

    private static JsonObject TaskPage() => new()
    {
        ["db"] = "gen", ["cursor"] = 0,
        ["task"] = new JsonObject
        {
            ["id"] = 7, ["title"] = "T", ["details"] = "", ["done_when"] = "done", ["needs"] = "none", ["goal"] = null,
            ["owner"] = "vps", ["requester"] = "manager", ["state"] = "completed", ["created"] = 1.0, ["attempt"] = 1,
            ["restarts"] = 0, ["nudge_level"] = 0, ["stop_sent"] = 0, ["where_"] = "outputs/T-7/", ["accepted"] = 1,
            ["a column of a later hub"] = "x",
        },
        ["notes"] = new JsonArray(new JsonObject { ["id"] = 1, ["task"] = 7, ["agent"] = "vps", ["ts"] = 1.0, ["text"] = "n" }),
        ["holds"] = new JsonArray(),
        ["outcomes"] = new JsonArray(new JsonObject
        {
            ["id"] = 1, ["task"] = 7, ["attempt"] = 1, ["title"] = "Deploy", ["kind"] = "deploy", ["state"] = "unknown",
        }),
    };

    [TestMethod]
    public void ATaskPageReadsTheWholeTaskAndANullGoalIsNone()
    {
        var page = HubDecode.TaskPage(Bytes(TaskPage()), "gen", 7);
        Assert.AreEqual("", page.Task.GoalText);
        Assert.AreEqual("outputs/T-7/", page.Task.Where);
        Assert.IsTrue(page.Task.IsTerminal);
        Refused(() => HubDecode.TaskPage(Bytes(TaskPage()), "gen", 8), "another task");
        var noGoal = TaskPage();
        noGoal["task"]!.AsObject().Remove("goal");
        Refused(() => HubDecode.TaskPage(Bytes(noGoal), "gen", 7), "goal must be there, null or text");
    }

    [TestMethod]
    public void TheSmallReadsCheckWhatTheyNeed()
    {
        var devices = HubDecode.Devices("""{"db":"gen","limit":4,"devices":[{"device":"pc","label":"PC","address":"192.0.2.10","key":true,"this_device":true}]}"""u8);
        Assert.AreEqual("pc", devices.ThisDevice!.Device);
        var enrolled = HubDecode.Enrollment("""{"device":"pc","label":"PC","key":"k","since":1.5}"""u8);
        Assert.AreEqual("k", enrolled.Key);
        Refused(() => HubDecode.Enrollment("""{"device":"pc","label":"PC","key":""}"""u8), "no key");
        Assert.AreEqual("b.2.3", HubDecode.Wait("""{"db":"gen","token":"b.2.3"}"""u8, "gen").Token!.Text);
        Assert.IsTrue(HubDecode.Wait("""{"db":"new","token":"b.2.3"}"""u8, "gen").IsGenerationChanged);
        Refused(() => HubDecode.Wait("""{"db":"gen","token":"b.2"}"""u8, "gen"), "no token");
        var file = HubDecode.Knowledge("""{"db":"gen","path":"knowledge/owner/a.md","title":"A","text":"# A","source":null}"""u8,
                                       "gen", "knowledge/owner/a.md");
        Assert.AreEqual("# A", file.Text);
        Refused(() => HubDecode.Knowledge("""{"db":"gen","path":"knowledge/owner/b.md","title":"B","text":""}"""u8,
                                          "gen", "knowledge/owner/a.md"), "another file");
    }
}
