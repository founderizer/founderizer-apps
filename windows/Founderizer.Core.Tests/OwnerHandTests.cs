using System;
using System.Buffers.Binary;
using System.Collections.Generic;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using Microsoft.VisualStudio.TestTools.UnitTesting;
using static Founderizer.Core.Tests.SampleFleet;

namespace Founderizer.Core.Tests;

/// <summary>**A message that an AI session sent for him does not look like his own** (owner feature `message_hands`, owner
/// API 1.332; the owner's "B, go ahead" of 24 November 2026, after "why does it look like I sent that message? I didn't";
/// his "Match the Mac" for the PC). One rule draws every bubble of his (<see cref="OwnerHand.Of"/>, FleetCore's
/// <c>OwnerHand.look</c>), from the hand that the hub gives each item of a chat, each line of a card's talk, each
/// guidance of a task and the last line of each chat. Example names only.</summary>
[TestClass]
public sealed class OwnerHandTests
{
    private static readonly string[] On = ["need_clarify", OwnerHand.Feature];

    /// <summary>The rule's table, case for case the Mac's (<c>OwnerHandTests.swift</c>
    /// <c>eachHandHasItsLookAndOnlyAnAISessionOfAKnownProgramHasAMark</c>). The bugs that this catches: an AI session's
    /// message in his filled bubble (the fault that he saw); his own words from the Mac, a device or a chat app, or a row
    /// from before the hand, in the outline; a mark on a connected app's or another hand's words, or on an AI session
    /// whose program has no mark here (a wrong logo); an outline or a mark on a hub that does not give the hand; and an
    /// assistive app that reads "You: " before words that he did not write.</summary>
    [TestMethod]
    public void EachHandHasItsLookAndOnlyAnAISessionOfAKnownProgramHasAMark()
    {
        static HandLook Look(string? hand, string? runtime) => OwnerHand.Of(On, hand, runtime);
        // his own hands, and a row from before owner API 1.289: the filled bubble, whatever runtime stands beside
        foreach (var hand in new[] { "app", "device", "chat", null })
        {
            Assert.AreEqual(HandLook.His, Look(hand, null), hand ?? "null");
            Assert.AreEqual(HandLook.His, Look(hand, "claude-code"), hand ?? "null");
        }
        // an AI session through the owner tools: the outline, with its mark when its program has one
        Assert.AreEqual(new HandLook(true, AiMark.Claude), Look("tool", "claude-code"));
        Assert.AreEqual(new HandLook(true, AiMark.Codex), Look("tool", "codex"));
        Assert.AreEqual(new HandLook(true, AiMark.Grok), Look("tool", "grok"));
        Assert.AreEqual(new HandLook(true, AiMark.OpenCode), Look("tool", "opencode"));
        Assert.AreEqual(new HandLook(true, null), Look("tool", null));
        Assert.AreEqual(new HandLook(true, null), Look("tool", "another-program"));
        // a connected app, another hand, and a hand that this app does not know: the outline, never a mark
        foreach (var hand in new[] { "connected", "other", "a-new-hand", "", "Tool" })
            foreach (var runtime in new[] { "claude-code", "codex", "grok", "opencode" })
                Assert.AreEqual(new HandLook(true, null), Look(hand, runtime), $"{hand} {runtime}");
        // the hub's names exactly: a program's name in other letters has no mark
        Assert.AreEqual(new HandLook(true, null), Look("tool", "Claude-Code"));
        // what an assistive app reads: "You: " only before his own words, the mark's words before an AI session's
        Assert.AreEqual("You: Pin it.", Look("app", null).Spoken("Pin it."));
        Assert.AreEqual("Sent by your AI session: Pin it.", Look("tool", "codex").Spoken("Pin it."));
        Assert.AreEqual("Pin it.", Look("tool", null).Spoken("Pin it."));
        Assert.AreEqual("Pin it.", Look("connected", null).Spoken("Pin it."));
        // a hub without the feature, or with no list of features: every bubble as before
        foreach (var hand in new[] { "app", "device", "chat", "connected", "tool", "other", null })
        {
            Assert.AreEqual(HandLook.His, OwnerHand.Of(["need_clarify"], hand, "claude-code"), hand ?? "null");
            Assert.AreEqual(HandLook.His, OwnerHand.Of(null, hand, "claude-code"), hand ?? "null");
        }
    }

