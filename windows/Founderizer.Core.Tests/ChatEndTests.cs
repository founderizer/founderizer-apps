using System.Linq;
using Microsoft.VisualStudio.TestTools.UnitTesting;
using static Founderizer.Core.Tests.SampleFleet;

namespace Founderizer.Core.Tests;

/// <summary>FleetCore's ChatEndTests, case for case (the owner, 14 November 2026: "it shows the Latest badge when there
/// are actually no more messages"). A chat and a task's thread ask the same rule, each with its own ChatEnd.</summary>
[TestClass]
public sealed class ChatEndTests
{
    [TestMethod]
    public void AChatThatOpensFollowsItsNewestRowAndShowsNoLatest()
    {
        var end = new ChatEnd();
        Assert.IsTrue(end.FollowsLatest);
        Assert.IsFalse(end.ShowsLatest);
    }

    [TestMethod]
    public void AScrollAwayFromTheEndShowsLatestUntilTheViewComesBack()
    {
        var end = new ChatEnd();
        end.Taken();
        end.Stands(600, moved: true);
        end.Rested(600, jumped: false);
        Assert.IsTrue(end.ShowsLatest);
        Assert.IsFalse(end.FollowsLatest);
        end.Taken();
        end.Stands(40, moved: true);
        end.Rested(40, jumped: false);
        Assert.IsFalse(end.ShowsLatest);
        Assert.IsTrue(end.FollowsLatest);
    }

    [TestMethod]
    public void AViewInHandAtItsEndShowsNoLatest()
    {
        var end = new ChatEnd();
        end.Taken();
        Assert.IsFalse(end.ShowsLatest);
        Assert.IsTrue(end.FollowsLatest);
        end.Rested(0, jumped: true);
        Assert.IsFalse(end.ShowsLatest);
        Assert.IsTrue(end.FollowsLatest);
    }

    [TestMethod]
    public void AViewThatComesToItsEndByAnyWayFollowsAgain()
    {
        var end = new ChatEnd();
        end.Taken();
        end.Stands(300, moved: true);
        end.Rested(300, jumped: false);
        Assert.IsTrue(end.ShowsLatest);
        end.Stands(0, moved: false);                // the window became taller
        Assert.IsFalse(end.ShowsLatest);
        Assert.IsTrue(end.FollowsLatest);
        end.Stands(800, moved: false);              // a long reply comes under it
        Assert.IsTrue(end.FollowsLatest);
        Assert.IsFalse(end.ShowsLatest);
    }

    [TestMethod]
    public void AViewThatLeavesItsEndByAnyWayStopsFollowingAndShowsLatest()
    {
        var end = new ChatEnd();
        end.Stands(3000, moved: true);
        Assert.IsTrue(end.ShowsLatest);
        Assert.IsFalse(end.FollowsLatest);
        end.Stands(0, moved: true);
        Assert.IsFalse(end.ShowsLatest);
        Assert.IsTrue(end.FollowsLatest);
    }

    [TestMethod]
    public void AJumpToAMatchFarBackStopsTheFollowingAndShowsLatest()
    {
        var end = new ChatEnd { FollowsLatest = false };
        end.Stands(14_000, moved: true);
        end.FollowsLatest = false;
        Assert.IsTrue(end.ShowsLatest);
        Assert.IsFalse(end.FollowsLatest);
        end.Stands(14_200, moved: false);
        Assert.IsTrue(end.ShowsLatest);
        Assert.IsFalse(end.FollowsLatest);
        end.FollowsLatest = true;                   // Latest brings the view to its end
        end.Stands(0, moved: true);
        Assert.IsFalse(end.ShowsLatest);
        Assert.IsTrue(end.FollowsLatest);
    }

    [TestMethod]
    public void AJumpToAMatchThatTheChatDrawsFirstStopsTheFollowing()
    {
        var end = new ChatEnd { FollowsLatest = false };
        end.Stands(9000, moved: false);
        Assert.IsFalse(end.FollowsLatest);
        end.FollowsLatest = false;
        Assert.IsTrue(end.ShowsLatest);
        end.Stands(9100, moved: false);
        Assert.IsFalse(end.FollowsLatest);
    }

    [TestMethod]
    public void AJumpToAMatchAtTheEndKeepsTheFollowingAndShowsNoLatest()
    {
        var end = new ChatEnd { FollowsLatest = false };
        end.FollowsLatest = false;
        Assert.IsFalse(end.ShowsLatest);
        Assert.IsTrue(end.FollowsLatest);
        end.Stands(0, moved: false);
        Assert.IsFalse(end.ShowsLatest);
        Assert.IsTrue(end.FollowsLatest);
    }

    [TestMethod]
    public void TheEndOfTheChatsOwnScrollNeverStopsTheFollowing()
    {
        var end = new ChatEnd();
        end.Stands(400, moved: false);
        end.Rested(400, jumped: true);
        Assert.IsTrue(end.FollowsLatest);
        Assert.IsFalse(end.ShowsLatest);
        end.Taken();
        end.Rested(400, jumped: false);
        Assert.IsTrue(end.ShowsLatest);
    }

    [TestMethod]
    public void TheEndIsLessThanAHundredPointsUnderTheView()
    {
        Assert.IsTrue(ChatEnd.IsEnd(0));
        Assert.IsTrue(ChatEnd.IsEnd(-30));
        Assert.IsTrue(ChatEnd.IsEnd(99));
        Assert.IsFalse(ChatEnd.IsEnd(100));
    }

    // ---------------------------------------------------------------- the time at the end of an agent's row

    /// <summary>FleetCore's ChatListTests.theRowsTimeIsTheTimeOfTheChatsLastMessage.</summary>
    [TestMethod]
    public void TheRowsTimeIsTheTimeOfTheChatsLastMessage()
    {
        var last = new MobilePreview(10, "agent", "Done.");
        Assert.AreEqual(10.0, ChatLine.LastTime(last));
        Assert.AreEqual(9.0, ChatLine.LastTime(new MobilePreview(9, "owner", "Is it live?")));
        // A task that moved after the message changes the line, and not the time.
        var moved = new MobileTaskHead(4, "The shop page", "working", "vps", "manager", 1, 1, LastActivity: 50);
        Assert.AreEqual("The shop page", ChatLine.Preview("vps", last, [moved]));
        Assert.AreEqual(10.0, ChatLine.LastTime(last));
        // No message, no time: also where the line names a task.
        Assert.IsNull(ChatLine.LastTime(null));
        Assert.IsNull(ChatLine.LastTime(new MobilePreview(9, "owner", "")));
    }

    [TestMethod]
    public void APaneRowsTimeIsItsLastMessagesAlsoBesideATask()
    {
        // Customer Support's last message is 60 s old, and its task moved 300 s ago: the line names the task, the
        // time is the message's (15:11); before, it was the task's move.
        var s = State(Decode(Snapshot()), Clock);
        var wren = Screens.Pane(s, Page.Needs, Clock, Utc).Agents.Single(a => a.Name == "wren");
        Assert.AreEqual("15:11", wren.Time);
        var developer = Screens.Pane(s, Page.Needs, Clock, Utc).Agents.Single(a => a.Name == "theo");
        Assert.AreEqual("Fix the checkout error on iPhone", developer.Line);
        Assert.AreEqual("14:05", developer.Time, "the Developer's last message (4000 s before), not its task's move (720 s)");
        Assert.IsNull(Screens.Pane(s, Page.Needs, Clock, Utc).Agents.Single(a => a.Name == "pax").Time, "no message, no time");
    }
}
