using System.Linq;
using System.Text;
using System.Text.Json.Nodes;
using Microsoft.VisualStudio.TestTools.UnitTesting;
using static Founderizer.Core.Tests.SampleFleet;

namespace Founderizer.Core.Tests;

/// <summary>**His capitals of an agent's name** (hub feature `agent_spelling`; the owner, 25 November 2026: "it doesn't
/// let me use upper case the first letter of the bot! then everywhere it ends up showing lowercase and looks bad because
/// it is a name!!"), by FleetCore's rule (`AgentNamesTests` on the Mac): the label is the name as he typed it, only from
/// a hub that serves the feature, and only where it is the name in other capitals.</summary>
[TestClass]
public sealed class AgentSpellingTests
{
    private static MobileSnapshot Read(bool served)
    {
        var snapshot = Snapshot();
        var features = (JsonArray)snapshot["ui_features"]!;
        if (served) features.Add((JsonNode)AgentBook.SpellingFeature);       // a node: no JSON by reflection
        var agents = (JsonArray)snapshot["agents"]!;
        ((JsonObject)agents[1]!)["spelling"] = "WrEn";                // wren, Customer Support
        ((JsonObject)agents[3]!)["spelling"] = "Orla";                // pax: another agent's name
        ((JsonObject)agents[0]!)["spelling"] = "Manager";             // a role that holds the name stays the label
        ((JsonObject)agents[2]!)["spelling"] = "theo";                // no capital: no spelling
        agents.Add(Agent("devops", "worker", null));
        ((JsonObject)agents[5]!)["spelling"] = "DevOps";
        // the Kelvin sign is "k" in small letters, and no letter of a name; a number is no text
        foreach (var (name, spelling) in new (string, JsonNode?)[]
                 { ("kai", "\u212Aai"), ("mini-2b", "Mini-2b"), ("nova", null), ("ines", ""), ("leo", 7) })
        {
            var agent = Agent(name, "worker", null);
            agent["spelling"] = spelling;
            agents.Add((JsonNode)agent);
        }
        return HubDecode.Snapshot(Encoding.UTF8.GetBytes(snapshot.ToJsonString()));
    }

    /// <summary>The bugs: the field is not read and the PC shows "Devops" where the Mac shows "DevOps"; an older hub's
    /// field is taken without the feature; a spelling of another name, or one that only looks like its name, puts words on
    /// an agent that are not its name; a spelling that is no text refuses the whole reading, and the PC shows no new one;
    /// or the spelling beats the role that holds the name, and "Manager" stands where "Fleet Manager" stood.</summary>
    [TestMethod]
    public void TheLabelIsHisSpellingOnlyOnAHubThatServesIt()
    {
        var served = Read(served: true);
        Assert.AreEqual("DevOps", served.Agents.Single(a => a.Name == "devops").Spelling);
        var book = AgentBook.Of(served);
        Assert.AreEqual("DevOps", book.Label("devops"));
        Assert.AreEqual("WrEn", book.Label("wren"));
        Assert.AreEqual("Customer Support", book.Role("wren"));
        Assert.AreEqual("Pax", book.Label("pax"));
        Assert.AreEqual("Fleet Manager", book.Label("manager"));
        Assert.IsNull(book.Role("manager"));
        Assert.AreEqual("Manager", book.Spelled("manager"));
        Assert.AreEqual("Theo", book.Label("theo"));
        Assert.AreEqual("Kai", book.Label("kai"));
        Assert.AreEqual("Mini-2b", book.Label("mini-2b"));
        Assert.AreEqual("Nova", book.Label("nova"));
        Assert.AreEqual("Ines", book.Label("ines"));
        Assert.AreEqual("Leo", book.Label("leo"));

        var older = AgentBook.Of(Read(served: false));
        Assert.AreEqual("Devops", older.Label("devops"));
        Assert.AreEqual("Wren", older.Label("wren"));
    }

    /// <summary>What a command sends beside the id. The bugs: a spelling goes to a hub that refuses an unknown field,
    /// one in small letters goes for nothing, or words that are not the id go and the hub refuses the whole command.</summary>
    [TestMethod]
    public void ACommandSendsHisSpellingOnlyWhereItIsTheIdInOtherCapitals()
    {
        Assert.AreEqual("Nova", AgentBook.Spelling("Nova", "nova", served: true));
        Assert.AreEqual("DevOps", AgentBook.Spelling(" DevOps ", "devops", served: true));
        Assert.IsNull(AgentBook.Spelling("Nova", "nova", served: false));
        Assert.IsNull(AgentBook.Spelling("nova", "nova", served: true));
        Assert.IsNull(AgentBook.Spelling("Atlas", "nova", served: true));
        Assert.IsNull(AgentBook.Spelling("Léo", "léo", served: true));
    }
}
