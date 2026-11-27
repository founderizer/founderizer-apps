using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using Founderizer.Core;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace Founderizer.Core.Tests;

/// <summary>**A press of Continue on "Name your manager"** (<see cref="ManagerRename"/>), against a hub whose answers can be
/// lost: the Mac's <c>ManagerRenameTests</c> (6e83cad2f), case for case.</summary>
[TestClass]
public sealed class ManagerRenameTests
{
    /// <summary>A hub that holds the manager's name: it renames, refuses a name that is gone, and can lose an answer.</summary>
    private sealed class Hub
    {
        public string Manager { get; set; } = "juno";
        /// <summary>The commands that reached it, by the name that they ask for.</summary>
        public List<string> Commands { get; } = [];
        /// <summary>What the next command gets in place of the hub's own answer, after the hub did its work or before.</summary>
        public (bool Made, HubException Error)? Next { get; set; }
        /// <summary>At each read of the team: a change of the team that comes between two reads.</summary>
        public Action AtRead { get; set; } = () => { };

        public Task<ManagerRename.Outcome> Press(string wanted, string was = "juno") => ManagerRename.PressAsync(was, wanted, () =>
        {
            AtRead();
            return Task.FromResult<ManagerRename.Team?>(new ManagerRename.Team(["mail", Manager], Manager, "the sha of " + Manager));
        }, sha256 =>
        {
            Commands.Add(wanted);
            var cut = Next;
            Next = null;
            if (cut is { } lost && !lost.Made) throw lost.Error;
            if (sha256 != "the sha of " + Manager) throw Refusal(409, "team_changed");
            if (Manager != was) throw Refusal(404, "no_such_agent");
            Manager = wanted;
            if (cut is { } made) throw made.Error;
            return Task.FromResult(true);
        });

        public static HubException Refusal(int status, string code) => HubException.Refusal(status, null, "example", code);
    }

    private static string Word(ManagerRename.Outcome outcome) => outcome switch
    {
        ManagerRename.Outcome.Keep => "keep",
        ManagerRename.Outcome.Named => "named",
        ManagerRename.Outcome.Renamed renamed => "renamed " + renamed.Now,
        ManagerRename.Outcome.Refused refused => $"refused {refused.Refusal.Status} {refused.Refusal.Code}",
        ManagerRename.Outcome.Unanswered => "unanswered",
        ManagerRename.Outcome.Moved => "moved",
        _ => throw new InvalidOperationException("no such outcome"),
    };

    /// <summary>The hub renamed the manager and its answer was lost, and the window still has the old name: the next press
    /// finds the new name and sends nothing, also when he types the old name again or a third one. A bug here sends a
    /// rename of a name that is gone: its refusal takes the note away, and the window never goes to the manager's new
    /// page.</summary>
    [TestMethod]
    public async Task ARenameWhoseAnswerWasLostIsFoundAtTheNextPress()
    {
        foreach (var wanted in new[] { "nova", "juno", "atlas" })
        {
            var hub = new Hub { Next = (Made: true, HubException.NoAnswer()) };
            Assert.AreEqual("unanswered", Word(await hub.Press("nova")));
            Assert.AreEqual("nova", hub.Manager);
            Assert.AreEqual("renamed nova", Word(await hub.Press(wanted)), wanted);
            CollectionAssert.AreEqual(new[] { "nova" }, hub.Commands, wanted);
        }
    }

    /// <summary>The command that was lost on its way there renamed nothing: the next press goes on with the name, or sends
    /// the rename again. A bug here leaves him on the page of a name that the hub never took.</summary>
    [TestMethod]
    public async Task ACommandThatNeverReachedTheHubIsSentAgain()
    {
        var hub = new Hub { Next = (Made: false, HubException.NoAnswer()) };
        Assert.AreEqual("unanswered", Word(await hub.Press("nova")));
        Assert.AreEqual("keep", Word(await hub.Press("juno")));
        CollectionAssert.AreEqual(new[] { "nova" }, hub.Commands);
        Assert.AreEqual("named", Word(await hub.Press("nova")));
        Assert.AreEqual("nova", hub.Manager);
        CollectionAssert.AreEqual(new[] { "nova", "nova" }, hub.Commands);
    }

