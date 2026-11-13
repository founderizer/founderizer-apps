using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Threading.Tasks;
using Microsoft.VisualStudio.TestTools.UnitTesting;
using static Founderizer.Core.Tests.SampleFleet;

namespace Founderizer.Core.Tests;

/// <summary>The models of the second set of pictures (windows-app-pictures-2.md): each state, in the Mac's or the
/// iPhone's words, from one store state.</summary>
[TestClass]
public sealed class SecondSetTests
{
    private static StoreState Fleet(Action<JsonObject>? change = null)
    {
        var snapshot = Snapshot();
        change?.Invoke(snapshot);
        return State(Decode(snapshot), Clock);
    }

    private static readonly Uri Hub = new("http://192.0.2.10:8765/");

    // ---------------------------------------------------------------- 14 · not sent

    [TestMethod]
    public void AMessageThatTheHubDidNotConfirmHasTheMacsBarAndABubbleWithNoWords()
    {
        var waiting = PendingRequest.New(Hub, "gen1", "founderizer-windows/1", "Which order is it?", recipient: "wren");
        var s = Fleet() with { Pending = waiting };
        var bar = Screens.PendingBar(s, Clock)!;
        Assert.AreEqual(("Not sent", "Your hub did not confirm it. Sending it again does not send it twice.", (string?)null, "Which order is it?"),
                        (bar.State, bar.Why, bar.OtherHub, bar.Text));
        CollectionAssert.AreEqual(new[] { "Refresh receipt", "Try again" }, bar.Actions.Select(a => a.Words).ToArray());
        var row = Screens.Chat(s, "wren", Clock, Utc).Rows.Single(r => r.Kind == ChatRowKind.Message);
        Assert.AreEqual(("Which order is it?", (string?)null, WriteAction.None, false), (row.Text, row.TimeWords, row.SlotAction, row.SlotIsWarning),
                        "his bubble, with no words under it: the bar says it");
        Assert.IsNull(Screens.PendingBar(s with { Sending = true }, Clock), "no bar while it goes");
        Assert.AreEqual("Sending…", Screens.Chat(s with { Sending = true }, "wren", Clock, Utc).Rows.Single(r => r.Kind == ChatRowKind.Message).TimeWords);
        // A refusal: its words, Discard, and no bubble in the chat.
        var refused = s with { Pending = waiting with { Refusal = "Not sent: Customer Support is in setup." } };
        var no = Screens.PendingBar(refused, Clock)!;
        Assert.AreEqual(("Not sent: Customer Support is in setup.", (string?)null), (no.State, no.Why));
        CollectionAssert.AreEqual(new[] { "Refresh receipt", "Discard" }, no.Actions.Select(a => a.Words).ToArray());
        Assert.IsFalse(Screens.Chat(refused, "wren", Clock, Utc).Rows.Any(r => r.Kind == ChatRowKind.Message));
        // A request of another hub, and one that cannot go again now.
        var other = Screens.PendingBar(s with { Pending = waiting with { Database = "gen0" } }, Clock)!;
        Assert.AreEqual("It belongs to another hub, so it is not sent again.", other.OtherHub);
        CollectionAssert.AreEqual(new[] { "Refresh receipt" }, other.Actions.Select(a => a.Words).ToArray());
    }

    [TestMethod]
    public void ACommandInTheBarIsNamedByItsItemOnlyFromItsOwnHub()
    {
        var s = Fleet();
        PendingRequest Command(OwnerCommand c, string db = "gen1") => PendingRequest.New(Hub, db, "founderizer-windows/1", "", command: c);
        Assert.AreEqual("Pause “Fix the checkout error on iPhone”", Screens.RequestName(s, Command(OwnerCommand.Control(12, TaskControl.Pause))));
        Assert.AreEqual("Resume Check “Fix the checkout error on iPhone”", Screens.RequestName(s, Command(OwnerCommand.Control(12, TaskControl.ResumeCheck))));
        Assert.AreEqual("Guide “Fix the checkout error on iPhone”", Screens.RequestName(s, Command(OwnerCommand.Steer(12, 1))));
        Assert.AreEqual("Stop the task", Screens.RequestName(s, Command(OwnerCommand.Control(12, TaskControl.Stop), "gen0")));
        Assert.AreEqual("Guide the task", Screens.RequestName(s, Command(OwnerCommand.Steer(99, 1))));
    }