    private static JsonObject Hand(JsonObject row, string? hand, string? runtime)
    {
        row["hand"] = hand;
        row["runtime"] = runtime;
        return row;
    }

    private static JsonObject Talk() => new()
    {
        ["who"] = "owner", ["text"] = "Does it go to the people who left in March?", ["ts"] = Now - 600,
        ["hand"] = "tool", ["runtime"] = "codex",
    };

    /// <summary>The device's reading on a hub with the hand, or without the feature: the manager's last line is an AI
    /// session's, Developer's is his own from a device, and the card about the email has a talk of four lines.</summary>
    private static MobileSnapshot Fleet(bool hands)
    {
        var snapshot = Snapshot();
        var features = snapshot["ui_features"]!.AsArray();
        features.Add((JsonNode)NeedClarify.Feature);
        if (hands) features.Add((JsonNode)OwnerHand.Feature);
        foreach (var node in snapshot["agents"]!.AsArray())
        {
            var agent = node!.AsObject();
            if ((string?)agent["name"] == "manager")
                agent["last"] = Hand(Preview(Now - 100, "owner", "The owner asked whether the sale is ready."), "tool", "claude-code");
            if ((string?)agent["name"] == "theo")
                agent["last"] = Hand(Preview(Now - 90, "owner", "Ship it."), "device", null);
            if ((string?)agent["name"] == "orla")
                agent["last"] = Hand(Preview(Now - 80, "agent", "The email is ready."), null, null);
        }
        var talk = new JsonArray
        {
            Talk(),
            new JsonObject { ["who"] = "manager", ["text"] = "No.", ["ts"] = Now - 540, ["hand"] = null, ["runtime"] = null },
            new JsonObject { ["who"] = "owner", ["text"] = "Thanks", ["ts"] = Now - 500 },
            // an agent's reply is no bubble of his, whatever hand stands beside it
            new JsonObject { ["who"] = "manager", ["text"] = "Done.", ["ts"] = Now - 400, ["hand"] = "tool", ["runtime"] = "claude-code" },
        };
        var need = snapshot["needs"]![1]!.AsObject();
        need["talk"] = talk;
        need["clarify"] = true;
        var answered = Need(3, "Post the summary?", "It is ready.", "manager", Now - 3000, "Post it");
        answered["answer"] = "Post it";
        answered["answered"] = Now - 2900;
        answered["talk"] = talk.DeepClone();
        snapshot["answered_needs"] = new JsonArray(answered);
        return Decode(snapshot);
    }

    private static StoreState WithManagersChat(MobileSnapshot fleet)
    {
        var s = State(fleet, Clock);
        var page = HubDecode.ChatPage(Encoding.UTF8.GetBytes(ChatPage("gen1", "manager",
            Hand(Message("0b5f6c8e-1111-4222-8333-00000000000a", Now - 400, "The owner asked whether the sale is ready."), "tool", "claude-code"),
            Hand(Message("0b5f6c8e-1111-4222-8333-00000000000b", Now - 300, "Is it ready?"), null, null),
            Message("0b5f6c8e-1111-4222-8333-00000000000c", Now - 200, "Thanks"),
            Hand(Message("0b5f6c8e-1111-4222-8333-00000000000d", Now - 150, "Send it"), "chat", null),
            Hand(Message("0b5f6c8e-1111-4222-8333-00000000000e", Now - 120, "Check the list"), "connected", null),
            Report(5, Now - 100, "Yes.")).ToJsonString()), "gen1", "manager");
        return s with { Chats = s.Chats.SetItem("manager", new ChatPageState { Agent = "manager", Items = ValueList.Of(page.Items), Whole = true }) };
    }

