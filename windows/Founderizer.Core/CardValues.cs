using System.Collections.Generic;
using System.Linq;
using System.Text;

namespace Founderizer.Core;

/// <summary>One value in a block's words: where its characters start in the block's plain words (the runs' words joined,
/// <see cref="InlineMarks.Plain"/>, which are the characters of the text block that draws them), and its characters,
/// exactly as the code holds them.</summary>
public sealed record CardValue(int Start, string Text)
{
    public int Length => Text.Length;
}

/// <summary>**A value in a request's words is what the agent put in inline code** (FleetCore's CardValues; the owner, 21
/// November 2026: "Sometimes tasks contain names, codes and other values that need to be copied... it would be nice to
/// identify those and add a small icon button next to them to copy them directly", and his "Yes, as drawn"). The app
/// guesses no value: only what the agent marked. A card draws each value as a chip with a copy icon, and a press copies
/// the value's characters exactly as the code holds them (<see cref="InlineMarks"/> reads a code span as CommonMark and
/// the Mac do), with nothing trimmed and nothing added.
///
/// Not a value: inline code in the words of a link, whose press is the link's; code of white space only, which holds
/// nothing to copy; and a code block, which has its own copy icon. The rule is the Mac's with no names
/// (<c>CardValues.values(in:names: nil)</c>): Windows draws no names as badges in a card's words, so a knowledge file's
/// path in inline code is a value here, and no name and its role are joined (the Mac's CardJoin). A link whose address
/// this PC does not open (not http, https or mailto) is words with no link on Windows (<see cref="InlineMarks.Runs"/>),
/// so its code is a value.
///
/// Where a card draws values is the card's to say (<see cref="RequestBody"/>): its reason, its task, its steps and its
/// details, never a door's script, the folded start of a long reason, his answer or a chat's message.</summary>
public static class CardValues
{
    /// <summary>The values of a block's runs, in their order: each stretch of runs of inline code with no link on it and
    /// not of white space only. Code that goes on over several runs (another mark changes on it, "**`a`**`b`") is one
    /// value.</summary>
    public static ValueList<CardValue> Of(IReadOnlyList<InlineRun> runs)
    {
        var found = new List<CardValue>();
        var words = new StringBuilder();
        int at = 0, start = -1;
        bool linked = false;
        void Close()
        {
            if (start >= 0 && !linked && words.ToString().Any(c => !char.IsWhiteSpace(c))) found.Add(new CardValue(start, words.ToString()));
            start = -1;
            linked = false;
            words.Clear();
        }
        foreach (var run in runs)
        {
            if (!run.Code) Close();
            else
            {
                if (start < 0) start = at;
                words.Append(run.Text);
                if (run.Link is not null) linked = true;
            }
            at += run.Text.Length;
        }
        Close();
        return ValueList.Of(found);
    }

    /// <summary>The values of one text's inline words, by their exact characters (a test reads the rule with no view).</summary>
    public static IReadOnlyList<string> Values(string text) => [.. Of(InlineMarks.Runs(text)).Select(v => v.Text)];

    /// <summary>The values of each block, in the blocks' order: those of a paragraph's, a heading's, an item's and a
    /// quote's words, and none in a code block, a rule or a table (the Mac draws a table's cells with no chip).</summary>
    public static ValueList<ValueList<CardValue>> OfBlocks(IReadOnlyList<MessageBlock> blocks) =>
        ValueList.Of(blocks.Select(b => b.Kind is MessageBlock.Kinds.Paragraph or MessageBlock.Kinds.Heading
                                                   or MessageBlock.Kinds.Item or MessageBlock.Kinds.Quote
            ? Of(b.Runs) : ValueList<CardValue>.Empty));
}