    // ---------------------------------------------------------------- 1 · search

    [TestMethod]
    public void SearchFindsAgentsByRoleOrNameAndTasksByTitleOrNumber()
    {
        var s = Fleet();
        var found = Screens.Search(s, " support ", 0, Clock, CultureInfo.InvariantCulture);
        Assert.AreEqual("support", found.Words);
        CollectionAssert.AreEqual(new[] { "wren" }, found.Agents.Select(a => a.Name).ToArray());
        Assert.AreEqual("Customer Support", found.Agents[0].Label);
        Assert.IsNotNull(found.Agents[0].Line, "its line, as the pane's preview says it");
        CollectionAssert.AreEqual(new[] { 11L }, found.Tasks.Select(t => t.Id).ToArray());
        Assert.AreEqual(Page.Chat("wren"), found.Open(0));
        Assert.AreEqual(Page.OfTask(11), found.Open(1));
        Assert.IsNull(found.Open(2));
        Assert.AreEqual(1, SearchModel.Move(0, +1, found.Count));
        Assert.AreEqual(1, SearchModel.Move(1, +1, found.Count), "Down stops at the last row");
        Assert.AreEqual(0, SearchModel.Move(0, -1, found.Count), "Up stops at the first");
        Assert.AreEqual(1, Screens.Search(s, "support", 7, Clock).Highlighted, "the row stays inside the list");
        // A task's number, with T- or without; nothing typed: every agent in the hub's order, and the task that moved last first.
        CollectionAssert.AreEqual(new[] { 12L }, Screens.Search(s, "T-12", 0, Clock).Tasks.Select(t => t.Id).ToArray());
        CollectionAssert.AreEqual(new[] { 12L }, Screens.Search(s, "12", 0, Clock).Tasks.Select(t => t.Id).ToArray());
        var all = Screens.Search(s, "", 0, Clock);
        CollectionAssert.AreEqual(new[] { "manager", "wren", "theo", "pax", "orla" }, all.Agents.Select(a => a.Name).ToArray());
        CollectionAssert.AreEqual(new[] { 11L, 12L, 13L, 22L, 23L, 21L }, all.Tasks.Select(t => t.Id).ToArray());
        var none = Screens.Search(s, "zzz", 3, Clock);
        Assert.AreEqual((0, 0), (none.Count, none.Highlighted));
        Assert.AreEqual(("Search", "Agents", "Tasks"), (none.Placeholder, none.AgentsHeading, none.TasksHeading));
        Assert.AreEqual(TaskSymbol.Checked, all.Tasks.Single(t => t.Id == 22).Mark.Symbol);
    }

    [TestMethod]
    public void SearchShowsTheNewestTwentyTasksAndAtMostFiftyThatMatch()
    {
        var s = Fleet(snapshot => snapshot["recent"] = new JsonArray(Enumerable.Range(100, 60)
            .Select(i => (JsonNode?)Head(i, $"Check backup {i}", "pax", "completed", Now - 100_000 + i, accepted: 1)).ToArray()));
        Assert.AreEqual(20, Screens.Search(s, "", 0, Clock).Tasks.Count);
        var backups = Screens.Search(s, "backup", 0, Clock).Tasks;
        Assert.AreEqual(50, backups.Count);
        Assert.AreEqual(159, backups[0].Id, "the one that moved last first");
    }

    // ---------------------------------------------------------------- 4 · files