    private static StoreState WithGuidance(StoreState s)
    {
        var page = new JsonObject
        {
            ["db"] = "gen1", ["cursor"] = 1, ["notes"] = new JsonArray(), ["holds"] = new JsonArray(), ["outcomes"] = new JsonArray(),
            ["task"] = new JsonObject
            {
                ["id"] = 7, ["title"] = "Example task", ["details"] = "Do it.", ["done_when"] = "done", ["needs"] = "none", ["goal"] = null,
                ["owner"] = "wren", ["requester"] = "manager", ["state"] = "working", ["created"] = Now - 9000, ["attempt"] = 1,
                ["restarts"] = 0, ["nudge_level"] = 0, ["stop_sent"] = 0,
            },
            ["steers"] = new JsonArray(
                Hand(new JsonObject
                {
                    ["id"] = 3, ["task"] = 7, ["attempt"] = 1, ["text"] = "Look at the logs first.", ["created"] = Now - 30,
                    ["read_at"] = null, ["request_id"] = "r-1", ["client"] = "example-tool",
                }, "tool", "codex"),
                new JsonObject
                {
                    ["id"] = 4, ["task"] = 7, ["attempt"] = 1, ["text"] = "Then the config.", ["created"] = Now - 20,
                    ["read_at"] = null, ["request_id"] = "r-2", ["client"] = "founderizer-windows/1",
                }),
        };
        var read = HubDecode.TaskPage(Encoding.UTF8.GetBytes(page.ToJsonString()), "gen1", 7);
        return s with { TaskPages = s.TaskPages.SetItem(7, new TaskPageState { Task = read.Task, Steers = ValueList.Of(read.Steers ?? []) }) };
    }

    /// <summary>The hand is read where the device's routes give it, and each place of the PC that draws a bubble of his
    /// draws it by the rule: his chat's messages (`GET /ui/mobile/chat/&lt;agent&gt;`), the talk under a card in a chat and
    /// on Needs you (`needs` and `answered_needs` of `GET /ui/mobile`, and the receipt of his message under a card), his
    /// guidance of a task (`steers` of `GET /ui/mobile/task/&lt;id&gt;`, and the receipt of a steer), and the line of each
    /// chat in the pane and in Search (`agents[].last`), which writes "You: " only before his own words (the iPhone's
    /// list). The bugs that this catches: a field that is not read in one of those places, so an AI session's words look
    /// like his there; a row without the keys, or with null, that stops the reading; an agent's reply in a talk drawn by a
    /// hand; and an outline or a missing "You: " on a hub that does not give the hand.</summary>
    [TestMethod]
    public void EachPlaceOfThePcDrawsHisBubbleByTheHandThatTheHubGives()
    {
        var outlinedClaude = new HandLook(true, AiMark.Claude);
        var outlinedCodex = new HandLook(true, AiMark.Codex);
        var outlined = new HandLook(true, null);

        var s = WithGuidance(WithManagersChat(Fleet(hands: true)));
        HandLook[] Messages(StoreState state) =>
            Screens.Chat(state, "manager", Clock, Utc).Rows.Where(r => r.Kind == ChatRowKind.Message).Select(r => r.Hand).ToArray();
        CollectionAssert.AreEqual(new[] { outlinedClaude, HandLook.His, HandLook.His, HandLook.His, outlined }, Messages(s));
        Assert.AreEqual(HandLook.His, Screens.Chat(s, "manager", Clock, Utc).Rows.Single(r => r.Kind == ChatRowKind.Reply).Hand,
                        "an agent's reply is no bubble of his");

        var fleet = s.Fleet!;
        var need = fleet.Needs.Single(n => n.Id == 2);
        var talk = new[] { outlinedCodex, HandLook.His, HandLook.His, HandLook.His };
        CollectionAssert.AreEqual(talk, Screens.Card(s, need, [], Clock, Utc).Talk.Select(l => l.Hand).ToArray(), "a card in a chat");
        CollectionAssert.AreEqual(talk, Screens.Step(s, need, [], Clock, Utc).Talk.Select(l => l.Hand).ToArray(), "the request at hand");
        // an assistive app hears no "You" before an AI session's line, and the agent's and his own lines as before
        var manager = s.Names.Label("manager");
        CollectionAssert.AreEqual(new[]
        {
            "Sent by your AI session: Does it go to the people who left in March?", $"{manager}: No.", "You: Thanks", $"{manager}: Done.",
        }, Screens.Card(s, need, [], Clock, Utc).Talk.Select(l => l.Spoken).ToArray(), "what an assistive app reads");
        Assert.AreEqual("Check the list", (new TalkLine(true, "Check the list", "owner", "You", null) { Hand = outlined }).Spoken,
                        "another hand's line: its words alone");
        CollectionAssert.AreEqual(talk, fleet.AnsweredNeeds!.Single().Talk!.Select(l => l.Look(fleet)).ToArray(), "an answered item");
        var receipt = JsonSerializer.Deserialize(Encoding.UTF8.GetBytes(new JsonObject
        {
            ["ok"] = true, ["request_id"] = "r-1", ["client"] = "example-tool", ["replayed"] = false, ["need"] = 2,
            ["talk"] = new JsonArray(Talk()),
            ["steer"] = Hand(new JsonObject
            {
                ["id"] = 5, ["task"] = 7, ["attempt"] = 1, ["text"] = "Stop after the logs.", ["created"] = Now, ["request_id"] = "r-1",
                ["client"] = "example-tool",
            }, "tool", "claude-code"),
        }.ToJsonString()), CoreJson.Default.ControlReceipt)!;
        Assert.AreEqual(outlinedCodex, receipt.Talk!.Single().Look(fleet), "the receipt of his message under a card");
        Assert.AreEqual(outlinedClaude, receipt.Steer!.Look(fleet), "the receipt of a steer");

        CollectionAssert.AreEqual(new[] { outlinedCodex, HandLook.His },
                                  Screens.Task(s, 7, Clock, Utc)!.Thread.Select(r => r.Guidance!.Hand).ToArray(), "a task's guidance");

        var pane = Screens.Pane(s, Page.Tasks, Clock, Utc).Agents;
        var search = Screens.Search(s, "", 0, Clock).Agents;
        Assert.AreEqual("The owner asked whether the sale is ready.", pane.Single(a => a.Name == "manager").Line, "no \"You: \" before an AI session's words");
        Assert.AreEqual("The owner asked whether the sale is ready.", search.Single(a => a.Name == "manager").Line);
        Assert.AreEqual("You: Ship it.", pane.Single(a => a.Name == "theo").Line, "his own words from a device");
        Assert.AreEqual("The email is ready.", pane.Single(a => a.Name == "orla").Line);

        // the same reading from a hub without the feature: every bubble his, and "You: " before every line of his
        var before = WithGuidance(WithManagersChat(Fleet(hands: false)));
        Assert.IsTrue(Messages(before).All(h => h == HandLook.His));
        Assert.IsTrue(Screens.Card(before, before.Fleet!.Needs.Single(n => n.Id == 2), [], Clock, Utc).Talk.All(l => l.Hand == HandLook.His));
        Assert.IsTrue(Screens.Task(before, 7, Clock, Utc)!.Thread.All(r => r.Guidance!.Hand == HandLook.His));
        Assert.AreEqual("You: The owner asked whether the sale is ready.",
                        Screens.Pane(before, Page.Tasks, Clock, Utc).Agents.Single(a => a.Name == "manager").Line);
    }

