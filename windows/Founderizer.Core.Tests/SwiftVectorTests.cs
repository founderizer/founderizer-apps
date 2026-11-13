using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Text.Json;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace Founderizer.Core.Tests;

/// <summary>The vectors that the Swift code itself writes: an agent's mark (FleetMark, agent-marks.json) and FleetCore's
/// words (swift-words.json). The C# must give the same, except in the cases that this file names as known differences,
/// which it holds as still different, so that a change on either side shows.</summary>
[TestClass]
public sealed class SwiftVectorTests
{
    private static GlyphKind Kind(string name) => Enum.Parse<GlyphKind>(name, ignoreCase: true);
    private static Rgb Rgb(JsonElement e) => new(e[0].GetDouble(), e[1].GetDouble(), e[2].GetDouble());
    private static void Near(Rgb expected, Rgb actual, string what)
    {
        Assert.AreEqual(expected.Red, actual.Red, 0.0005, what);
        Assert.AreEqual(expected.Green, actual.Green, 0.0005, what);
        Assert.AreEqual(expected.Blue, actual.Blue, 0.0005, what);
    }

    [TestMethod]
    public void EachNameHasFleetMarksLookAndItsNextLooks()
    {
        var marks = Vectors.Read("agent-marks.json");
        Assert.AreEqual(GlyphLook.CoreOpacity, marks.GetProperty("core_opacity").GetDouble());
        Assert.AreEqual(GlyphLook.ToneCount, marks.GetProperty("tone_count").GetInt32());
        CollectionAssert.AreEqual(marks.GetProperty("kinds").EnumerateArray().Select(k => k.GetString()).ToArray(),
                                  Enum.GetValues<GlyphKind>().Select(GlyphLook.Name).ToArray());
        var count = 0;
        foreach (var named in marks.GetProperty("names").EnumerateArray())
        {
            var name = named.GetProperty("name").GetString()!;
            var look = new GlyphLook(name);
            Assert.AreEqual(Kind(named.GetProperty("kind").GetString()!), look.Kind, name);
            Assert.AreEqual(named.GetProperty("tone").GetInt32(), look.Tone, name);
            Assert.AreEqual(named.GetProperty("phase").GetDouble(), look.Phase, 1e-9, name);
            Near(Rgb(named.GetProperty("light")), look.Light, name + " light");
            Near(Rgb(named.GetProperty("deep")), look.Deep, name + " deep");
            var attempt = 1;
            foreach (var next in named.GetProperty("next").EnumerateArray())
            {
                var other = new GlyphLook(name, attempt++);
                Assert.AreEqual(Kind(next.GetProperty("kind").GetString()!), other.Kind, $"{name}#{attempt - 1}");
                Assert.AreEqual(next.GetProperty("tone").GetInt32(), other.Tone, $"{name}#{attempt - 1}");
            }
            count++;
        }
        Assert.IsTrue(count >= 30);
    }

    [TestMethod]
    public void EachTeamWearsFleetMarksLooks()
    {
        foreach (var team in Vectors.Read("agent-marks.json").GetProperty("teams").EnumerateArray())
        {
            var looks = GlyphLook.Team(team.GetProperty("names").EnumerateArray().Select(n => n.GetString()!));
            foreach (var look in team.GetProperty("looks").EnumerateArray())
            {
                var name = look.GetProperty("name").GetString()!;
                Assert.AreEqual(Kind(look.GetProperty("kind").GetString()!), looks[name].Kind, name);
                Assert.AreEqual(look.GetProperty("tone").GetInt32(), looks[name].Tone, name);
            }
        }
        // The sample fleet of the pictures: a lime sparkle, a coral flower, a mint drop, a sky circle, an orchid hexagon.
        var sample = GlyphLook.Team(["manager", "wren", "theo", "pax", "orla"]);
        Assert.AreEqual((GlyphKind.Sparkle, 2), (sample["manager"].Kind, sample["manager"].Tone));
        Assert.AreEqual((GlyphKind.Hexagon, 7), (sample["orla"].Kind, sample["orla"].Tone));
    }