    [TestMethod]
    public void AFileOfAMessageSaysItsSizeOrThatItWasNotLoaded()
    {
        var picture = new MessageAttachment(7, "spring-banner.png", "image/png", 48 * 1024, new string('a', 64), Now);
        var table = new MessageAttachment(8, "spring-prices.csv", "text/csv", 12 * 1024, new string('b', 64), Now);
        var s = Fleet();
        var tile = Screens.Tile(s, table, Clock);
        Assert.AreEqual((false, FileSymbol.Text, "12 KB", false, "Open spring-prices.csv (12 KB)"),
                        (tile.IsPicture, tile.Symbol, tile.Words, tile.ShowsReadAgain, tile.Hover));
        Assert.IsTrue(Screens.Tile(s, picture, Clock).IsPicture);
        var unloaded = Screens.Tile(s with { FilesUnloaded = [8] }, table, Clock);
        Assert.AreEqual(("Not loaded", true, true, "Read spring-prices.csv again"),
                        (unloaded.Words, unloaded.WordsAreWarning, unloaded.ShowsReadAgain, unloaded.ReadAgainHover));
        var reading = Screens.Tile(s with { FilesUnloaded = [8], FilesReading = [8] }, table, Clock);
        Assert.IsFalse(reading.ShowsReadAgain, "no Read again while a read runs");
        var old = Screens.Tile(s with { FilesUnloaded = [8], ReadError = HubException.NoAnswer() }, table, Clock);
        Assert.AreEqual((false, false), (old.WordsAreWarning, old.ShowsReadAgain), "muted, with no way on, while the hub does not answer");
        Assert.AreEqual(FileSymbol.Pdf, (table with { Mime = "application/pdf" }).Symbol);
        Assert.AreEqual(FileSymbol.Zip, (table with { Mime = "application/zip" }).Symbol);
    }

    [TestMethod]
    public void AFileThatHeAddedSaysWhereItsUploadStands()
    {
        var waiting = new StagedFile { RequestId = Guid.NewGuid(), Name = "logo.png", Mime = "image/png", Size = 48 * 1024 };
        var onHub = waiting with { File = new MessageAttachment(9, "logo.png", "image/png", 48 * 1024, new string('c', 64), Now) };
        var s = Fleet();
        Assert.AreEqual(("Waiting", "Take logo.png out", true, false), (Screens.Chip(s, waiting).Words, Screens.Chip(s, waiting).TakeOutHover,
                                                                        Screens.Chip(s, waiting).IsPicture, Screens.Chip(s, waiting).ShowsSendAgain));
        Assert.AreEqual("Going up…", Screens.Chip(s with { Uploading = [waiting.RequestId] }, waiting).Words);
        Assert.AreEqual("48 KB", Screens.Chip(s, onHub).Words);
        var failed = Screens.Chip(s, waiting with { Failure = "The hub is busy." });
        Assert.AreEqual(("The hub is busy.", true, true, "Send this file up again"), (failed.Words, failed.WordsAreWarning, failed.ShowsSendAgain, failed.SendAgainHover));
        Assert.AreEqual("Not sent", Screens.Chip(s, waiting with { Failure = "This hub takes images, PDF, ZIP, text, Markdown, CSV and JSON." }).Words);
        Assert.IsFalse(Screens.Chip(s, onHub, sending: true).ShowsTakeOut, "a file that a message carries is not taken out");
        // The files of a message on its way are in the request line, not in the composer.
        var staged = s with { Staged = s.Staged.SetItem("agent:orla", ValueList.Of([onHub, waiting])) };
        Assert.AreEqual(2, Screens.Chat(staged, "orla", Clock, Utc).Composer.Chips.Count);
        var going = staged with { Pending = PendingRequest.New(Hub, "gen1", "founderizer-windows/1", "And our logo.", recipient: "orla", attachments: [9]) };
        CollectionAssert.AreEqual(new[] { "logo.png" }, Screens.Chat(going, "orla", Clock, Utc).Composer.Files.Select(f => f.Name).ToArray());
        Assert.AreEqual(waiting.RequestId, Screens.Chat(going, "orla", Clock, Utc).Composer.Files.Single().RequestId);
        Assert.AreEqual(9, Screens.PendingBar(going, Clock)!.Files.Single().File.Id);
    }