    /// <summary>**The mark's words are the Mac's, and the Mac's string catalog keeps their Spanish** ("Enviado por tu
    /// sesión de IA"): the PC's sentences are the catalog's keys (plan v2, rule 14). The bug: hover words that drifted from
    /// the Mac's, which the owner did not approve, or a catalog that lost their Spanish.</summary>
    [TestMethod]
    public void TheMarksWordsAreTheMacsWithTheirSpanish()
    {
        using var catalog = JsonDocument.Parse(File.ReadAllBytes(Path.Combine(AppContext.BaseDirectory, "catalog", "Localizable.xcstrings")));
        var entry = catalog.RootElement.GetProperty("strings").GetProperty(OwnerHand.Words);
        Assert.AreEqual("Enviado por tu sesión de IA",
                        entry.GetProperty("localizations").GetProperty("es").GetProperty("stringUnit").GetProperty("value").GetString());
    }

    /// <summary>**An AI session's mark is its logo's glyph alone**, read from the window's own logo (<c>Assets/</c>, the
    /// Mac's bytes) as FleetMark's ProviderLogo.glyphMask reads it, with the bounds and the share of the Mac's test
    /// (<c>eachProgramOfAnAISessionHasTheGlyphOfItsLogoAlone</c>). The bugs that this catches: no glyph for a program that
    /// the hub names, so the bubble's corner shows an empty tile; the wrong logo for a mark; a glyph read the wrong way
    /// round (the tile and not the star, the knot, the ball or the frame), which has other bounds and another share of them
    /// opaque; and a name of the logo's resource that the window's project does not give it (a renamed logo, or another
    /// logical name), so the window reads no logo and the tile is empty.</summary>
    [TestMethod]
    public void EachProgramOfAnAISessionHasTheGlyphOfItsLogoAlone()
    {
        var project = System.Xml.Linq.XDocument.Load(Path.Combine(AppContext.BaseDirectory, "sources", "windows", "Founderizer.Windows.csproj"));
        var logos = project.Descendants("EmbeddedResource")
            .Single(e => (string?)e.Attribute("Include") == "Assets/*.png" && e.Parent!.Attribute("Condition") is null);
        // the Mac's table: the glyph's width, its height, and the share of its bounds that is opaque
        var macs = new Dictionary<AiMark, (int Wide, int High, double Share)>
        {
            [AiMark.Claude] = (76, 76, 0.39), [AiMark.Codex] = (82, 82, 0.395), [AiMark.Grok] = (92, 80, 0.68), [AiMark.OpenCode] = (43, 54, 0.73),
        };
        foreach (var mark in Enum.GetValues<AiMark>())
        {
            Assert.AreEqual(OwnerHand.LogoResource(mark),
                            ((string)logos.Attribute("LogicalName")!).Replace("%(Filename)", OwnerHand.Logo(mark)).Replace("%(Extension)", ".png"));
            var glyph = Glyph(mark);
            var share = glyph.Opacity.Sum(a => a / 255.0) / (glyph.Width * glyph.Height);
            Assert.AreEqual(macs[mark].Wide, glyph.Width, 3.0, $"{mark}'s width");
            Assert.AreEqual(macs[mark].High, glyph.Height, 3.0, $"{mark}'s height");
            Assert.AreEqual(macs[mark].Share, share, 0.04, $"{mark}: the share of its bounds");
        }
    }

