using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using Founderizer.Core;
using Founderizer.Windows.Fleet;
using Founderizer.Windows.Navigation;
using Founderizer.Windows.Pages;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace Founderizer.Windows.Tests;

[TestClass]
public sealed class WindowTests
{
    private static readonly ScreenContext British = new(TimeZoneInfo.Local, CultureInfo.GetCultureInfo("en-GB"));

    private static StoreState SampleAt1512(string? ask = null, string? reading = null)
    {
        Environment.SetEnvironmentVariable("FOUNDERIZER_SAMPLE_CLOCK", "15:12");
        Environment.SetEnvironmentVariable("FOUNDERIZER_SAMPLE_ASK", ask);
        Environment.SetEnvironmentVariable("FOUNDERIZER_READING", reading);
        try { return new SampleSource().State; }
        finally
        {
            Environment.SetEnvironmentVariable("FOUNDERIZER_SAMPLE_CLOCK", null);
            Environment.SetEnvironmentVariable("FOUNDERIZER_SAMPLE_ASK", null);
            Environment.SetEnvironmentVariable("FOUNDERIZER_READING", null);
        }
    }

    [TestMethod]
    public void TheSampleFleetGivesThePaneOfPictureOne()
    {
        var pane = Screens.Pane(SampleAt1512(), Page.Chat("manager"), DateTimeOffset.UtcNow, British);
        Assert.IsTrue(pane.ShowsNeeds);
        Assert.AreEqual(2, pane.NeedsCount);
        Assert.IsTrue(pane.ShowsSearch);
        var rows = pane.Agents;
        CollectionAssert.AreEqual(new[] { "Fleet Manager", "Wren", "Theo", "Pax", "Orla" }, rows.Select(r => r.Label).ToArray());
        CollectionAssert.AreEqual(new[] { null, "Customer Support", "Developer", "DevOps", "Marketing" },
            rows.Select(r => r.Role).ToArray());
        // Each row's time is its chat's last message (the Mac's rule of 14 November 2026, ChatList.lastTime), also while the
        // line names a task: Wren 14:31 and Theo 13:12, where picture 1 drew 15:06 and 15:00.
        CollectionAssert.AreEqual(new[] { "15:04", "14:31", "13:12", "12:12", "14:46" }, rows.Select(r => r.Time).ToArray());
        Assert.IsTrue(rows[0].Line!.StartsWith("Yes. Marketing has the email ready, and Developer", StringComparison.Ordinal));
        Assert.AreEqual("Answer today's support tickets", rows[1].Line);
        Assert.AreEqual("Fix the checkout error on iPhone", rows[2].Line);
        Assert.IsTrue(rows[3].Line!.StartsWith("Backups ran at 03:00 and I tested one restore.", StringComparison.Ordinal));
        Assert.AreEqual("Write the spring sale email", rows[4].Line);
        CollectionAssert.AreEqual(new[] { true, false, false, false, false }, rows.Select(r => r.Selected).ToArray());
        // At work, so their marks and lines move: Customer Support and Developer. Marketing's task waits for his answer.
        CollectionAssert.AreEqual(new[] { false, true, true, false, false }, rows.Select(r => r.LineMoves).ToArray());
        CollectionAssert.AreEqual(new[] { false, true, true, false, false }, rows.Select(r => r.Mark.Moves).ToArray());
        // The marks of the pictures: a lime sparkle, a coral flower, a mint drop, a sky circle, an orchid hexagon.
        CollectionAssert.AreEqual(
            new[] { (GlyphKind.Sparkle, 2), (GlyphKind.Flower, 0), (GlyphKind.Drop, 3), (GlyphKind.Circle, 4), (GlyphKind.Hexagon, 7) },
            rows.Select(r => (r.Mark.Kind, r.Mark.Look.Tone)).ToArray());
    }

    [TestMethod]
    public void NothingMovesWithLessMotion()
    {
        var pane = Screens.Pane(SampleAt1512(), Page.Chat("manager"), DateTimeOffset.UtcNow, British, reduceMotion: true);
        Assert.IsFalse(pane.Agents.Any(r => r.LineMoves || r.Mark.Moves));
    }

    [TestMethod]
    public void TheWindowOpensOnNeedsYouWhileARequestWaits()
    {
        // The Mac's FleetStore.home and the library's Screens.FirstPage: picture 1 shows the manager's chat instead.
        Assert.AreEqual(Page.Needs, Screens.FirstPage(SampleAt1512()));
    }

    [TestMethod]
    public void TheSampleReadsCurrent()
    {
        var state = SampleAt1512();
        Assert.IsTrue(state.ShowsCurrent(DateTimeOffset.UtcNow));
        Assert.IsNull(Screens.Line(state, DateTimeOffset.UtcNow));
    }