    [TestMethod]
    public void TheSizeOfAFileIsTheMacsWords()
    {
        var en = CultureInfo.GetCultureInfo("en-GB");
        Assert.AreEqual("512 B", MessageAttachment.SizeWords(512, en));
        Assert.AreEqual("1,023 B", MessageAttachment.SizeWords(1023, en));
        Assert.AreEqual("12 KB", MessageAttachment.SizeWords(12 * 1024 + 1000, en));
        Assert.AreEqual("1.2 MB", MessageAttachment.SizeWords(1_310_720, en), "half to even, as Swift's FormatStyle");
        Assert.AreEqual("1.4 MB", MessageAttachment.SizeWords(1_415_578, en));
        Assert.AreEqual("2,5 MB", MessageAttachment.SizeWords(2_621_440, CultureInfo.GetCultureInfo("de-DE")));
    }

    // ---------------------------------------------------------------- 10 · the notification and the taskbar's count

    private static OwnerNeed Need(long id, string by, bool open = true) =>
        new(id, $"Request {id}", "Why.", "", Now - 60, by, Answered: open ? null : Now - 30);

    [TestMethod]
    public void ANewRequestOfTheManagerNotifiesOnceAndTheFirstReadingNotifiesNothing()
    {
        var ledger = new NotificationLedger();
        Assert.AreEqual(0, ledger.Observe("c", [Need(1, "manager"), Need(2, "manager")]).Count, "the first reading is the baseline");
        CollectionAssert.AreEqual(new[] { 3L }, ledger.Observe("c", [Need(1, "manager"), Need(3, "manager"), Need(4, "wren"), Need(5, "manager", open: false)]).ToArray(),
                                  "the manager's, open, and above the highest seen");
        Assert.AreEqual(0, ledger.Observe("c", [Need(3, "manager")]).Count, "never twice");
        Assert.AreEqual(0, ledger.Observe("other", [Need(9, "manager")]).Count, "another hub or generation has its own baseline");
        Assert.IsNull(ledger.ObserveWarning("c", null));
        Assert.AreEqual("stalled/1794582000.0", ledger.ObserveWarning("c", new ManagerWarning("stalled", 1794582000)));
        Assert.IsNull(ledger.ObserveWarning("c", new ManagerWarning("stalled", 1794582000)), "one notice for each episode");
        Assert.IsNull(new NotificationLedger().ObserveWarning("c", new ManagerWarning("stalled", 1794582000)), "a warning at the first reading is the baseline");
    }

    [TestMethod]
    public void ANoticeHasTheMacsWordsAndItsClickOpensItsRequest()
    {
        var ledger = new NotificationLedger();
        var s = Fleet();
        Notifications.Due(ledger, Hub, s.Fleet!, s.Names);
        var next = Fleet(snapshot => ((JsonArray)snapshot["needs"]!).Add(SampleFleet.Need(3, "Raise the ad budget?", "It sold out.", "manager", Now - 10, "Yes", "No")));
        var notice = Notifications.Due(ledger, Hub, next.Fleet!, next.Names).Single();
        Assert.AreEqual(("Fleet Manager", "Raise the ad budget?", (long?)3), (notice.Title, notice.Body, notice.Need));
        Assert.AreEqual(Notifications.Context(Hub, "gen1") + "/3", notice.Tag);
        Assert.AreEqual(64, notice.Context.Length);
        Assert.AreEqual(3, Screens.NoticeTarget(next, notice));
        Assert.IsNull(Screens.NoticeTarget(s, notice), "a request that the reading does not list opens nothing");
        Assert.IsNull(Screens.NoticeTarget(next with { Hub = new Uri("http://192.0.2.11:8765/") }, notice));
        Assert.IsTrue(Notifications.Open(Hub, next.Fleet!).Contains(notice.Tag));
        Assert.IsFalse(Notifications.Open(Hub, s.Fleet!).Contains(notice.Tag), "an answered request's notice goes");
        var warned = Fleet(snapshot => snapshot["manager_warning"] = new JsonObject { ["kind"] = "stalled", ["since"] = Now - 600 });
        var warning = Notifications.Due(ledger, Hub, warned.Fleet!, warned.Names).Single();
        Assert.AreEqual(("Check the Founderizer manager", "The manager needs your attention.", (long?)null), (warning.Title, warning.Body, warning.Need));
    }