    [TestMethod]
    public void EachShapeHasFleetMarksMotionAnchorAndPaths()
    {
        foreach (var shape in Vectors.Read("agent-marks.json").GetProperty("shapes").EnumerateArray())
        {
            var kind = Kind(shape.GetProperty("kind").GetString()!);
            Assert.AreEqual(shape.GetProperty("motion").GetString(), GlyphLook.MotionOf(kind).ToString().ToLowerInvariant());
            var (x, y) = GlyphLook.CoreAnchor(kind);
            Assert.AreEqual(shape.GetProperty("core_anchor")[0].GetDouble(), x, 1e-9);
            Assert.AreEqual(shape.GetProperty("core_anchor")[1].GetDouble(), y, 1e-9);
            Assert.AreEqual(shape.GetProperty("outline").GetString(), GlyphPaths.Outline(kind));
            Assert.AreEqual(shape.GetProperty("core").GetString(), GlyphPaths.Core(kind));
            StringAssert.StartsWith(GlyphPaths.Outline(kind), "M");
        }
    }

    [TestMethod]
    public void AMarkMovesAsTheAppsMoveItAndRestsWhereItShould()
    {
        var turn = new GlyphLook("manager");                         // a sparkle turns
        var moves = turn.Moves();
        var pace = 0.9 + 0.2 * turn.Phase / (2 * Math.PI);
        Assert.AreEqual(4, moves.Count);
        Assert.AreEqual(GlyphMove.Turn(GlyphPart.Figure, 2 * Math.PI, 6 * pace), moves[0]);
        Assert.AreEqual((1.0, 0.86), (moves[1].From, moves[1].To));   // a swing whose rest is an end starts at its rest
        Assert.AreEqual(1.0, GlyphMove.Swing(GlyphPart.Figure, GlyphProperty.Scale, 0.86, 1, 1, 1).From);
        Assert.AreEqual(0.3, GlyphMove.Swing(GlyphPart.Figure, GlyphProperty.Rotation, -0.3, 0.3, 0, 1).From);
        var look = new GlyphLook("theo");                            // a drop breathes, and its inner mark too
        Assert.AreEqual(GlyphKind.Drop, look.Kind);
        Assert.IsTrue(look.Moves().Any(m => m.Part == GlyphPart.Core));
        var working = MarkLook.Of(turn, AgentState.Working);
        Assert.IsTrue(working.Moves);
        Assert.IsFalse(MarkLook.Of(turn, AgentState.Working, moves: false).Moves);
        Assert.AreEqual(MarkLook.AbsentLight, MarkLook.Of(turn, AgentState.Offline).Light);
        Assert.IsTrue(MarkLook.Of(turn, AgentState.Setup).Dashed);
        var moon = MarkLook.Of(new GlyphLook("studio"), AgentState.Online);
        Assert.AreEqual(GlyphKind.Moon, moon.Kind);
        Assert.AreEqual((moon.Light, 1.0), (moon.CoreFill, moon.CoreOpacity));
    }

    // ---------------------------------------------------------------- FleetCore's words

    [TestMethod]
    public void AnAgentsLabelAndTheLineUnderItAreFleetCores()
    {
        var words = Vectors.Read("swift-words.json");
        var names = new AgentBook(words.GetProperty("names").EnumerateArray()
            .Select(n => (n.GetProperty("name").GetString()!, n.TryGetProperty("title", out var t) ? t.GetString() : null)));
        foreach (var n in words.GetProperty("names").EnumerateArray())
        {
            var name = n.GetProperty("name").GetString()!;
            Assert.AreEqual(n.GetProperty("label").GetString(), names.Label(name), name);
            Assert.AreEqual(n.TryGetProperty("under", out var under) ? under.GetString() : null, names.Under(name), name);
            Assert.AreEqual(n.GetProperty("capitalized").GetString(), AgentBook.Capitalized(name), name);
        }
        Assert.IsTrue(names.Matches("wren", "cust", CultureInfo.InvariantCulture));
        Assert.IsTrue(names.Matches("wren", "WREN", CultureInfo.InvariantCulture));
        Assert.IsFalse(names.Matches("wren", "dev", CultureInfo.InvariantCulture));
    }