    [TestMethod]
    public void TheSampleGivesTheChatOfPictureOne()
    {
        var chat = Screens.Chat(SampleAt1512(), "manager", DateTimeOffset.UtcNow, British);
        // Each request stands at the time it was raised (the Mac's rule of 14 November 2026), before his message of 15:03,
        // where picture 1 drew them at the end; the sample's chat is its whole history, so they stand at all.
        CollectionAssert.AreEqual(new[] { ChatRowKind.Stamp, ChatRowKind.Request, ChatRowKind.Request, ChatRowKind.Message, ChatRowKind.Reply },
            chat.Rows.Select(r => r.Kind).ToArray());
        Assert.AreEqual("Today 14:32", chat.Rows[0].Text);
        Assert.AreEqual("Can we start the spring sale on Monday?", chat.Rows[3].Text);
        // The two requests in the order raised, each with its options and "Show all".
        var cards = chat.Rows.Where(r => r.Request is not null).Select(r => r.Request!).ToArray();
        CollectionAssert.AreEqual(new[] { "Refund an order from 45 days ago?", "Send the spring sale email on Monday?" }, cards.Select(c => c.Title).ToArray());
        CollectionAssert.AreEqual(new[] { "Refund it", "Offer a 20% voucher", "Say no, politely" }, cards[0].Options.Labels.ToArray());
        Assert.AreEqual("From Fleet Manager · 14:32", cards[0].From);
        Assert.IsTrue(cards.All(c => c.MoreClosed == "Show all" && !c.Folded));
        Assert.AreEqual("Message Fleet Manager", chat.Composer.Placeholder);
        Assert.IsFalse(chat.Composer.CanSend);
        Assert.AreEqual(("Fleet Manager", (string?)null, "Claude Code", "hub"), (chat.Panel.Label, chat.Panel.Role, chat.Panel.Provider, chat.Panel.Machine));
    }

    [TestMethod]
    public void HisAskGivesTheThinkingLineOfPictureTwo()
    {
        var state = SampleAt1512(ask: "Which order is it?");
        var chat = Screens.Chat(state, "wren", DateTimeOffset.UtcNow, British);
        Assert.AreEqual(ChatWaiting.Working, chat.Waiting?.Line.Says);
        Assert.IsTrue(chat.Waiting!.Shows && chat.Waiting.Line.Moving && chat.WaitingMark.Moves);
        Assert.AreEqual("Which order is it?", chat.Rows[^1].Text);
        Assert.AreEqual("Customer Support", chat.Panel.Role);
        var row = Screens.Pane(state, Page.Chat("wren"), DateTimeOffset.UtcNow, British).Agents.First(r => r.Name == "wren");
        Assert.AreEqual(("You: Which order is it?", "15:11"), (row.Line, row.Time));
    }

    /// <summary>An opened Ended lane draws again only the rows that changed (a week of a busy fleet is hundreds of rows):
    /// each line has its own key, and the same model gives equal lines, so a row keeps its view and the keyboard's
    /// focus.</summary>
    [TestMethod]
    public void AnOpenedEndedLaneKeepsEachRowThatDidNotChange()
    {
        var state = SampleAt1512();
        EndedModel End() => Screens.Board(state, ActivityPeriod.Week, null, DateTimeOffset.UtcNow, British).Lanes[2].Ended!;
        var (first, days) = EndedRows.Of(End());
        var again = EndedRows.Of(End());
        CollectionAssert.AreEqual(first.ToList(), again.First.ToList());
        var items = EndedRows.Items(days);
        CollectionAssert.AreEqual(items, EndedRows.Items(again.Days));
        Assert.AreEqual(items.Count, items.Select(i => i.Key).Distinct().Count());
        Assert.IsTrue(items.Count > 1 && items[0].Line is null && items[1].Line is not null);
    }

    /// <summary>The Mac's restRows: a row of several tasks says "×N" and opens them under it, each with its time, and a
    /// row of one task says its state word when its result is not checked.</summary>
    [TestMethod]
    public void ARowOfSeveralEndedTasksSaysItsNumberAndOpensItsRuns()
    {
        var end = new EndedModel
        {
            Days = ValueList.Of(new[] { new EndedTaskDay("Today", ValueList.Of(new[] {
                new EndedGroup("group-1", "Check the example queue", "vps", "Vps", "×2",
                    ValueList.Of(new[] { new EndedTask(2, "Check the example queue", "15:00"), new EndedTask(1, "Check the example queue", "14:00") })),
                new EndedGroup("group-3", "Draft the example reply", "vps", "Vps", "Awaiting check",
                    ValueList.Of(new[] { new EndedTask(3, "Draft the example reply", "13:00") })) })) }),
        };
        var (_, days) = EndedRows.Of(end);
        var closed = EndedRows.Items(days);
        CollectionAssert.AreEqual(new[] { "day-Today", "group-1", "group-3" }, closed.Select(i => i.Key).ToArray());
        Assert.AreEqual(("×2", false), (closed[1].Line!.Note, closed[1].Line!.Opened));
        Assert.AreEqual(("Awaiting check", (ValueList<EndedLine>?)null), (closed[2].Line!.Note, closed[2].Line!.Runs));
        var opened = EndedRows.Items(days, new HashSet<string> { "group-1" });
        CollectionAssert.AreEqual(new[] { "day-Today", "group-1", "run-2", "run-1", "group-3" }, opened.Select(i => i.Key).ToArray());
        Assert.IsTrue(opened[1].Line!.Opened);
        Assert.AreEqual(("15:00", true, 2L), (opened[2].Line!.Note, opened[2].Line!.Indent, opened[2].Line!.Id));
        // With a row of runs open, each line still has its own key, and the same model gives equal lines: an opened
        // row and its runs keep their views and the keyboard's focus when the store changes.
        Assert.AreEqual(opened.Count, opened.Select(i => i.Key).Distinct().Count());
        CollectionAssert.AreEqual(opened, EndedRows.Items(EndedRows.Of(end).Days, new HashSet<string> { "group-1" }));
    }