    [TestMethod]
    public void TheTaskbarCountIsTheOpenRequestsAndTheWarning()
    {
        Assert.AreEqual("2", Screens.TaskbarCount(Fleet()));
        Assert.AreEqual("3", Screens.TaskbarCount(Fleet(snapshot => snapshot["manager_warning"] = new JsonObject { ["kind"] = "stalled", ["since"] = Now - 600 })));
        Assert.IsNull(Screens.TaskbarCount(Fleet(snapshot => snapshot["needs"] = new JsonArray())), "nothing when none is open");
        Assert.IsNull(Screens.TaskbarCount(new StoreState()));
    }

    // ---------------------------------------------------------------- the footer, Earlier messages and Latest

    [TestMethod]
    public void AMessagesFooterSaysWhenItWasReadAndAChatShowsItsNewestItemsFirst()
    {
        var s = Fleet() with
        {
            Chats = ImmutableDictionaryOf("orla", Enumerable.Range(0, 5).Select(i =>
                new MobileChatItem("message", Now - 600 + i * 10, JsonDocument.Parse($"\"{Guid.NewGuid()}\"").RootElement, $"Line {i}",
                                   ReadAt: i < 4 ? Now - 300 : null, Edited: i == 3 ? Now - 200 : null) { Key = Guid.NewGuid().ToString() })),
        };
        var rows = Screens.Chat(s, "orla", Clock, Utc).Rows.Where(r => r.Kind == ChatRowKind.Message).ToList();
        Assert.AreEqual("13 Nov 2026 at 15:02 · Read", rows[0].TimeHover);
        Assert.AreEqual("13 Nov 2026 at 15:02 · Read · Edited 15:08", rows[3].TimeHover);
        Assert.AreEqual("13 Nov 2026 at 15:02 · Received, not read yet", rows[4].TimeHover);
        Assert.AreEqual("Copy message", rows[0].CopyWords);
        var chat = Screens.Chat(s, "orla", Clock, Utc, shown: 2);
        Assert.AreEqual("Earlier messages", chat.Earlier);
        CollectionAssert.AreEqual(new[] { "Line 3", "Line 4" }, chat.Rows.Where(r => r.Kind == ChatRowKind.Message).Select(r => r.Text).ToArray());
        Assert.IsNull(Screens.Chat(s, "orla", Clock, Utc).Earlier);
        Assert.AreEqual("Latest", chat.LatestWords);
    }

    private static System.Collections.Immutable.ImmutableDictionary<string, ChatPageState> ImmutableDictionaryOf(string agent, IEnumerable<MobileChatItem> items) =>
        System.Collections.Immutable.ImmutableDictionary<string, ChatPageState>.Empty.Add(agent, new ChatPageState { Agent = agent, Items = ValueList.Of(items) });

    // ---------------------------------------------------------------- the small states

    [TestMethod]
    public void TheFirstReadShowsOneLineAndNoPageSaysItIsEmpty()
    {
        var first = new StoreState { Hub = Hub, Key = KeyState.InHand };
        var pane = Screens.Pane(first, Page.Needs, Clock, Utc);
        Assert.AreEqual((true, "Reading the hub…", 0), (pane.Reading, pane.ReadingWords, pane.Agents.Count));
        Assert.IsFalse(Screens.Needs(first, null, null, Clock, Utc).Empty, "no Nothing needs you before the first reading");
        var board = Screens.Board(first, ActivityPeriod.Today, null, Clock, Utc);
        Assert.AreEqual((true, false, (string?)null), (board.Waiting, board.Empty, board.EmptyWords));
        Assert.IsFalse(Screens.Pane(Fleet(), Page.Needs, Clock, Utc).Reading);
    }

