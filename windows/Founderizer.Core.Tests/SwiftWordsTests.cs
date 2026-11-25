using System;
using System.IO;
using System.Linq;
using Microsoft.VisualStudio.TestTools.UnitTesting;
using static Founderizer.Core.Tests.SampleFleet;

namespace Founderizer.Core.Tests;

/// <summary>The words that the library gives the screens where the Swift writes them in its views, which no FleetCore
/// test can call: each is held equal to the Swift's own literal, read from the source file that the build copies beside
/// the tests (as CreditTests reads Credit.swift). A value that the Swift puts into its sentence, "\(n)", is put into the
/// literal here, so the sentence is compared whole.</summary>
[TestClass]
public sealed class SwiftWordsTests
{
    /// <summary>The Swift literal in <paramref name="file"/>, as written there between its quotes; the test fails when
    /// the file does not hold it, so a change of the Swift's words fails here first.</summary>
    private static string Literal(string file, string literal)
    {
        var source = File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "sources", file));
        Assert.IsTrue(source.Contains("\"" + literal + "\"", StringComparison.Ordinal), $"{file} no longer says \"{literal}\"");
        return literal;
    }

    private static string With(string literal, string swiftValue, object value) => literal.Replace(swiftValue, value.ToString());

    [TestMethod]
    public void APressedOptionSaysSendingAsTheMacsCard()
    {
        Assert.AreEqual(Literal("NeedRequestCard.swift", "Sending…"), new OptionsModel().SendingWords);
    }

    /// <summary>An answer that waits ends its line with the Mac's "Undo", the task's Pause there says "Pause", and an
    /// assistive app hears the Mac's "Open the task" for the mark that opens it (NeedRequestCard.lineEnd and its
    /// actions): a Windows word of its own would be a word that the owner did not approve.</summary>
    [TestMethod]
    public void AnAnswerThatWaitsSaysUndoAsTheMacsCard()
    {
        var card = new RequestCard();
        Assert.AreEqual((Literal("NeedRequestCard.swift", "Undo"), Literal("NeedRequestCard.swift", "Pause"),
                         Literal("NeedRequestCard.swift", "Open the task")), (card.UndoWords, card.PauseWords, card.OpenWords));
        Assert.AreEqual(card.UndoWords, new RequestStep().UndoWords, "the same word on Needs you");
    }

    /// <summary>The hold of words that look like a key says the Mac's words (KeyHoldBanner): its first line, the start of
    /// its second up to what this app cannot do (the vault's form), and "Keep it". A Windows word of its own would be a
    /// word that the owner did not approve.</summary>
    [TestMethod]
    public void TheHoldOfAKeySaysTheMacsWords()
    {
        var line = Literal("SecretRequestViews.swift", "In a message, \\(agent.agentLabel) and its transcripts would have it. Saved as a secret, it goes straight into the vault, and \\(agent.agentLabel) gets only its name.");
        var s = State(Decode(Snapshot()), Clock) with { Drafts = System.Collections.Immutable.ImmutableDictionary<string, string>.Empty.Add("wren", "sk-proj-" + "EXAMPLEexampleEXAMPLE0123456789ab") };
        var hold = Screens.Chat(s, "wren", Clock, Utc).Composer.KeyHold!;
        Assert.AreEqual(Literal("SecretRequestViews.swift", "This message holds what looks like a key."), hold.Words);
        Assert.AreEqual(Literal("SecretRequestViews.swift", "Keep it"), hold.KeepWords);
        Assert.AreEqual(With(line, "\\(agent.agentLabel)", s.Names.Label("wren"))[..hold.Line.Length], hold.Line);
    }

    [TestMethod]
    public void TheComposersPlusHasTheAttachButtonsHover()
    {
        var some = Literal("AttachmentViews.swift", "Send a picture, a PDF, a ZIP or a text file with this message");
        var full = Literal("AttachmentViews.swift", "A message carries at most \\(MessageAttachment.perMessage) files");
        var s = State(Decode(Snapshot()), Clock);
        Assert.AreEqual(some, Screens.Chat(s, "manager", Clock, Utc).Composer.PlusHover);
        Assert.AreEqual(some, AttachWords.PlusHover(0));
        Assert.AreEqual(With(full, "\\(MessageAttachment.perMessage)", MessageAttachment.PerMessage),
                        AttachWords.PlusHover(MessageAttachment.PerMessage));
        Assert.AreEqual(Screens.Chat(s, "manager", Clock, Utc).Composer.PlusHover,
                        Screens.Card(s, s.Fleet!.Needs[0], [], Clock, Utc).Answer.PlusHover, "one plus, one sentence");
    }

    [TestMethod]
    public void TheTaskbarCountIsSaidInTheWordsOfTheMacsNeedsRow()
    {
        var none = Literal("FleetView.swift", "Nothing needs you");
        var one = Literal("FleetView.swift", "1 item needs you");
        var many = Literal("FleetView.swift", "\\(waiting) items need you");
        Assert.AreEqual((none, one, With(many, "\\(waiting)", 3)), (NeedsWords.Count(0), NeedsWords.Count(1), NeedsWords.Count(3)));
        Assert.AreEqual(With(many, "\\(waiting)", 2), Screens.TaskbarWords(State(Decode(Snapshot()), Clock)));
        var single = Snapshot();
        single["needs"]!.AsArray().RemoveAt(1);
        Assert.AreEqual(one, Screens.TaskbarWords(State(Decode(single), Clock)));
        var empty = Snapshot();
        empty["needs"] = new System.Text.Json.Nodes.JsonArray();
        Assert.IsNull(Screens.TaskbarWords(State(Decode(empty), Clock)), "no count, no sentence");
        Assert.AreEqual(none, Screens.Pane(State(Decode(empty), Clock), Page.Needs, Clock, Utc).NeedsHover);
    }

    [TestMethod]
    public void AUsageShareIsWrittenAsBothAppsWriteIt()
    {
        // The Mac: Text("\(Int(window.used_percent.rounded()))%"); the iPhone: Text("\(percent)%").
        var mac = Literal("AgentStatusPanel.swift", "\\(Int(window.used_percent.rounded()))%");
        var phone = Literal(Path.Combine("ios", "AgentPage.swift"), "\\(percent)%");
        Assert.AreEqual(With(mac, "\\(Int(window.used_percent.rounded()))", 42), ShareWords.Of(42));
        Assert.AreEqual(With(phone, "\\(percent)", 100), new UsageRow("5 h", 100, UsageLevel.Full, null).ShareWords);
    }

    [TestMethod]
    public void AnEmptyChatAndAChatThatWasNotReadSayWhatTheAppsSay()
    {
        var empty = Literal("ThreadViews.swift", "No messages with \\(agent.agentLabel) yet");
        var reading = Literal(Path.Combine("ios", "ChatPage.swift"), "Reading…");
        var s = State(Decode(Snapshot()), Clock);
        var chat = Screens.Chat(s, "pax", Clock, Utc);
        Assert.AreEqual(With(empty, "\\(agent.agentLabel)", "Pax"), chat.EmptyWords);
        Assert.AreEqual(reading, chat.LoadingWords);
    }

    [TestMethod]
    public void ATasksResultHasTheMacsLabels()
    {
        var model = new ResultModel();
        Assert.AreEqual(Literal("ThreadViews.swift", "Output"), model.OutputLabel);
        Assert.AreEqual(Literal("ThreadViews.swift", "How it was checked"), model.HowLabel);
        Assert.IsTrue(File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "sources", "ThreadViews.swift"))
                          .Contains("String(l10n: \"No result reported\")", StringComparison.Ordinal));
    }
}
