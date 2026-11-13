using System;
using System.Globalization;
using System.Linq;
using Founderizer.Core;
using Founderizer.Windows.Fleet;
using Founderizer.Windows.Navigation;
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
        CollectionAssert.AreEqual(new[] { "Fleet Manager", "Customer Support", "Developer", "DevOps", "Marketing" },
            rows.Select(r => r.Label).ToArray());
        CollectionAssert.AreEqual(new[] { "15:04", "15:06", "15:00", "12:12", "14:46" }, rows.Select(r => r.Time).ToArray());
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
        CollectionAssert.AreEqual(new[] { ChatRowKind.Stamp, ChatRowKind.Message, ChatRowKind.Reply, ChatRowKind.Request, ChatRowKind.Request },
            chat.Rows.Select(r => r.Kind).ToArray());
        Assert.AreEqual("Today 15:03", chat.Rows[0].Text);
        Assert.AreEqual("Can we start the spring sale on Monday?", chat.Rows[1].Text);
        // The two requests at the end, in the order raised, each with its options and "Show all".
        var cards = chat.Rows.Where(r => r.Request is not null).Select(r => r.Request!).ToArray();
        CollectionAssert.AreEqual(new[] { "Refund an order from 45 days ago?", "Send the spring sale email on Monday?" }, cards.Select(c => c.Title).ToArray());
        CollectionAssert.AreEqual(new[] { "Refund it", "Offer a 20% voucher", "Say no, politely" }, cards[0].Options.Labels.ToArray());
        Assert.AreEqual("From Fleet Manager · 14:32", cards[0].From);
        Assert.IsTrue(cards.All(c => c.MoreClosed == "Show all" && !c.Folded));
        Assert.AreEqual("Message Fleet Manager", chat.Composer.Placeholder);
        Assert.IsFalse(chat.Composer.CanSend);
        Assert.AreEqual(("Fleet Manager", (string?)null, "Claude Code", "hub"), (chat.Panel.Label, chat.Panel.Under, chat.Panel.Provider, chat.Panel.Machine));
    }

    [TestMethod]
    public void HisAskGivesTheThinkingLineOfPictureTwo()
    {
        var state = SampleAt1512(ask: "Which order is it?");
        var chat = Screens.Chat(state, "wren", DateTimeOffset.UtcNow, British);
        Assert.AreEqual(ChatWaiting.Working, chat.Waiting?.Line.Says);
        Assert.IsTrue(chat.Waiting!.Shows && chat.Waiting.Line.Moving && chat.WaitingMark.Moves);
        Assert.AreEqual("Which order is it?", chat.Rows[^1].Text);
        Assert.AreEqual("Wren", chat.Panel.Under);
        var row = Screens.Pane(state, Page.Chat("wren"), DateTimeOffset.UtcNow, British).Agents.First(r => r.Name == "wren");
        Assert.AreEqual(("You: Which order is it?", "15:11"), (row.Line, row.Time));
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
                                     "usage", "marks", "failed", "paused", "stopping", "reading", "files", "notify" })
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
}
