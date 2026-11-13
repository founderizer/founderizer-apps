using System;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.Json;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace Founderizer.Core.Tests;

/// <summary>The rules of the live changes, case for case as Tests/FleetCoreTests/LiveChangesTests.swift holds them.</summary>
[TestClass]
public sealed class LiveChangesTests
{
    private static LiveToken T(string text) => LiveToken.Parse(text) ?? throw new AssertFailedException(text);

    [TestMethod]
    public void ATokenIsItsBootAndItsTwoCounts()
    {
        var read = T("b7f3.12.940");
        Assert.AreEqual(("b7f3", 12UL, 940UL, "b7f3.12.940"), (read.Boot, read.State, read.Activity, read.Text));
        var dotted = T("1729.5.7.9");
        Assert.AreEqual(("1729.5", 7UL, 9UL), (dotted.Boot, dotted.State, dotted.Activity));
        foreach (var text in new string?[] { null, "", "b7f3", "b7f3.12", ".12.9", "b7f3..9", "b7f3.12.", "b7f3.x.9",
                                             "b7f3.-1.9", "b7f3.+1.9", "b 7.1.2", "b+7.1.2", "b7f3.1.2\n",
                                             new string('b', 200) + ".1.2", "b.18446744073709551616.1" })
            Assert.IsNull(LiveToken.Parse(text), text);
    }

    [TestMethod]
    public void OnlyTheBootOrTheStateCountWakes()
    {
        var since = T("boot.5.100");
        Assert.IsTrue(T("boot.6.100").Wakes(since));
        Assert.IsTrue(T("other.5.100").Wakes(since));
        Assert.IsFalse(T("boot.5.180").Wakes(since));
        Assert.IsFalse(T("boot.5.100").Wakes(since));
    }

    [TestMethod]
    public void AStateReadCoversAChangeOfItsOwnBootAndCount()
    {
        var change = T("boot.6.5");
        Assert.IsTrue(T("boot.6.0").Covers(change));
        Assert.IsTrue(T("boot.9.0").Covers(change));
        Assert.IsFalse(T("boot.5.9").Covers(change));
        Assert.IsFalse(T("other.9.9").Covers(change));
    }

    [TestMethod]
    public void TheCapLetsOneWakeThroughEveryTwoSecondsAndFoldsTheRest()
    {
        var cap = new WakeCap(2);
        CollectionAssert.AreEqual(new[] { WakeAnswer.Now, WakeAnswer.Later(102), WakeAnswer.Folded, WakeAnswer.Folded },
                                  new[] { cap.Wake(100), cap.Wake(100.5), cap.Wake(101), cap.Wake(101.9) });
        cap.Fired(102);
        var first = cap.Wake(103);
        cap.Fired(104);
        CollectionAssert.AreEqual(new[] { WakeAnswer.Later(104), WakeAnswer.Now, WakeAnswer.Later(108.5) },
                                  new[] { first, cap.Wake(106.5), cap.Wake(107) });
        cap.Reset();
        Assert.AreEqual(WakeAnswer.Now, cap.Wake(107.1));
    }

    [TestMethod]
    public void AFailedWaitWaitsLongerEachTimeFromOneToThirtySeconds()
    {
        foreach (var jitter in new[] { 0.0, 0.5, 1.0 })
        {
            var delays = Enumerable.Range(1, 9).Select(f => WakeBackoff.Delay(f, jitter)).ToArray();
            Assert.IsTrue(delays.All(d => d is >= 1 and <= 30));
            Assert.IsTrue(delays.Zip(delays.Skip(1)).All(p => p.First <= p.Second));
            Assert.IsTrue(delays[^1] >= 24);
        }
        Assert.AreEqual(1, WakeBackoff.Delay(1, 0), 1e-9);
        Assert.AreEqual(1.2, WakeBackoff.Delay(1, 1), 1e-9);
        Assert.AreEqual(4, WakeBackoff.Delay(3, 0.5), 1e-9);
        Assert.AreEqual(12.8, WakeBackoff.Delay(5, 0), 1e-9);
        Assert.AreEqual(30, WakeBackoff.Delay(40, 1), 1e-9);
        Assert.AreEqual(0, WakeBackoff.Delay(0, 1));
    }