    /// <summary>A door card's details are the hub's one fenced block (hub.py door_script_details): the window parses them
    /// as they come, so the script is one code block, as the Mac draws it (MessageText.script). A second fence around
    /// them gave an empty block, the script as plain lines, and a second empty block.</summary>
    [TestMethod]
    public void ADoorCardsScriptIsOneCodeBlock()
    {
        Environment.SetEnvironmentVariable("FOUNDERIZER_SAMPLE_STATE", "door");
        try
        {
            var hand = Screens.Needs(SampleAt1512(), 3, null, DateTimeOffset.UtcNow, British).AtHand!;
            Assert.AreEqual(("Run one root script on web-1?", true), (hand.Title, hand.DetailsIsCode));
            var blocks = MessageBlock.Parse(hand.Details!);
            Assert.AreEqual(1, blocks.Count);
            Assert.AreEqual(MessageBlock.Kinds.Code, blocks[0].Kind);
            StringAssert.StartsWith(blocks[0].Text, "#!/bin/sh\nset -eu\nfind /srv/example-shop/releases");
            StringAssert.EndsWith(blocks[0].Text.TrimEnd('\n'), "df -h /srv/example-shop | tail -n 1");
            Assert.AreEqual(3, MessageBlock.Parse("```\n" + hand.Details + "\n```").Count);
        }
        finally
        {
            Environment.SetEnvironmentVariable("FOUNDERIZER_SAMPLE_STATE", null);
        }
    }

    /// <summary>The sample's state "card" for the pictures of the Mac's request card (Founderizer 0.1.239): a task of steps
    /// with a command stands on the front, with no link, from the leading edge; a request with details says Details with
    /// its chevron; a long reason with no details folds and stands in the middle with its task of one paragraph.</summary>
    [TestMethod]
    public void TheSampleCardStateHasTheMacsCardParts()
    {
        Environment.SetEnvironmentVariable("FOUNDERIZER_SAMPLE_STATE", "card");
        try
        {
            var state = SampleAt1512();
            RequestBody Step(long id) => Screens.Needs(state, id, null, DateTimeOffset.UtcNow, British).AtHand!.Body;
            var task = Step(4);
            Assert.AreEqual((null, false, false), (task.MoreClosed, task.CentredClosed, task.Task is null));
            Assert.IsTrue(task.TaskBlocks.Any(b => b.Kind == MessageBlock.Kinds.Code && b.Text.StartsWith("sudo systemctl enable")));
            var details = Step(5);
            Assert.AreEqual(("Details", true, true), (details.MoreClosed, details.MoreChevron, details.Short));
            var folded = Step(6);
            Assert.AreEqual(("Show all", false, true), (folded.MoreClosed, folded.Short, folded.CentredClosed));
        }
        finally
        {
            Environment.SetEnvironmentVariable("FOUNDERIZER_SAMPLE_STATE", null);
        }
    }

    [TestMethod]
    public void TheSampleGivesNeedsYouAndTheTasksOfPicturesThreeAndFour()
    {
        var state = SampleAt1512();
        var needs = Screens.Needs(state, null, null, DateTimeOffset.UtcNow, British);
        CollectionAssert.AreEqual(new[] { "Send the spring sale email on Monday?", "Refund an order from 45 days ago?" },
            needs.Cards.Select(c => c.Title).ToArray());
        Assert.IsTrue(needs.Cards[0].Selected && needs.Cards[0].Waits && !needs.Cards[1].Waits);
        Assert.AreEqual(("Fleet Manager · 25 min ago", "Details"), (needs.AtHand!.From, needs.AtHand.MoreClosed));

        var board = Screens.Board(state, ActivityPeriod.Week, null, DateTimeOffset.UtcNow, British);
        CollectionAssert.AreEqual(new[] { ("In progress", 2), ("Waiting", 1), ("Ended", 3) }, board.Lanes.Select(l => (l.Title, l.Count)).ToArray());
        Assert.AreEqual("Send the spring sale email on Monday?", board.Lanes[1].Cards[0].OwnerLine);
        Assert.AreEqual("Show all", board.Lanes[2].Ended!.RestWords);

        var task = Screens.Task(state, 2, DateTimeOffset.UtcNow, British)!;
        Assert.AreEqual("Some orders fail at checkout on iPhone. Find the cause, fix it and test it.", task.Asks);
        Assert.AreEqual("Started: Fix the checkout error on iPhone.", task.Notes.Single().Text);
        Assert.AreEqual(("Working", true, true), (task.Controls!.StateWord, task.Controls.ShowsPause, task.Controls.ShowsStop));
        Assert.AreEqual("Guide this task…", task.Guidance!.Placeholder);
        CollectionAssert.AreEqual(new[] { "Asked by", "Agent", "State", "Last activity", "Done when" }, task.Facts.Select(f => f.Label).ToArray());
    }