    /// <summary>The rename of an earlier press lands between the read of the team and the command of this one: the hub says
    /// that the team changed, or that the name is gone, and the second read finds the new name with no second command. A bug
    /// here shows him the hub's error for a rename that was made.</summary>
    [TestMethod]
    public async Task ARenameThatLandsMeanwhileIsFoundAtTheSecondRead()
    {
        foreach (var (status, code) in new[] { (409, "team_changed"), (404, "no_such_agent") })
        {
            var hub = new Hub { Next = (Made: false, Hub.Refusal(status, code)) };
            var reads = 0;
            hub.AtRead = () => { if (++reads == 2) hub.Manager = "nova"; };
            Assert.AreEqual("renamed nova", Word(await hub.Press("atlas")), code);
            CollectionAssert.AreEqual(new[] { "atlas" }, hub.Commands, code);
            Assert.AreEqual(2, reads, code);
        }
    }

    /// <summary>The team is read again once, and then the hub's refusal stands: a team that changes at each read ends the
    /// press, and a refusal of the name itself is asked once. The bugs: a press that stops at the first changed team, and a
    /// refused name asked for twice.</summary>
    [TestMethod]
    public async Task ARefusalStandsAtTheSecondRead()
    {
        foreach (var (status, code, commands) in new[] { (409, "team_changed", 2), (404, "no_such_agent", 2), (409, "name_taken", 1) })
        {
            var hub = new Hub();
            hub.AtRead = () => hub.Next = (Made: false, Hub.Refusal(status, code));
            Assert.AreEqual($"refused {status} {code}", Word(await hub.Press("nova")));
            Assert.AreEqual(commands, hub.Commands.Count, code);
        }
    }

    /// <summary>A window that went to another hub while the team was read, or whose call was answered with nothing (the
    /// PC's store gives no value when the hub's generation changed), sends that hub's command nowhere, and nothing of the
    /// press counts. A bug here gives the page of another hub the press of this one.</summary>
    [TestMethod]
    public async Task AWindowThatWentToAnotherHubSendsNothing()
    {
        var sent = 0;
        Assert.AreEqual("moved", Word(await ManagerRename.PressAsync("juno", "nova", () => Task.FromResult<ManagerRename.Team?>(null),
                                                                     _ => { sent++; return Task.FromResult(true); })));
        Assert.AreEqual(0, sent);
        var team = new ManagerRename.Team(["juno"], "juno", "the sha of juno");
        Assert.AreEqual("moved", Word(await ManagerRename.PressAsync("juno", "nova", () => Task.FromResult<ManagerRename.Team?>(team),
                                                                     _ => { sent++; return Task.FromResult(false); })));
        Assert.AreEqual(1, sent, "a call that was answered with nothing sent once, and the press counts for nothing");
    }

    /// <summary>The page goes to the manager's name in the first reading without the noted name. A bug here leaves the window
    /// on an agent that is gone, or takes it to an agent that is not the manager, or to another hub's manager.</summary>
    [TestMethod]
    public void ThePageFollowsTheManagerAndNoOtherAgent()
    {
        static MobileSnapshot ReadingOf(string db, params (string Name, string Role)[] agents) =>
            new(1, db, 1000, agents.Select(a => new MobileAgent(a.Name, a.Role, "claude", 0, [])).ToArray(), [], [], [], [], []);
        var hub = new Uri("http://hub.example:8765/");
        var other = new Uri("http://other.example:8765/");
        var note = new ManagerRenameNote(hub, "named", "juno");
        var renamed = ReadingOf("named", ("mail", "worker"), ("nova", "manager"));
        Assert.AreEqual("nova", note.Follow(hub, renamed));
        // The manager got another name than the one that this window asked for, and a worker has that one.
        Assert.AreEqual("atlas", note.Follow(hub, ReadingOf("named", ("nova", "worker"), ("atlas", "manager"))));
        // The hub still has the old name, has no manager, or is another hub or another generation.
        Assert.IsNull(note.Follow(hub, ReadingOf("named", ("juno", "manager"))));
        Assert.IsNull(note.Follow(hub, ReadingOf("named", ("mail", "worker"))));
        Assert.IsNull(note.Follow(other, renamed));
        Assert.IsNull(note.Follow(hub, ReadingOf("another", ("nova", "manager"))));
        // The PC's hub can carry another form of its address: the scheme, the host and the port are what counts.
        Assert.AreEqual("nova", note.Follow(new Uri("HTTP://HUB.example:8765/"), renamed), "the same hub in another form");
        Assert.IsTrue(note.Is(new Uri("http://hub.example:8765/"), "named", "juno"));
        Assert.IsFalse(note.Is(other, "named", "juno"));
        Assert.IsFalse(note.Is(hub, "named", "atlas"));
    }
}