    [TestMethod]
    public void NothingNeedsYouAndTheRequestThatHeAnsweredStaysAtHandWithItsCheck()
    {
        var answered = Fleet(snapshot =>
        {
            snapshot["needs"] = new JsonArray();
            var one = SampleFleet.Need(1, "Refund an order from 45 days ago?", "A customer asks.", "manager", Now - 2400, "Refund it", "Offer a 20% voucher");
            one["answer"] = "Offer a 20% voucher";
            one["answered"] = Now - 60;
            snapshot["answered_needs"] = new JsonArray(one);
        });
        var needs = Screens.Needs(answered, null, null, Clock, Utc);
        Assert.AreEqual((true, "Nothing needs you", 1, "1 answered"), (needs.Empty, needs.EmptyWords, needs.EndedCount, needs.EndedWords));
        var step = Screens.Needs(answered, 1, null, Clock, Utc).AtHand!;
        Assert.AreEqual((1L, true, "Offer a 20% voucher"), (step.Id, step.Ended, step.AnswerWords));
        Assert.IsFalse(Screens.Needs(answered, 1, null, Clock, Utc).Empty);
    }

    [TestMethod]
    public void TheWordsOfARequestCardAndTicksAreTheMacs()
    {
        var s = Fleet();
        var need = s.Fleet!.Needs[0];
        var card = Screens.Card(s, need, [], Clock, Utc);
        Assert.AreEqual(("Answered", "Your answer"), (card.AnsweredHeading, card.YourAnswerLabel));
        Assert.IsFalse(OptionsModel.CanSendTicks(s, Clock, 0));
        Assert.IsTrue(OptionsModel.CanSendTicks(s, Clock, 2));
        Assert.AreEqual("Send 2", OptionsModel.SendWords(2));
        var step = Screens.Step(s, need with { Why = "One line.\r\nTwo lines.\u2028Three." }, [], Clock, Utc);
        Assert.AreEqual("One line. Two lines. Three.", step.ShortWhy);
    }

    [TestMethod]
    public void AReasonIsReadInBlocksAsTheMacsNeedBody()
    {
        var blocks = NeedBody.Blocks("The email is ready.\nIt goes on Monday.\n\n- one\n• two\n* three\n1. first\n12) twelfth\n123. not an item\n-no space");
        CollectionAssert.AreEqual(new[]
        {
            new NeedBody.Block(null, "The email is ready. It goes on Monday."), new NeedBody.Block("•", "one"), new NeedBody.Block("•", "two"),
            new NeedBody.Block("•", "three"), new NeedBody.Block("1.", "first"), new NeedBody.Block("12.", "twelfth"),
            new NeedBody.Block(null, "123. not an item -no space"),
        }, blocks.ToArray());
    }

    [TestMethod]
    public void TheSmallStatesHaveTheirWords()
    {
        var s = Fleet();
        var controls = Screens.Task(s with
        {
            TaskPages = s.TaskPages.SetItem(12, new TaskPageState { Task = TaskPage(12) }),
        }, 12, Clock, Utc)!.Controls!;
        Assert.AreEqual(("Pause", "Stop", "Resume"), (controls.PauseWords, controls.StopWords, controls.ResumeWords));
        var board = Screens.Board(s, ActivityPeriod.Today, null, Clock, Utc);
        Assert.AreEqual(("Period", "Show the tasks of one period", "Agent", "Show the tasks of one agent"),
                        (board.PeriodLabel, board.PeriodHover, board.AgentLabel, board.AgentHover));
        Assert.AreEqual("Last reading", Screens.Settings(s, "", Clock, Utc).LastReadingLabel);
        Assert.AreEqual("Usage", Screens.Panel(s, "wren", Clock, Utc).UsageHeading);
        Assert.AreEqual("The hub's answer does not match the PC's API.", StoreState.PcWords("The hub's answer does not match the phone's API."));
        // A time to come that is past shows its date, as fleetComingTime.
        Assert.AreEqual("12 Nov", Screens.ComingTime(Now - 86_400, Now, Utc));
        Assert.AreEqual("15:12", Screens.ComingTime(Now, Now, Utc));
    }