    [TestMethod]
    public void AnAnswerEndsTheBackoffAndTheNextWaitAsksFromTheNewestToken()
    {
        var watch = new LiveWatch(T("boot.5.1"));
        CollectionAssert.AreEqual(new double[] { 1, 2, 4 },
                                  new[] { watch.Failed(0.5), watch.Failed(0.5), watch.Failed(0.5) });
        var quiet = T("boot.5.9");
        Assert.AreEqual(WatchStep.Wait, watch.Answered(quiet, 20, 0.5));
        Assert.AreEqual(0, watch.Failures);
        Assert.AreEqual(quiet, watch.Since);
        Assert.AreEqual(1, watch.Failed(0.5));
        var change = T("boot.6.9");
        Assert.AreEqual(WatchStep.Wake, watch.Answered(change, 0.1, 0.5));
        Assert.AreEqual(WatchStep.Wait, watch.Answered(change, 20, 0.5));
        Assert.AreEqual(0, watch.Failures);
        Assert.AreEqual(WatchStep.Wake, watch.Answered(T("again.0.0"), 0.2, 0.5));
    }

    [TestMethod]
    public void AnAnswerThatDidNotWaitIsNotAskedAgainAtOnce()
    {
        var watch = new LiveWatch(T("boot.5.1"));
        var same = T("boot.5.1");
        CollectionAssert.AreEqual(new[] { WatchStep.PauseFor(1), WatchStep.PauseFor(2), WatchStep.PauseFor(4) },
                                  new[] { watch.Answered(same, 0.01, 0.5), watch.Answered(same, 0.01, 0.5),
                                          watch.Answered(same, 0.5, 0.5) });
        Assert.AreEqual(WatchStep.Wake, watch.Answered(T("boot.6.1"), 0.01, 0.5));
        Assert.AreEqual(0, watch.Failures);
    }

    [TestMethod]
    public void TheReadOnTheClockCountsFromTheLastReadWhoeverRanIt()
    {
        Assert.AreEqual(0, LiveChanges.UntilRead(null, 50));
        Assert.AreEqual(2, LiveChanges.UntilRead(49, 50));
        Assert.AreEqual(0, LiveChanges.UntilRead(47, 50));
        Assert.AreEqual(0, LiveChanges.UntilRead(46, 50));
        Assert.AreEqual(3, LiveChanges.UntilRead(50, 50));
    }
}

/// <summary>The outbox and the requests it keeps (FleetCore's Outbox and PendingRequest).</summary>
[TestClass]
public sealed class OutboxTests
{
    private static readonly Uri Hub = new("http://192.0.2.10:8765/");
    private string folder = "";

    [TestInitialize]
    public void Make() => folder = Directory.CreateTempSubdirectory("founderizer-outbox-").FullName;

    [TestCleanup]
    public void Remove() => Directory.Delete(folder, recursive: true);

    private static JsonElement Body(PendingRequest request) => JsonDocument.Parse(request.Body()).RootElement.Clone();

    [TestMethod]
    public void AMessageAnAnswerAndAPressGoAsTheMacSendsThem()
    {
        var message = PendingRequest.New(Hub, "db", "pc", "hello", recipient: "vps", attachments: [3, 4]);
        Assert.AreEqual("ui/messages", message.Route);
        var body = Body(message);
        Assert.AreEqual("hello", body.GetProperty("text").GetString());
        Assert.AreEqual("vps", body.GetProperty("recipient").GetString());
        Assert.AreEqual("db", body.GetProperty("db").GetString());
        Assert.AreEqual(message.RequestIdText, body.GetProperty("request_id").GetString());
        Assert.AreEqual(2, body.GetProperty("attachments").GetArrayLength());
        // The keys are sorted, as the Mac's JSONSerialization sorts them.
        var keys = body.EnumerateObject().Select(p => p.Name).ToArray();
        CollectionAssert.AreEqual(keys.Order(StringComparer.Ordinal).ToArray(), keys);

        var answer = PendingRequest.New(Hub, "db", "pc", "yes", needId: 7);
        Assert.AreEqual("ui/needs/7", answer.Route);
        Assert.AreEqual("yes", Body(answer).GetProperty("answer").GetString());
        var press = PendingRequest.New(Hub, "db", "pc", "Option two", needId: 7, choice: 1);
        Assert.AreEqual(1, Body(press).GetProperty("choice").GetInt64());
        Assert.IsFalse(Body(press).TryGetProperty("answer", out _));
        var ticks = PendingRequest.New(Hub, "db", "pc", "A, B", needId: 7, choices: [2, 0, 2]);
        CollectionAssert.AreEqual(new long[] { 0, 2 }, Body(ticks).GetProperty("choices").EnumerateArray()
                                                                        .Select(e => e.GetInt64()).ToArray());
        // A message carries no signed yes; an answer carries it only with both halves.
        Assert.IsNull(PendingRequest.New(Hub, "db", "pc", "x", statement: "s", signature: "g").Statement);
        Assert.IsFalse(Body(PendingRequest.New(Hub, "db", "pc", "x", needId: 1, statement: "s")).TryGetProperty("statement", out _));
        Assert.AreEqual("s", Body(PendingRequest.New(Hub, "db", "pc", "x", needId: 1, statement: "s", signature: "g"))
                             .GetProperty("statement").GetString());
    }