    /// <summary>The glyph of the mark's logo, read from the window's own file.</summary>
    private static GlyphMask Glyph(AiMark mark)
    {
        var (rgba, side) = Rgba(File.ReadAllBytes(Path.Combine(AppContext.BaseDirectory, "assets", OwnerHand.Logo(mark) + ".png")));
        var glyph = ProviderGlyph.Mask(rgba, side, side, OwnerHand.Tones(mark));
        Assert.IsNotNull(glyph, mark.ToString());
        return glyph;
    }

    /// <summary>**The glyph at the screen's size keeps its soft edges** (<see cref="GlyphMask.Scaled"/>; the Mac draws it
    /// with <c>.interpolation(.high)</c>): each pixel is the mean opacity of the area that it covers. The bug that this
    /// catches: a glyph of 76 or 82 pixels shrunk to 10 or 21 by taking one pixel of each area, which is jagged, with gaps:
    /// its pixels almost only clear or opaque (built-pc.png of e41ed7149); and a glyph that is not square (Grok's,
    /// OpenCode's) drawn as a square.</summary>
    [TestMethod]
    public void TheGlyphAtTheScreensSizeKeepsItsSoftEdges()
    {
        // columns that change from clear to opaque at each pixel: at a tenth of the size, each pixel is half opaque
        var stripes = new GlyphMask(100, 100, Enumerable.Range(0, 100 * 100).Select(i => (byte)(i % 2 == 0 ? 0 : 255)).ToArray());
        var small = stripes.Scaled(10);
        Assert.AreEqual((10, 10), (small.Width, small.Height));
        Assert.IsTrue(small.Opacity.All(a => a is >= 120 and <= 135), string.Join(",", small.Opacity));
        Assert.AreSame(stripes, stripes.Scaled(100), "no larger than the screen draws it: as it is");
        // twice as wide as it is high, and twice as high as it is wide
        var wide = new GlyphMask(100, 50, Enumerable.Repeat((byte)255, 100 * 50).ToArray()).Scaled(10);
        Assert.AreEqual((10, 5), (wide.Width, wide.Height));
        var high = new GlyphMask(50, 100, Enumerable.Repeat((byte)255, 50 * 100).ToArray()).Scaled(10);
        Assert.AreEqual((5, 10), (high.Width, high.Height));
        Assert.IsTrue(wide.Opacity.Concat(high.Opacity).All(a => a == 255), "a full glyph stays full");

        foreach (var mark in Enum.GetValues<AiMark>())
        {
            var glyph = Glyph(mark);
            double Mean(GlyphMask m) => m.Opacity.Average(a => a / 255.0);
            // the glyph's side in pixels at 100, 125, 150, 175 and 200 %
            foreach (var scale in new[] { 1, 1.25, 1.5, 1.75, 2 })
            {
                var pixels = ScreenPixels.Side(18 * 0.58, scale);
                var scaled = glyph.Scaled(pixels);
                Assert.AreEqual(pixels, Math.Max(scaled.Width, scaled.Height), $"{mark} at {pixels}");
                Assert.AreEqual((double)glyph.Width / glyph.Height, (double)scaled.Width / scaled.Height, 0.06, $"{mark} at {pixels}: its proportions");
                Assert.AreEqual(Mean(glyph), Mean(scaled), 0.03, $"{mark} at {pixels}: as much ink");
                var inked = scaled.Opacity.Count(a => a > 0);
                var soft = scaled.Opacity.Count(a => a is > 0 and < 255);
                Assert.IsTrue(soft >= inked / 4, $"{mark} at {pixels}: {soft} of {inked} pixels between clear and opaque");
            }
        }
    }