    [TestMethod]
    public void EachStateOfTheSecondSetIsAReadingOfTheLibrary()
    {
        // The sample's states of the second set of pictures decode as the hub's own reads, and every page's model takes
        // them (a state that the decoder refuses would leave the picture's window empty).
        foreach (var name in new[] { "code-refused", "not-enrolled", "no-answer", "not-sent", "answered", "all-answered",
                                     "usage", "marks", "failed", "paused", "stopping", "reading", "files", "notify",
                                     "markdown", "no-messages", "first-read" })
        {
            Environment.SetEnvironmentVariable("FOUNDERIZER_SAMPLE_STATE", name);
            try
            {
                var state = SampleAt1512();
                var now = DateTimeOffset.UtcNow;
                var page = Screens.FirstPage(state);
                Assert.IsNotNull(Screens.Pane(state, page, now, British), name);
                Assert.IsNotNull(Screens.Settings(state, "", now, British), name);
                if (state.Fleet is null) continue;
                foreach (var agent in state.Fleet.Agents) Assert.IsNotNull(Screens.Chat(state, agent.Name, now, British), name);
                Assert.IsNotNull(Screens.Needs(state, null, null, now, British), name);
                Assert.IsNotNull(Screens.Board(state, ActivityPeriod.Week, null, now, British), name);
            }
            finally
            {
                Environment.SetEnvironmentVariable("FOUNDERIZER_SAMPLE_STATE", null);
            }
        }
        Environment.SetEnvironmentVariable("FOUNDERIZER_SAMPLE_STATE", "answered");
        try
        {
            var answered = SampleAt1512();
            var card = Screens.Chat(answered, "manager", DateTimeOffset.UtcNow, British).Rows.First(r => r.Request?.Id == 1).Request!;
            Assert.IsTrue(card.Folded);
            Assert.AreEqual("Offer a 20% voucher", card.AnswerWords);
            Environment.SetEnvironmentVariable("FOUNDERIZER_SAMPLE_STATE", "paused");
            Assert.AreEqual("Paused", Screens.Task(SampleAt1512(), 2, DateTimeOffset.UtcNow, British)!.Controls!.StateWord);
            Environment.SetEnvironmentVariable("FOUNDERIZER_SAMPLE_STATE", "not-sent");
            Assert.AreEqual("Not sent", Screens.PendingBar(SampleAt1512(), DateTimeOffset.UtcNow)!.State);
        }
        finally
        {
            Environment.SetEnvironmentVariable("FOUNDERIZER_SAMPLE_STATE", null);
        }
    }

    [TestMethod]
    public void TheThirdSetsStatesAreTheLibrarysModels()
    {
        // The states of the third set of pictures, as the library's models give them to the pages.
        var sample = SampleAt1512();
        var accepted = Screens.Task(sample, 4, DateTimeOffset.UtcNow, British)!;
        Assert.AreEqual(("Renewed the certificate", "Accepted by Fleet Manager"), (accepted.Result!.What, accepted.Result.Check));
        Assert.IsTrue(accepted.Result.CheckOpensFolded);
        Assert.AreEqual(("Checked outputs", "View outputs", true), (accepted.Result.Outputs!.Heading, accepted.Result.Outputs.ViewWords, accepted.Result.Outputs.Enabled));
        Assert.IsNull(accepted.Controls);
        var waiting = Screens.Task(sample, 3, DateTimeOffset.UtcNow, British)!;
        Assert.AreEqual(("Waiting for", "Fleet Manager", "manager"), (waiting.WaitingLabel, waiting.WaitingValue, waiting.WaitingAgent));
        try
        {
            Environment.SetEnvironmentVariable("FOUNDERIZER_SAMPLE_STATE", "failed");
            var failed = Screens.Task(SampleAt1512(), 6, DateTimeOffset.UtcNow, British)!.Result!;
            Assert.AreEqual("Waiting for Fleet Manager's check", failed.Check);
            Assert.IsNull(failed.Outputs);
            Assert.IsTrue(failed.What.StartsWith("The post did not go live.", StringComparison.Ordinal));

            Environment.SetEnvironmentVariable("FOUNDERIZER_SAMPLE_STATE", "markdown");
            var markdown = Screens.Chat(SampleAt1512(), "pax", DateTimeOffset.UtcNow, British);
            Assert.IsFalse(markdown.Waiting is { Shows: true });
            var reply = markdown.Rows.Last(r => r.Kind == ChatRowKind.Reply);
            CollectionAssert.AreEqual(new[] { MessageBlock.Kinds.Heading, MessageBlock.Kinds.Paragraph, MessageBlock.Kinds.Item, MessageBlock.Kinds.Item,
                                              MessageBlock.Kinds.Item, MessageBlock.Kinds.Paragraph, MessageBlock.Kinds.Code, MessageBlock.Kinds.Table,
                                              MessageBlock.Kinds.Paragraph }, reply.Blocks.Select(b => b.Kind).ToArray());
            Assert.AreEqual("https://example.com/backups/2026-11-13", reply.Blocks[^1].Runs.Single(r => r.Link is not null).Link);

            Environment.SetEnvironmentVariable("FOUNDERIZER_SAMPLE_STATE", "no-messages");
            var empty = Screens.Chat(SampleAt1512(), "theo", DateTimeOffset.UtcNow, British);
            Assert.AreEqual((true, false, "No messages with Theo yet"), (empty.Empty, empty.Loading, empty.EmptyWords));

            Environment.SetEnvironmentVariable("FOUNDERIZER_SAMPLE_STATE", "first-read");
            var first = Screens.Chat(SampleAt1512(), "orla", DateTimeOffset.UtcNow, British);
            Assert.AreEqual((false, true, "Reading\u2026"), (first.Empty, first.Loading, first.LoadingWords));
        }
        finally
        {
            Environment.SetEnvironmentVariable("FOUNDERIZER_SAMPLE_STATE", null);
        }
    }