    [TestMethod]
    public void TheCommandsOfADeviceGoToTheirRoutes()
    {
        var steer = PendingRequest.New(Hub, "db", "pc", "  look at the logs\r\nfirst ", command: OwnerCommand.Steer(5, 2));
        Assert.AreEqual("ui/tasks/5/steer", steer.Route);
        Assert.AreEqual("look at the logs\nfirst", Body(steer).GetProperty("text").GetString());
        Assert.AreEqual(2, Body(steer).GetProperty("expected_attempt").GetInt64());
        var pause = PendingRequest.New(Hub, "db", "pc", "", command: OwnerCommand.Control(5, TaskControl.ResumeCheck));
        Assert.AreEqual("ui/tasks/5/control", pause.Route);
        Assert.AreEqual("resume_check", Body(pause).GetProperty("action").GetString());
        Assert.AreEqual("", Body(pause).GetProperty("note").GetString());
        var talk = PendingRequest.New(Hub, "db", "pc", " why? ", command: OwnerCommand.NeedTalk(9));
        Assert.AreEqual("ui/needs/9/talk", talk.Route);
        Assert.AreEqual("why?", Body(talk).GetProperty("text").GetString());
        Assert.ThrowsExactly<OutboxException>(() => PendingRequest.New(Hub, "db", "pc", " ", command: OwnerCommand.Steer(5, 2)).Body());
        Assert.ThrowsExactly<OutboxException>(() => PendingRequest.New(Hub, "db", "pc", new string('x', 2001),
                                                                       command: OwnerCommand.NeedTalk(9)).Body());
    }

    [TestMethod]
    public void TheOutboxKeepsOneRequestUntilItsReceipt()
    {
        var outbox = new Outbox(Path.Combine(folder, "deep", "outbox.json"));
        Assert.IsNull(outbox.Load());
        var first = PendingRequest.New(Hub, "db", "pc", "hello \u2028 \u00e9", recipient: "vps",
                                       command: null, attachments: [1]);
        outbox.Save(first);
        outbox.Save(first);                         // the same request again is kept again
        var loaded = outbox.Load()!;
        Assert.IsTrue(loaded.SameRequest(first));
        Assert.AreEqual(first.CreatedAt.ToUnixTimeMilliseconds(), loaded.CreatedAt.ToUnixTimeMilliseconds());
        var second = PendingRequest.New(Hub, "db", "pc", "another");
        Assert.AreEqual(OutboxException.Problem.PendingRequest, Assert.ThrowsExactly<OutboxException>(() => outbox.Save(second)).Kind);
        Assert.ThrowsExactly<OutboxException>(() => outbox.Clear(second.RequestId));
        outbox.Clear(first.RequestId);
        Assert.IsNull(outbox.Load());
        outbox.Save(second);
        var command = PendingRequest.New(Hub, "db", "pc", "", command: OwnerCommand.Control(3, TaskControl.Stop));
        outbox.Clear(second.RequestId);
        outbox.Save(command);
        Assert.AreEqual(OwnerCommand.Control(3, TaskControl.Stop), outbox.Load()!.Command);
        if (!OperatingSystem.IsWindows())
            Assert.AreEqual(UnixFileMode.UserRead | UnixFileMode.UserWrite, File.GetUnixFileMode(outbox.File));
    }