    [TestMethod]
    public void AMessagesBlocksAreFleetCores()
    {
        foreach (var t in Vectors.Read("swift-words.json").GetProperty("texts").EnumerateArray())
        {
            var text = t.GetProperty("text").GetString()!;
            var blocks = MessageBlock.Parse(text);
            var expected = t.GetProperty("blocks");
            Assert.AreEqual(expected.GetArrayLength(), blocks.Count, text);
            for (var i = 0; i < blocks.Count; i++)
            {
                var e = expected[i];
                Assert.AreEqual(e.GetProperty("kind").GetString(), blocks[i].Kind.ToString().ToLowerInvariant(), text);
                Assert.AreEqual(e.GetProperty("text").GetString(), blocks[i].Text, text);
                Assert.AreEqual(e.GetProperty("marker").GetString(), blocks[i].Marker, text);
                Assert.AreEqual(e.GetProperty("level").GetInt32(), blocks[i].Level, text);
                var cells = e.GetProperty("cells").EnumerateArray().Select(r => r.EnumerateArray().Select(c => c.GetString()).ToArray()).ToArray();
                Assert.AreEqual(cells.Length, blocks[i].Rows.Count, text);
                for (var r = 0; r < cells.Length; r++) CollectionAssert.AreEqual(cells[r], blocks[i].Rows[r].ToArray(), text);
            }
        }
    }

    [TestMethod]
    public void APlainLineAndARowsLineAreFleetCores()
    {
        foreach (var t in Vectors.Read("swift-words.json").GetProperty("texts").EnumerateArray())
        {
            var text = t.GetProperty("text").GetString()!;
            Assert.AreEqual(t.GetProperty("plain").GetString(), MessageBlock.Plain(text), "plain: " + text);
            var preview = t.TryGetProperty("preview", out var p) ? p.GetString() : null;
            Assert.AreEqual(preview, ChatLine.Plain(text), "preview: " + text);
        }
    }

    /// <summary>The cases where .NET's culture data writes a time otherwise than Swift's (both from ICU on this Mac): the
    /// short time of en-GB at midnight past ("0:12" against "00:12").</summary>
    private static readonly HashSet<(string Locale, double Ago)> KnownTimeDifferences = [("en_GB", 54000)];

    [TestMethod]
    public void TheRowTimeAndTheAgeAreFleetCoresInTwoLocales()
    {
        var words = Vectors.Read("swift-words.json");
        var utc = new ScreenContext(TimeZoneInfo.Utc, CultureInfo.InvariantCulture);
        var differences = new List<string>();
        foreach (var t in words.GetProperty("times").EnumerateArray())
        {
            var locale = t.GetProperty("locale").GetString()!;
            var context = utc with { Culture = new CultureInfo(locale.Replace('_', '-')) };
            var (time, now) = (t.GetProperty("time").GetDouble(), t.GetProperty("now").GetDouble());
            var mine = TimeWords.RowTime(time, now, context);
            var swift = t.GetProperty("words").GetString();
            if (KnownTimeDifferences.Contains((locale, now - time)))
            {
                Assert.AreNotEqual(swift, mine, "a known difference closed: remove it from the list");
                differences.Add($"{locale} {now - time}: Swift {swift}, C# {mine}");
            }
            else Assert.AreEqual(swift, mine, $"{locale}, {now - time} s before");
        }
        foreach (var a in words.GetProperty("ages").EnumerateArray())
        {
            var locale = a.GetProperty("locale").GetString()!;
            var context = utc with { Culture = new CultureInfo(locale.Replace('_', '-')) };
            Assert.AreEqual(a.GetProperty("words").GetString(),
                            TimeWords.Age(a.GetProperty("time").GetDouble(), a.GetProperty("now").GetDouble(), context),
                            $"{locale}, {a.GetProperty("now").GetDouble() - a.GetProperty("time").GetDouble()} s");
        }
        Assert.AreEqual(KnownTimeDifferences.Count, differences.Count, string.Join("; ", differences));
    }
}
