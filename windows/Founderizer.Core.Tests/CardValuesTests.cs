using System.Linq;
using Microsoft.VisualStudio.TestTools.UnitTesting;
using static Founderizer.Core.Tests.SampleFleet;

namespace Founderizer.Core.Tests;

/// <summary>A value in a request's words, which the card draws as a chip with a copy icon (<see cref="CardValues"/>, the
/// Mac's FleetCore CardValues): only what the agent put in inline code, copied exactly.</summary>
[TestClass]
public sealed class CardValuesTests
{
    /// <summary>The values of a text, and the check that each one's place in the plain words holds its characters: the
    /// chip's fill (the text block's highlighter of that place) and its copy are the same characters.</summary>
    private static string[] Values(string text)
    {
        var runs = InlineMarks.Runs(text);
        var plain = string.Concat(runs.Select(r => r.Text));
        var values = CardValues.Of(runs);
        foreach (var value in values) Assert.AreEqual(value.Text, plain.Substring(value.Start, value.Length), text);
        CollectionAssert.AreEqual(values.Select(v => v.Text).ToArray(), CardValues.Values(text).ToArray(), text);
        return [.. values.Select(v => v.Text)];
    }

    /// <summary>**The Mac's own case** (FleetCore CardValuesTests, aValueIsInlineCodeWithItsExactCharacters), with no
    /// names, because Windows draws no names as badges in a card's words: a plain inline code is a value with its exact
    /// characters, a trailing space too, and so is a knowledge file's path (on the Mac that one is its badge); code in
    /// the words of a link, whose press is the link's, and code of white space only are no value.</summary>
    [TestMethod]
    public void AValueIsInlineCodeWithItsExactCharacters()
    {
        CollectionAssert.AreEqual(new[] { "acme-logs", "ls ", "knowledge/owner/brand.md", "cat knowledge/owner/brand.md" },
            Values("Make the bucket `acme-logs`, name it `ls ` and read `knowledge/owner/brand.md` and `cat knowledge/owner/brand.md`. Keep `  ` as it is."));
        Assert.AreEqual(0, Values("Nova has no code here.").Length);
        Assert.AreEqual(0, Values("Open [`acme-logs`](https://console.example.com) first.").Length);
    }

    /// <summary>**A copy holds the characters that the Mac copies**: the code as Foundation's AttributedString reads it
    /// (CommonMark), measured on a Mac on 21 November 2026. One space goes from each end only when both ends have one; a
    /// line's end is a space; a backslash and an entity in code stay as written (a share, a Windows folder); a run of
    /// backticks closes only one as long; an escaped backtick opens nothing; code over two runs of marks is one value. A
    /// reader that took the escapes first copied `\\server\share` as "\server\share".</summary>
    [TestMethod]
    public void ACopyHoldsTheCharactersThatTheMacCopies()
    {
        (string Text, string[] Values)[] cases =
        [
            ("a ` ls ` b", ["ls"]),
            ("a `ls ` b", ["ls "]),
            ("a `` x`y `` b", ["x`y"]),
            ("Use `` ` `` here", ["`"]),
            ("`   x   `", ["  x  "]),
            ("x `one\ntwo` y", ["one two"]),
            ("`one\r\ntwo`", ["one two"]),
            ("`a&amp;b`", ["a&amp;b"]),
            (@"`C:\fz\`", [@"C:\fz\"]),
            (@"`\\server\share`", [@"\\server\share"]),
            (@"`a\_b`", [@"a\_b"]),
            (@"\\`x`", ["x"]),
            (@"\`x\`", []),
            (@"\``x`", ["x"]),
            (@"\```x``", ["x"]),
            ("a` `b", []),
            ("a `x``", []),
            ("a ``` b", []),
            ("`a`b`", ["a"]),
            ("`a``b`", ["a``b"]),
            ("**`a`**`b`", ["ab"]),
            ("`a` `b`", ["a", "b"]),
            ("`*.log` and `**/bin`", ["*.log", "**/bin"]),
        ];
        foreach (var (text, values) in cases) CollectionAssert.AreEqual(values, Values(text), text);
        Assert.AreEqual(@"\x and \\server\share", InlineMarks.Plain(@"\\x and `\\server\share`"), "the words around the code keep their escapes");
    }

    /// <summary>**Where a card draws values**: in the reason, the task, the details and the task behind the link of a
    /// request's card and of the request at hand, block by block (a code block has its own copy icon and is no value);
    /// never in a door's script, the Mac's MessageText(values: door_script == nil), whose details are the script that he
    /// signs, also where they hold inline code.</summary>
    [TestMethod]
    public void ACardHasValuesInItsWordsAndNoneInADoorsScript()
    {
        var fleet = State(Decode(Snapshot()), Clock);
        var need = new OwnerNeed(7, "Turn the backups on?", "The backups of `web-1` stopped.", "Run `example-backup --now`, then answer.",
                                 Now - 60, "manager", Details: "- the timer `example-backup.timer`\n\n```\nexample-backup --check\n```");
        foreach (var body in new[] { Screens.Card(fleet, need, [], Clock, Utc).Body, Screens.Step(fleet, need, [], Clock, Utc).Body })
        {
            CollectionAssert.AreEqual(new[] { "web-1" }, body.WhyValues.Single().Select(v => v.Text).ToArray());
            CollectionAssert.AreEqual(new[] { "example-backup --now" }, body.TaskValues.Single().Select(v => v.Text).ToArray());
            Assert.AreEqual(body.DetailsBlocks.Count, body.DetailsValues.Count);
            CollectionAssert.AreEqual(new[] { "example-backup.timer" }, body.DetailsValues[0].Select(v => v.Text).ToArray());
            Assert.AreEqual(0, body.DetailsValues[1].Count, "a code block");
        }
        var door = need with
        {
            DoorCall = new string('a', 64), DoorHost = "web-1", DoorScript = "#!/bin/sh\nexample-backup --now\n",
            Details = "Runs `example-backup`:\n\n```\n#!/bin/sh\nexample-backup --now\n```",
        };
        foreach (var body in new[] { Screens.Card(fleet, door, [], Clock, Utc).Body, Screens.Step(fleet, door, [], Clock, Utc).Body })
        {
            Assert.IsTrue(body.DetailsIsScript);
            Assert.AreEqual(0, body.DetailsValues.Sum(b => b.Count), "a door's script");
            // its task stays behind the link, and its values are the steps'
            CollectionAssert.AreEqual(new[] { "example-backup --now" }, body.TodoBehindValues.Single().Select(v => v.Text).ToArray());
        }
    }
}