    [TestMethod]
    public void TheNeedsYouRowHasNoCountWhenNothingIsOpen()
    {
        // The pill of picture 12's fault: with both requests answered and Needs you open, the row stays (selected) and
        // its pill showed "0"; the approved picture and the Mac's needsRow show no count. Two open requests show "2".
        Environment.SetEnvironmentVariable("FOUNDERIZER_SAMPLE_STATE", "all-answered");
        try
        {
            var answered = Screens.Pane(SampleAt1512(), Page.Needs, DateTimeOffset.UtcNow, British);
            Assert.IsTrue(answered.ShowsNeeds);
            Assert.AreEqual(0, answered.NeedsCount);
            Assert.IsNull(PaneMarks.NeedsBadge(answered));
            Environment.SetEnvironmentVariable("FOUNDERIZER_SAMPLE_STATE", null);
            Assert.AreEqual("2", PaneMarks.NeedsBadge(Screens.Pane(SampleAt1512(), Page.Needs, DateTimeOffset.UtcNow, British)));
        }
        finally
        {
            Environment.SetEnvironmentVariable("FOUNDERIZER_SAMPLE_STATE", null);
        }
    }

    [TestMethod]
    public void TheScrollReadingHasAChatOfTwoThousand()
    {
        var state = SampleAt1512(reading: "long-chat");
        Assert.AreEqual(SampleSource.LongChat, state.Items("wren").Count);
        // The Mac's "Earlier messages": the newest 60 items at first, and each press adds as many again.
        var first = Screens.Chat(state, "wren", DateTimeOffset.UtcNow, British);
        Assert.AreEqual("Earlier messages", first.Earlier);
        var chat = Screens.Chat(state, "wren", DateTimeOffset.UtcNow, British, shown: SampleSource.LongChat);
        Assert.IsNull(chat.Earlier);
        Assert.IsTrue(chat.Rows.Count > SampleSource.LongChat, "stamps come between the days");
    }

    [TestMethod]
    public void TheSampleGivesTheSettingsOfPictureSix()
    {
        var state = SampleAt1512();
        var settings = Screens.Settings(state, "http://100.84.1.2:8765", DateTimeOffset.UtcNow, British);
        Assert.AreEqual(("In hand", StateTone.Online), (settings.KeyWords, settings.KeyTone));
        Assert.AreEqual(("This PC's address", "PC · 100.84.1.9", "just now"), (settings.Address!.Title, settings.Address.Detail, settings.Address.Value));
        Assert.IsTrue(settings.ShowsForget);
        Assert.IsNull(settings.LastReading);
        Assert.IsNull(settings.Pending);
        Assert.AreEqual(Credit.Founderizer, settings.Credit);
    }

    [TestMethod]
    public void BackAndForwardMoveAlongTheHistory()
    {
        var history = new History(Page.Needs);
        Assert.IsFalse(history.CanGoBack);
        history.Go(Page.Chat("manager"));
        history.Go(Page.Tasks);
        history.Go(Page.Tasks); // the same page again moves nothing
        history.GoBack();
        Assert.AreEqual(Page.Chat("manager"), history.Current);
        Assert.IsTrue(history.CanGoForward);
        history.GoBack();
        Assert.AreEqual(Page.Needs, history.Current);
        Assert.IsFalse(history.CanGoBack);
        history.GoForward();
        Assert.AreEqual(Page.Chat("manager"), history.Current);
        history.Go(Page.Settings); // a new page clears the way forward
        Assert.IsFalse(history.CanGoForward);
        history.Forget(p => p == Page.Chat("manager"));
        history.GoBack();
        Assert.AreEqual(Page.Needs, history.Current);
        history.Start(Page.Tasks); // the launch's first page leaves no way back
        Assert.IsFalse(history.CanGoBack || history.CanGoForward);

        // A manager that its setup renamed (piece U3b): its pages, here and on both lists, go to its new name, so that the
        // window neither leaves its setup for Tasks nor goes Back to an agent that is gone.
        history.Go(Page.Chat("juno"));
        history.Go(Page.Needs);
        history.Go(Page.Chat("juno"));
        history.GoBack();
        history.Rename("juno", "nova");
        Assert.AreEqual(Page.Needs, history.Current);
        history.GoBack();
        Assert.AreEqual(Page.Chat("nova"), history.Current, "the back list");
        history.GoForward();
        history.GoForward();
        Assert.AreEqual(Page.Chat("nova"), history.Current, "the forward list");
        history.Rename("nova", "vera");
        Assert.AreEqual(Page.Chat("vera"), history.Current, "the current page");
    }