    [TestMethod]
    public void ARefusedSecretRemovesTheTextAndTheDrafts()
    {
        var outbox = new Outbox(Path.Combine(folder, "outbox.json"));
        var request = PendingRequest.New(Hub, "db", "pc", "my password is hunter2");
        outbox.Save(request);
        var cleared = false;
        var refused = outbox.RejectSecret(request.RequestId, () => cleared = true);
        Assert.IsTrue(cleared);
        Assert.AreEqual("", refused.Text);
        Assert.AreEqual("", outbox.Load()!.Text);
        Assert.IsNotNull(outbox.Load()!.Refusal);
        Assert.IsFalse(File.ReadAllText(outbox.File).Contains("hunter2"));
    }

    [TestMethod]
    public void ARecordThatDoesNotReadOrIsTooLargeBlocksTheSend()
    {
        var outbox = new Outbox(Path.Combine(folder, "outbox.json"));
        File.WriteAllText(outbox.File, "{\"request_id\": 5}");
        Assert.AreEqual(OutboxException.Problem.InvalidRecord, Assert.ThrowsExactly<OutboxException>(() => outbox.Load()).Kind);
        File.WriteAllBytes(outbox.File, new byte[Outbox.RecordLimit + 1]);
        Assert.ThrowsExactly<OutboxException>(() => outbox.Load());
        File.Delete(outbox.File);
        Assert.ThrowsExactly<OutboxException>(() => outbox.Save(PendingRequest.New(Hub, "db", "pc", new string('x', 70_000))));
    }

    [TestMethod]
    public void AReceiptConfirmsOnlyItsOwnRequest()
    {
        var message = PendingRequest.New(Hub, "db", "pc", "hi", attachments: [2]);
        SendReceipt Receipt(string? id = null, string client = "pc", string? recipient = null, long[]? files = null) =>
            new(true, id ?? message.RequestIdText.ToUpperInvariant(), 1, 1, false, client, recipient,
                Attachments: files ?? [2]);
        Assert.IsTrue(message.IsConfirmedBy(Receipt()));                         // the id in any case
        Assert.IsTrue(message.IsConfirmedBy(Receipt(recipient: "manager")));    // no recipient is the manager
        Assert.IsFalse(message.IsConfirmedBy(Receipt(id: Guid.NewGuid().ToString())));
        Assert.IsFalse(message.IsConfirmedBy(Receipt(client: "other")));
        Assert.IsFalse(message.IsConfirmedBy(Receipt(recipient: "vps")));
        Assert.IsFalse(message.IsConfirmedBy(Receipt(files: [])));
        Assert.IsFalse(message.IsConfirmedBy(Receipt() with { Ok = false }));

        var steer = PendingRequest.New(Hub, "db", "pc", "go\r\n", command: OwnerCommand.Steer(4, 2));
        var steered = new ControlReceipt(true, steer.RequestIdText, "pc", false,
                                         Steer: new TaskSteer(1, 4, 2, "go", 1, steer.RequestIdText, "pc"));
        Assert.IsTrue(steer.IsConfirmedBy(steered));
        Assert.IsFalse(steer.IsConfirmedBy(steered with { Steer = steered.Steer! with { Attempt = 3 } }));
        Assert.IsFalse(steer.IsConfirmedBy(steered with { Steer = null }));

        var pause = PendingRequest.New(Hub, "db", "pc", "", command: OwnerCommand.Control(4, TaskControl.Pause));
        var held = new ControlReceipt(true, pause.RequestIdText, "pc", false, Hold: new TaskHold(9, 4, "pause", "requested", 2));
        Assert.IsTrue(pause.IsConfirmedBy(held));
        Assert.IsTrue(pause.IsConfirmedBy(held with { Hold = held.Hold! with { Kind = "stop" } }));
        Assert.IsFalse(pause.IsConfirmedBy(held with { Hold = held.Hold! with { State = "released" } }));
        var resume = PendingRequest.New(Hub, "db", "pc", "", command: OwnerCommand.Control(4, TaskControl.Resume));
        Assert.IsTrue(resume.IsConfirmedBy(held with { RequestId = resume.RequestIdText,
                                                       Hold = held.Hold! with { State = "released" } }));

        var talk = PendingRequest.New(Hub, "db", "pc", "why?", command: OwnerCommand.NeedTalk(6));
        var talked = new ControlReceipt(true, talk.RequestIdText, "pc", false, Need: 6,
                                        Talk: [new NeedMessage("owner", "why?", 1)]);
        Assert.IsTrue(talk.IsConfirmedBy(talked));
        Assert.IsFalse(talk.IsConfirmedBy(talked with { Talk = [new NeedMessage("manager", "because", 1)] }));
    }
}
