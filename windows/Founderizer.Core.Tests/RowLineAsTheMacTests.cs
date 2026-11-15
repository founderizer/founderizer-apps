using System.Linq;
using System.Text.Json;
using Microsoft.VisualStudio.TestTools.UnitTesting;
using static Founderizer.Core.Tests.SampleFleet;

namespace Founderizer.Core.Tests;

/// <summary>An agent's row shows a request that waits for him, in orange, when its card is the newest thing in its chat
/// (FleetCore ChatList.waitingRequest and requestTime, Founderizer 0.1.224; the cases of ChatListTests.swift).</summary>
[TestClass]
public sealed class RowLineAsTheMacTests
{
    private static MobileChatItem Agents(long id, double at, string? replyingTo = null) =>
        new("report", at, JsonDocument.Parse(id.ToString()).RootElement.Clone(), "Synthetic reply " + id, InReplyTo: replyingTo)
        { Key = id.ToString() };

    private static MobileChatItem Mine(string id, double at) =>
        new("message", at, JsonDocument.Parse($"\"{id}\"").RootElement.Clone(), "Synthetic", "test") { Key = id };

    private static OwnerNeed Need(long id, double raised, double? answered = null, string by = "manager") =>
        new(id, "Give the developer write on the repository?", "", "", raised, by, Answer: answered is null ? null : "Yes",
            Answered: answered);

    [TestMethod]
    public void AWaitingCardThatIsTheNewestThingInTheChatIsTheLine()
    {
        var chat = new[] { Agents(1, 10), Mine("a", 20), Agents(3, 30) };
        Assert.AreEqual(7L, ChatLine.WaitingRequest("manager", chat, true, [Need(7, 40), Need(6, 35)])?.Id);
        Assert.AreEqual(40.0, ChatLine.RequestTime(Need(7, 40), chat[^1]));
        Assert.IsNull(ChatLine.WaitingRequest("manager", chat, true, [Need(7, 25)]), "a message after it is the line");
        Assert.IsNull(ChatLine.WaitingRequest("manager", chat, true, [Need(7, 40, answered: 50)]), "answered");
        Assert.IsNull(ChatLine.WaitingRequest("manager", chat, true, [Need(7, 40, by: "vps")]), "another agent's");
        Assert.IsNull(ChatLine.WaitingRequest("manager", chat, true, []));
        Assert.AreEqual(7L, ChatLine.WaitingRequest("manager", [], true, [Need(7, 40)])?.Id, "with no message yet, the card is the chat");
    }

    [TestMethod]
    public void ACardUnderTheReplyOfItsTurnIsStillTheLine()
    {
        var chat = new[] { Agents(1, 10), Mine("a", 20), Agents(3, 45, replyingTo: "a") };
        var request = Need(7, 40);
        Assert.AreEqual(7L, ChatLine.WaitingRequest("manager", chat, true, [request])?.Id);
        Assert.AreEqual(45.0, ChatLine.RequestTime(request, chat[^1]));
        Assert.IsNull(ChatLine.WaitingRequest("manager", [.. chat, Agents(4, 90)], true, [request]),
                      "a later message of the agent's that answers nothing of his comes after the card");
    }

    [TestMethod]
    public void TheRowAndTheSearchSayTheRequestInOrange()
    {
        var fleet = Decode(Snapshot());
        var raised = Now - 30;
        fleet = fleet with { Needs = [Need(7, raised)] };
        var s = State(fleet, Clock);
        var chat = new[] { Agents(1, Now - 600), Mine("a", Now - 300), Agents(3, Now - 60) };
        s = s with { Chats = s.Chats.SetItem("manager", new ChatPageState { Agent = "manager", Items = ValueList.Of(chat), Whole = true }) };
        var row = Screens.Pane(s, Page.Chat("manager"), Clock, Utc).Agents.Single(a => a.Name == "manager");
        Assert.AreEqual(("Give the developer write on the repository?", true, null), (row.Line, row.NeedsYou, row.LineCount));
        Assert.AreEqual(TimeWords.RowTime(raised, fleet.Time, Utc), row.Time, "the row's time is the card's");
        var search = Screens.Search(s, "", 0, Clock).Agents.Single(a => a.Name == "manager");
        Assert.AreEqual(("Give the developer write on the repository?", true), (search.Line, search.NeedsYou));

        // A chat that the store has not read has no place for the card yet: the hub's last line stays.
        var unread = State(fleet, Clock);
        var plain = Screens.Pane(unread, Page.Chat("manager"), Clock, Utc).Agents.Single(a => a.Name == "manager");
        Assert.IsFalse(plain.NeedsYou);
        Assert.AreEqual(ChatLine.Preview("manager", fleet.Agents.Single(a => a.Name == "manager").Last, fleet.Tasks), plain.Line);
    }
}