    [TestMethod]
    public void TheLaunchArgumentOpensAPageAsOnTheMac()
    {
        Assert.AreEqual(Page.Chat("manager"), History.Asked(["Founderizer.exe", "-openPage", "agent.manager"]));
        Assert.AreEqual(Page.Needs, History.Asked(["x", "-openPage", "needs"]));
        Assert.AreEqual(Page.Tasks, History.Asked(["x", "-openPage", "tasks"]));
        Assert.AreEqual(Page.Settings, History.Asked(["x", "-openPage", "settings"]));
        Assert.AreEqual(Page.OfTask(2), History.Asked(["x", "-openPage", "task.2"]));
        Assert.IsNull(History.Asked(["x", "-openPage", "task.x"]));
        Assert.IsNull(History.Asked(["x"]));
        Assert.IsNull(History.Asked(["x", "-openPage", "agent."]));
    }

    [TestMethod]
    public void ATasksThreadIsOneFoldForEachRunAndARowForEachStepOfAnOpenRun()
    {
        // The fourth set's 2a to 2c: Customer Support's task with 8 steps (one failed), the agent's message, 2 steps, and a
        // permission of Bash that waits, as the sample's state "steps" gives them to the library.
        TaskPageModel task;
        try
        {
            Environment.SetEnvironmentVariable("FOUNDERIZER_SAMPLE_STATE", "steps");
            task = Screens.Task(SampleAt1512(), 1, DateTimeOffset.UtcNow, British)!;
        }
        finally
        {
            Environment.SetEnvironmentVariable("FOUNDERIZER_SAMPLE_STATE", null);
        }
        var folded = TaskThreadRows.Of(task.Thread, new HashSet<string>()).ToList();
        CollectionAssert.AreEqual(new[] { RowKind.Reply, RowKind.Fold, RowKind.Reply, RowKind.Fold, RowKind.Fold },
                                  folded.Select(r => r.Kind).ToArray());
        var run = (FoldRowModel)folded[1].Model;
        Assert.AreEqual(("8 steps", "1 failed", true, false, FoldMark.Steps), (run.Title, run.Status, run.Warn, run.Open, run.Mark));
        var second = (FoldRowModel)folded[3].Model;
        Assert.AreEqual(("2 steps", "", false), (second.Title, second.Status, second.Warn));
        var waits = (FoldRowModel)folded[4].Model;
        Assert.AreEqual((FoldMark.Hand, "Bash", "Waiting", true, false), (waits.Mark, waits.Title, waits.Status, waits.Warn, waits.Open));
        Assert.AreEqual("curl -s -X POST https://help.example.com/api/tickets/10517/reply -d @replies/10517.json", waits.Code);
        // The panel: the AI provider, and the file that a completed step changed.
        Assert.AreEqual("Claude Code", task.Facts.Single(f => f.Label == "AI provider").Value);
        Assert.AreEqual(("replies/make_reply.py", "Modify", "+4", "−1"),
                        (task.ChangedFiles!.Rows[0].Path, task.ChangedFiles.Rows[0].Action, task.ChangedFiles.Rows[0].Added, task.ChangedFiles.Rows[0].Removed));

        var opened = TaskThreadRows.Of(task.Thread, new HashSet<string> { folded[1].Key, folded[4].Key }).ToList();
        var steps = opened.Where(r => r.Kind == RowKind.Step).ToList();
        // The steps stand on one box: 4.5 under the fold (the Mac's line of 16.5 + 8 + the box's 10 = 34.5 under a face of
        // 20), then no room between rows, the box's own room inside it.
        CollectionAssert.AreEqual(new[] { 4.5, 0, 0, 0, 0, 0, 0, 0 }, steps.Select(r => r.Gap).ToArray());
        var models = steps.Select(r => (StepRow)r.Model).ToList();
        CollectionAssert.AreEqual(new[] { FoldMark.Fetch, FoldMark.Read, FoldMark.Read, FoldMark.Search, FoldMark.Execute, FoldMark.Edit, FoldMark.Execute, FoldMark.Execute },
                                  models.Select(m => m.Mark).ToArray());
        CollectionAssert.AreEqual(new[] { "Done", "Done", "Done", "Done", "Failed", "Done", "Done", "Done" }, models.Select(m => m.Step.Status).ToArray());
        Assert.IsTrue(models[4].Step.Orange && !models[3].Step.Orange);
        Assert.IsTrue(models[0].First && !models[0].Last && models[7].Last && !models[7].First);
        Assert.IsTrue(((FoldRowModel)opened.Single(r => r.Key == folded[4].Key).Model).Open);

        // The Mac's pitch of 36.5 pt between activity rows: 16.5 under a closed fold's face of 20, 20 under an opened
        // fold's content, 21 under the agent's words and under a run's box; inside the box 14.5 over a step under a
        // closed one (its face of 22), 20 under an opened one, 10 over the first.
        CollectionAssert.AreEqual(new[] { 21, 21, 16.5, 21, 16.5 }, folded.Select(r => r.Gap).ToArray());
        Assert.AreEqual((16.5, 20.0, 21.0), (TaskThreadRows.Under(RowKind.Fold, false), TaskThreadRows.Under(RowKind.Fold, true),
                                             TaskThreadRows.Under(RowKind.Reply, false)));
        Assert.AreEqual(19.0, TaskThreadRows.Under(RowKind.EarlierActivity, false));
        CollectionAssert.AreEqual(new[] { 10, 14.5, 14.5, 14.5, 14.5, 14.5, 14.5, 14.5 }, models.Select(TaskThreadRows.StepTop).ToArray());
        var oneOpen = TaskThreadRows.Of(task.Thread, new HashSet<string> { folded[1].Key, models[2].Step.Key }).Where(r => r.Kind == RowKind.Step)
            .Select(r => TaskThreadRows.StepTop((StepRow)r.Model)).ToArray();
        CollectionAssert.AreEqual(new[] { 10, 14.5, 14.5, 20, 14.5, 14.5, 14.5, 14.5 }, oneOpen);
        // Under the last step, inside the box: the Mac's 20 + 10 under its line (24.5 under a face of 22, 30 under an
        // opened step's content), then 20 under the box: 66.5 from a closed last step to the next row.
        CollectionAssert.AreEqual(new[] { 0, 0, 0, 0, 0, 0, 0, 24.5 }, models.Select(TaskThreadRows.StepBottom).ToArray());
        Assert.AreEqual(30.0, TaskThreadRows.StepBottom(models[7] with { Open = true }));
        var afterRun = opened.SkipWhile(r => r.Kind != RowKind.Step).SkipWhile(r => r.Kind == RowKind.Step).First();
        Assert.AreEqual((RowKind.Reply, 20.0), (afterRun.Kind, afterRun.Gap));
        Assert.AreEqual(19.0, TaskThreadRows.Of(task.Thread, new HashSet<string>(), RowKind.Line, TaskThreadRows.UnderOverLine).First().Gap);
    }

