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

    private static StoreState SampleAt1512()
    {
        Environment.SetEnvironmentVariable("FOUNDERIZER_SAMPLE_CLOCK", "15:12");
        try { return new SampleSource().State; }
        finally { Environment.SetEnvironmentVariable("FOUNDERIZER_SAMPLE_CLOCK", null); }
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
        Assert.IsNull(History.Asked(["x"]));
        Assert.IsNull(History.Asked(["x", "-openPage", "agent."]));
    }
}