    /// <summary>**The mark stands on whole pixels of the screen at each scale of Windows** (<see cref="ScreenPixels"/>): the
    /// layout rounds its own places, and not a transform's. The bug that this catches: the tile 7 left and 5 under the
    /// bubble's corner, which is 10.5 and 7.5 pixels at 150 %, so Windows draws the glyph between two pixels and it loses
    /// contrast.</summary>
    [TestMethod]
    public void TheMarkStandsOnWholePixelsOfTheScreen()
    {
        foreach (var scale in new[] { 1, 1.25, 1.5, 1.75, 2, 2.25, 2.5, 3 })
            foreach (var units in new[] { -7.0, 5.0 })
            {
                var pixels = ScreenPixels.Whole(units, scale) * scale;
                Assert.AreEqual(Math.Round(pixels), pixels, 1e-9, $"{units} at {scale}: whole pixels");
                Assert.AreEqual(units * scale, pixels, 0.5 + 1e-9, $"{units} at {scale}: the nearest ones");
            }
        CollectionAssert.AreEqual(new[] { 10, 13, 16, 18, 21 },
                                  new[] { 1, 1.25, 1.5, 1.75, 2 }.Select(scale => ScreenPixels.Side(18 * 0.58, scale)).ToArray(), "the glyph's side");
    }

    /// <summary>The straight RGBA pixels of a PNG of 8 bits for each of its four channels, with no interlace (the logos'
    /// form), row by row; for this test only.</summary>
    private static (byte[] Rgba, int Side) Rgba(byte[] png)
    {
        int width = 0, height = 0;
        using var packed = new MemoryStream();
        for (int at = 8; at < png.Length;)
        {
            int length = BinaryPrimitives.ReadInt32BigEndian(png.AsSpan(at));
            var type = Encoding.ASCII.GetString(png, at + 4, 4);
            var data = png.AsSpan(at + 8, length);
            if (type == "IHDR")
            {
                width = BinaryPrimitives.ReadInt32BigEndian(data);
                height = BinaryPrimitives.ReadInt32BigEndian(data[4..]);
                Assert.IsTrue(data[8] == 8 && data[9] == 6 && data[12] == 0, "an RGBA PNG of 8 bits with no interlace");
            }
            if (type == "IDAT") packed.Write(data);
            at += 12 + length;
        }
        packed.Position = 0;
        using var raw = new MemoryStream();
        using (var zlib = new ZLibStream(packed, CompressionMode.Decompress)) zlib.CopyTo(raw);
        var rows = raw.ToArray();
        int stride = width * 4;
        var pixels = new byte[height * stride];
        for (int y = 0; y < height; y++)
        {
            int filter = rows[y * (stride + 1)];
            for (int x = 0; x < stride; x++)
            {
                int value = rows[y * (stride + 1) + 1 + x];
                int a = x >= 4 ? pixels[y * stride + x - 4] : 0, b = y > 0 ? pixels[(y - 1) * stride + x] : 0;
                int c = x >= 4 && y > 0 ? pixels[(y - 1) * stride + x - 4] : 0;
                int p = a + b - c, pa = Math.Abs(p - a), pb = Math.Abs(p - b), pc = Math.Abs(p - c);
                int predicted = filter switch
                {
                    1 => a, 2 => b, 3 => (a + b) / 2, 4 => pa <= pb && pa <= pc ? a : pb <= pc ? b : c, _ => 0,
                };
                pixels[y * stride + x] = (byte)(value + predicted);
            }
        }
        Assert.AreEqual(width, height, "a square logo");
        return (pixels, width);
    }
}