    private static TaskPageModel SampleTask(string state, long id)
    {
        try
        {
            Environment.SetEnvironmentVariable("FOUNDERIZER_SAMPLE_STATE", state);
            return Screens.Task(SampleAt1512(), id, DateTimeOffset.UtcNow, British)!;
        }
        finally
        {
            Environment.SetEnvironmentVariable("FOUNDERIZER_SAMPLE_STATE", null);
        }
    }

    [TestMethod]
    public void TheFifthSetsRowsAreTheMacs()
    {
        // 3: a thought is a step of its run, and the run counts it; opened, it says its words.
        var thinking = SampleTask("thinking", 1);
        var run = (FoldRowModel)TaskThreadRows.Of(thinking.Thread, new HashSet<string>()).First(r => r.Kind == RowKind.Fold).Model;
        Assert.AreEqual("4 steps", run.Title);
        var steps = TaskThreadRows.Of(thinking.Thread, new HashSet<string> { run.Key }).Where(r => r.Kind == RowKind.Step)
            .Select(r => (StepRow)r.Model).ToList();
        Assert.AreEqual((FoldMark.Thought, "Thinking", ActivityRowKind.Thought), (steps[0].Mark, steps[0].Step.Title, steps[0].Step.Kind));

        // 2: an error ends the run of its attempt, a call with no finish says "Result unknown", and the next attempt is a
        // new run; the panel has the attempt.
        var error = SampleTask("error", 1);
        var rows = TaskThreadRows.Of(error.Thread, new HashSet<string>()).ToList();
        CollectionAssert.AreEqual(new[] { RowKind.Reply, RowKind.Fold, RowKind.Line, RowKind.Fold }, rows.Select(r => r.Kind).ToArray());
        Assert.AreEqual(new ThreadLine("The connection to the AI provider was lost: the program ended with code 1.", LineLook.Error), rows[2].Model);
        Assert.AreEqual(("4 steps", "3 steps"), (((FoldRowModel)rows[1].Model).Title, ((FoldRowModel)rows[3].Model).Title));
        var ended = TaskThreadRows.Of(error.Thread, new HashSet<string> { rows[1].Key }).Where(r => r.Kind == RowKind.Step).Select(r => ((StepRow)r.Model).Step.Status);
        Assert.AreEqual("Result unknown", ended.Last());
        Assert.AreEqual("Attempt 2 · Restarted 1 time", error.Facts.Single(f => f.Label == "Attempt").Value);

        // 1b: a Codex call opens on its output, its script, and the script's result.
        var script = SampleTask("script", 2);
        var call = script.Thread.Single(r => r.Kind == ThreadRowKind.Steps).Steps!.Rows[0];
        Assert.AreEqual(("rg -n postcode Sources/Checkout", "Script result"), (call.Title, call.ScriptResultTitle));
        Assert.IsTrue(call.Script!.StartsWith("exec: ", StringComparison.Ordinal) && call.ScriptResult!.StartsWith("Script completed", StringComparison.Ordinal));

        // 6a and 6b: a child agent's row and its own thread, with its head; the panel lists it.
        var child = SampleTask("child", 1);
        var agent = child.Thread.Single(r => r.Kind == ThreadRowKind.Steps).Steps!.Rows.Single(r => r.Child is not null);
        Assert.AreEqual(("Check the tracking of late parcels", FoldMark.Child), (agent.Title, TaskThreadRows.Mark(agent.Symbol)));
        Assert.AreEqual("Check the tracking of late parcels", child.ChildAgents!.Rows.Single().Name);
        Environment.SetEnvironmentVariable("FOUNDERIZER_SAMPLE_STATE", "child");
        try
        {
            var thread = Screens.ChildThread(SampleAt1512(), 1, agent.Child!, DateTimeOffset.UtcNow, British)!;
            var childRows = TaskThreadRows.Child(thread, new HashSet<string>()).ToList();
            Assert.AreEqual(new ChildHeadRow("Back", "Check the tracking of late parcels", "Attempt 1"), childRows[0].Model);
            CollectionAssert.AreEqual(new[] { RowKind.ChildHead, RowKind.Step, RowKind.Step, RowKind.Step, RowKind.Reply }, childRows.Select(r => r.Kind).ToArray());
            Assert.IsFalse(((StepRow)childRows[1].Model).Boxed);
            // The Mac's pitch of 36.5 pt between a child's steps: 14.5 over each step after a closed step's face of 22,
            // 20 after an opened one, 21 after the agent's words; 14 under the head.
            CollectionAssert.AreEqual(new[] { 21, 14, 14.5, 14.5, 14.5 }, childRows.Select(r => r.Gap).ToArray());
            var opened = TaskThreadRows.Child(thread, new HashSet<string> { childRows[2].Key }).ToList();
            CollectionAssert.AreEqual(new[] { 21, 14, 14.5, 20, 14.5 }, opened.Select(r => r.Gap).ToArray());
        }
        finally
        {
            Environment.SetEnvironmentVariable("FOUNDERIZER_SAMPLE_STATE", null);
        }

        // 7: a long thread holds more than the 80 rows that show, and the read that failed is over it.
        var earlier = SampleTask("earlier", 1);
        Assert.IsTrue(earlier.Thread.Count > StepWords.ShownAtOnce);
        Assert.AreEqual(StepWords.Unavailable, earlier.ActivityError);

        // 4, 5 and 8: the plan of the work that runs, his guidance, the parent task and the subtasks.
        Assert.AreEqual(4, SampleTask("plan", 1).LivePlan!.Count);
        Assert.AreEqual("Guidance · Attempt 1 · Read", SampleTask("guidance", 1).Thread.Single(r => r.Kind == ThreadRowKind.Guidance).Guidance!.Line);
        var subtasks = SampleTask("subtasks", 2);
        Assert.AreEqual("Parent task · Get the shop ready for the spring sale", subtasks.ParentTask!.Words);
        CollectionAssert.AreEqual(new[] { ("Test the checkout on Android", "Working"), ("Tell the customers whose orders failed", "Queued") },
                                  subtasks.Subtasks!.Rows.Select(r => (r.Title, r.Status)).ToArray());
    }