    private static FleetTask TaskPage(long id) => HubDecode.TaskPage(System.Text.Encoding.UTF8.GetBytes(new JsonObject
    {
        ["db"] = "gen1", ["cursor"] = 1,
        ["task"] = new JsonObject
        {
            ["id"] = id, ["title"] = "Fix the checkout error on iPhone", ["details"] = "Some orders fail at checkout.", ["done_when"] = "an order goes through",
            ["needs"] = "none", ["goal"] = null, ["owner"] = "theo", ["requester"] = "manager", ["state"] = "working", ["created"] = Now - 900,
            ["attempt"] = 1, ["restarts"] = 0, ["nudge_level"] = 0, ["stop_sent"] = 0, ["last_activity"] = Now - 720,
        },
        ["notes"] = new JsonArray(), ["holds"] = new JsonArray(), ["outcomes"] = new JsonArray(),
    }.ToJsonString()), "gen1", id).Task;

    [TestMethod]
    public void AUsageWindowHasItsHoverAndItsResetAtTheMinuteHalfUp()
    {
        var s = Fleet(snapshot =>
        {
            var wren = ((JsonArray)snapshot["agents"]!).First(a => a!["name"]!.GetValue<string>() == "wren")!;
            wren["usage"] = new JsonArray(
                new JsonObject { ["label"] = "5 hours", ["used_percent"] = 42.5, ["resets_at"] = Now + 6480 + 30 },
                new JsonObject { ["label"] = "7 days", ["used_percent"] = 18, ["resets_at"] = Now + 3 * 86_400 });
        });
        var usage = Screens.Panel(s, "wren", Clock, Utc).Usage;
        Assert.AreEqual(("5 h", 43, "17:01"), (usage[0].Label, usage[0].Percent, usage[0].Resets), "half a minute goes up");
        Assert.AreEqual("5 hours: 42.5% used · resets 13 Nov 2026 at 17:01", usage[0].Hover);
        Assert.AreEqual("7 days: 18% used · resets 16 Nov 2026 at 15:12", usage[1].Hover);
    }

    [TestMethod]
    public void ALineWhoseWayOnIsSettingsHasNoButtonOnSettings()
    {
        var s = Fleet() with { ReadError = HubException.Refusal(403, "device_not_enrolled", "not enrolled"), ReadWasRefused = true, AuthProblem = "device_not_enrolled", LastRead = Clock.AddMinutes(-4) };
        var line = Screens.Line(s, Clock)!;
        Assert.IsTrue(line.ActionIsSettings && line.ShowsAction, line.Words);
        Assert.IsFalse(Screens.Line(s, Clock, Page.Settings)!.ShowsAction);
        Assert.IsTrue(Screens.Line(s, Clock, Page.Needs)!.ShowsAction);
        var silent = Fleet() with { ReadError = HubException.NoAnswer(), LastRead = Clock.AddMinutes(-4) };
        Assert.IsTrue(Screens.Line(silent, Clock, Page.Settings)!.ShowsAction, "Try again shows on Settings too");
    }

    [TestMethod]
    public void AnAgentsLineKeepsItsCountApartAndAnEndedRowDrawsItsAgentsState()
    {
        var s = Fleet(snapshot => ((JsonArray)snapshot["tasks"]!).Add(Head(14, "Reply to the reseller", "theo", "working", Now - 200)));
        var rows = Screens.Pane(s, Page.Needs, Clock, Utc).Agents;
        foreach (var row in rows) Assert.AreEqual(row.Line ?? "", row.LineText + row.LineCount, row.Name);
        Assert.IsTrue(rows.Any(r => r.LineCount is { } count && System.Text.RegularExpressions.Regex.IsMatch(count, "^ · \\+[0-9]+$")),
                      string.Join(" | ", rows.Select(r => r.Line)));
        var ended = Screens.Board(s, ActivityPeriod.All, null, Clock, Utc).Lanes.Single(l => l.Column == ActivityColumn.Done).Ended!;
        Assert.IsTrue(ended.Days.SelectMany(d => d.Groups).All(g => g.Mark is not null));
    }

    // ---------------------------------------------------------------- the store: notices while behind, and files

    [TestMethod]
    public async Task BehindTheStoreKeepsItsWaitAndANewRequestNotifiesOnceAlsoAfterAStart()
    {
        var folder = Directory.CreateTempSubdirectory("founderizer-notices-").FullName;
        using var hub = new FakeHub();
        try
        {
            var notices = new ConcurrentQueue<Notice>();
            await using (var store = new OwnerStore(new StoreSettings { Folder = folder, Keys = new MemoryKeyStore("device-key-1") }))
            {
                store.Notified += (_, due) => { foreach (var n in due) notices.Enqueue(n); };
                await store.ConnectAsync(hub.Address.ToString());
                store.SetFront(true);
                for (var i = 0; i < 60 && hub.WaitReads == 0; i++) await Task.Delay(50);
                store.SetFront(false);
                Assert.AreEqual(KeyState.InHand, store.State.Key, "behind, the open app keeps its key");
                Assert.IsTrue(notices.IsEmpty, "the first reading is the baseline");
                var reads = hub.MobileReads;
                ((JsonArray)hub.Snapshot["needs"]!).Add(SampleFleet.Need(3, "Raise the ad budget?", "It sold out.", "manager", Now - 10, "Yes", "No"));
                hub.WaitToken = "boot.2.1";
                for (var i = 0; i < 80 && notices.IsEmpty; i++) await Task.Delay(50);
                Assert.AreEqual("Raise the ad budget?", notices.Single().Body, "a wake behind reads the fleet and notifies");
                Assert.IsTrue(hub.MobileReads > reads);
                Assert.IsFalse(hub.Server.Received.Any(r => r.Target.StartsWith("/ui/mobile/task/", StringComparison.Ordinal)), "no page behind");
            }
            // While the app was closed, request 4 came: the next start notifies it, and not 3 again.
            ((JsonArray)hub.Snapshot["needs"]!).Add(SampleFleet.Need(4, "Renew the domain?", "It ends Friday.", "manager", Now - 5, "Yes", "No"));
            hub.WaitToken = "boot.3.1";
            notices.Clear();
            await using (var again = new OwnerStore(new StoreSettings { Folder = folder, Keys = new MemoryKeyStore("device-key-1") }))
            {
                again.Notified += (_, due) => { foreach (var n in due) notices.Enqueue(n); };
                again.Unlock();
                await again.RefreshAsync();
                CollectionAssert.AreEqual(new long?[] { 4 }, notices.Select(n => n.Need).ToArray());
            }
        }
        finally
        {
            Directory.Delete(folder, recursive: true);
        }
    }

    [TestMethod]
    public async Task AFileWhoseReadFailedIsNotLoadedUntilAReadWorks()
    {
        var folder = Directory.CreateTempSubdirectory("founderizer-files-").FullName;
        using var hub = new FakeHub();
        try
        {
            await using var store = new OwnerStore(new StoreSettings { Folder = folder, Keys = new MemoryKeyStore("device-key-1") });
            await store.ConnectAsync(hub.Address.ToString());
            store.Unlock();
            await store.RefreshAsync();
            var file = new MessageAttachment(77, "missing.csv", "text/csv", 10, new string('d', 64), Now);
            var failed = false;
            try { await store.FileAsync(file); } catch (Exception) { failed = true; }
            Assert.IsTrue(failed);
            Assert.IsTrue(store.State.FilesUnloaded.Contains(77));
            Assert.IsFalse(store.State.FilesReading.Contains(77));
            Assert.AreEqual("Not loaded", Screens.Tile(store.State, file, DateTimeOffset.UtcNow).Words);
        }
        finally
        {
            Directory.Delete(folder, recursive: true);
        }
    }
}