    [TestMethod]
    public async System.Threading.Tasks.Task TheSamplesCheckedOutputsListOpenAndClose()
    {
        // The fourth set's 1a to 1d on the sample: View outputs lists two files, View opens the certificate with its
        // facts, and Close takes the file and the list away.
        Environment.SetEnvironmentVariable("FOUNDERIZER_SAMPLE_CLOCK", "15:12");
        Environment.SetEnvironmentVariable("FOUNDERIZER_SAMPLE_STATE", "outputs");
        try
        {
            await using var sample = new SampleSource();
            sample.OpenTask(4);
            CheckedOutputsModel Outputs() => Screens.Task(sample.State, 4, DateTimeOffset.UtcNow, British)!.Result!.Outputs!;
            await sample.ListOutputsAsync();
            CollectionAssert.AreEqual(new[] { "outputs/T-4/certificate.txt", "outputs/T-4/shop-page.png" }, Outputs().Files.Select(f => f.Path).ToArray());
            Assert.AreEqual("Reload outputs", Outputs().ViewWords);
            await sample.ViewOutputAsync(Outputs().Files[0].File);
            var text = Outputs().Opened!;
            // Four lines and the file's last new line, which the Mac counts as a fifth (ArtifactSection): 5 × 18 + 16.
            Assert.AreEqual(("Verified download · 149 bytes", 106.0), (text.Download, text.TextHeight));
            Assert.AreEqual("1ef8ceae8fa177fdf1c15cdac6f3dc2c96a3d99b26b388f09ee903ba4bbedb83", text.Facts.Single(f => f.Label == "SHA-256").Value);
            await sample.ViewOutputAsync(Outputs().Files[1].File);
            Assert.AreEqual((1208, 680), (Outputs().Opened!.Width, Outputs().Opened!.Height));
            sample.CloseOutputs();
            Assert.AreEqual(("View outputs", 0), (Outputs().ViewWords, Outputs().Files.Count));
        }
        finally
        {
            Environment.SetEnvironmentVariable("FOUNDERIZER_SAMPLE_STATE", null);
            Environment.SetEnvironmentVariable("FOUNDERIZER_SAMPLE_CLOCK", null);
        }
    }
}
