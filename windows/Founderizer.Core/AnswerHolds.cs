using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;

namespace Founderizer.Core;

/// <summary>An answer that a request's card sends (the presses that the Mac's AnswerHolds holds): an option, the ticked
/// options, one of the app's quick replies, or his words in the answer box with its files.</summary>
public enum CardAnswerKind { Option, Ticks, Reply, Words }

/// <summary>One answer that a card sends (<see cref="OwnerStore.Hold"/>). <see cref="Words"/> of a typed answer
/// (<see cref="Typed"/>) are the box's draft at the press, which the store reads itself.</summary>
public sealed record CardAnswer
{
    public CardAnswerKind Kind { get; private init; }
    /// <summary>The option's 0-based index (<see cref="CardAnswerKind.Option"/>), else -1.</summary>
    public int Choice { get; private init; } = -1;
    /// <summary>The ticked options in order (<see cref="CardAnswerKind.Ticks"/>), else none.</summary>
    public ValueList<int> Ticks { get; private init; } = ValueList<int>.Empty;
    /// <summary>A quick reply's words, or his typed words once the store read them from the box.</summary>
    public string Words { get; init; } = "";

    public static CardAnswer Option(int choice) => new() { Kind = CardAnswerKind.Option, Choice = choice };
    public static CardAnswer Ticked(IEnumerable<int> choices) =>
        new() { Kind = CardAnswerKind.Ticks, Ticks = ValueList.Of(choices.Distinct().Order()) };
    public static CardAnswer Reply(string words) => new() { Kind = CardAnswerKind.Reply, Words = words.Trim() };
    /// <summary>His words in the box, with the box's files.</summary>
    public static readonly CardAnswer Typed = new() { Kind = CardAnswerKind.Words };
}

/// <summary>**His answer on a card, which waits 5 seconds with Undo before it goes** (<see cref="OwnerStore.Hold"/>):
/// the request, the hub and the generation of the press, the answer, and what the card shows meanwhile
/// (<see cref="Shown"/>: the answer as one on its way shows, never saved and never sent). <see cref="Leaving"/>: its wait
/// ended and its press runs now, so the card stays folded, with no Undo, until the press went or was dropped.</summary>
public sealed record HeldAnswer(long Need, Uri Hub, string Database, CardAnswer Answer, PendingRequest Shown, long Number)
{
    public bool Leaving { get; init; }
}

/// <summary>What his last Undo of a card gave back (<see cref="OwnerStore.Undo"/>): its number, which no other Undo has,
/// and the options that he had ticked. The card's box loads its words again, and ticks them again, once for each
/// number.</summary>
public sealed record UndoneAnswer(long Number, ValueList<int> Ticks);

/// <summary>**What a card's answer box and its ticks take at a draw** (the view's AnswerParts.Show; as
/// <see cref="ClarifyField"/> for the field of Needs clarification): the store's draft and the ticks that an Undo gave
/// back go in when the view shows another card (a chat row that the list uses again, the next request at hand), and when
/// an Undo, or an answer that did not go, gave them back (<see cref="AnswerBoxModel.Given"/>); never at another draw,
/// which can come from a state older than his last key. **The ticks go to whichever view shows the card next, once**
/// (the Mac's restoredTicks(of:)): that view tells the store that it took them (<see cref="OwnerStore.TicksShown"/>).
/// An Undo that gives back no ticks (his typed words) leaves the ticks that the view shows.</summary>
public sealed class AnswerBoxLoad
{
    private long? need;
    private long given;

    /// <summary>A draw of card <paramref name="id"/>: the words to put in its box (null: leave it as it is), and the ticks
    /// to show in place of the view's (null: keep them).</summary>
    public (string? Load, IReadOnlyList<int>? Ticks) Show(long id, OptionsModel options, AnswerBoxModel box)
    {
        if (need != id)
        {
            need = id;
            given = box.Given;
            return (box.Draft, options.Ticked);
        }
        if (box.Given == given) return (null, null);
        given = box.Given;
        return (box.Draft, options.Ticked.Count > 0 ? options.Ticked : null);
    }
}

public sealed partial class OwnerStore
{
    /// <summary>How long his answer waits on its card with Undo: 5 seconds (the owner's "Yes, 5 seconds (Recommended)",
    /// 21 November 2026).</summary>
    public static readonly TimeSpan AnswerWait = TimeSpan.FromSeconds(5);

    /// <summary>The wait of each answer that waits, by request: its hold's number and its cancel.</summary>
    private readonly Dictionary<long, (long Number, CancellationTokenSource Cancel)> answerWaits = new();
    private long holdNumbers;
    private long undoNumbers;

    /// <summary>**His answer waits 5 seconds on its card, with Undo, before it goes** (the owner, 21 November 2026:
    /// "Sometimes I can make a mistake replying to a card... we need a way to be able to UNDO very easily", and his "Yes,
    /// 5 seconds (Recommended)": "Nothing goes to the hub until the 5 seconds end. A click on Undo opens the card again as
    /// it was."; the Mac's AnswerHolds). Each answer that a card sends waits here, whole, in the store's state
    /// (<see cref="StoreState.HeldAnswers"/>), so the card in a chat and the request at hand in Needs you show the same
    /// Undo; nothing of it reaches the outbox or the hub meanwhile, and the hub has no part in it. Then it goes on the
    /// path that it took before: <see cref="Press"/>, <see cref="TickAsync"/>, <see cref="Reply"/>, or his typed words
    /// with the box's files (<see cref="AnswerAsync"/>'s path, with the words that he sent). A newer answer of the same
    /// request takes the place of one that waits, also of a press or a quick reply that waits for the store.
    ///
    /// Not held, as before: the card of a key or a login (a held secret would stay in memory), a card whose own request
    /// waits unsent (its press is dropped), and a quick reply while a file of its box still goes up (its words stand in
    /// the box for Enter or Send). A message under a card (Needs clarification) is no answer.
    ///
    /// **His typed words stay in the store's draft, and in its file, while they wait** (<see cref="SetAnswerDraft"/>): the
    /// box that empties at his Send is the view's change, so a crash, a kill or the app's end in the 5 seconds loses
    /// nothing; the outbox's receipt takes them out of the draft, as before (Finish).</summary>
    /// <returns>The words that the card's box shows now, where the store put them into its draft at once: a quick reply
    /// that waits for nothing (a key request, a card whose own request waits unsent, a file of its box that goes up), whose
    /// words stand in the box as before. Null where the box keeps what it shows.</returns>
    public string? Hold(long need, CardAnswer answer)
    {
        var s = State;
        if (s.Hub is not { } hub || s.Fleet is not { } fleet || fleet.Needs.FirstOrDefault(n => n.Id == need && n.IsOpen) is not { } item)
            return null;
        if (s.HeldOn(need) is { Leaving: true }) return null;
        if (answer.Kind == CardAnswerKind.Words) answer = answer with { Words = s.AnswerDrafts.GetValueOrDefault(need, "").Trim() };
        // a press behind this card's own request that waits unsent is dropped at once, as before (Press)
        if (item.AsksForSecret || s.WaitsUnsent(need) || answer.Kind == CardAnswerKind.Reply && s.FilesWait("need:" + need))
        {
            _ = Go(need, answer, hub, fleet.Db);
            return answer.Kind == CardAnswerKind.Reply ? answer.Words : null;
        }
        if (Shown(s, hub, fleet.Db, item, answer) is not { } shown) return null;
        var number = Interlocked.Increment(ref holdNumbers);
        var held = new HeldAnswer(need, hub, fleet.Db, answer, shown, number);
        lock (pressWaits)
        {
            if (pressWaits.Remove(need, out var press)) press.Cancel.Cancel();
        }
        lock (replyWaits) replyWaits.Remove(need);
        var wait = new CancellationTokenSource();
        lock (answerWaits)
        {
            if (answerWaits.Remove(need, out var before)) before.Cancel.Cancel();
            answerWaits[need] = (number, wait);
        }
        Update(x => x with { HeldAnswers = x.HeldAnswers.SetItem(need, held), WaitingPresses = x.WaitingPresses.Remove(need) });
        _ = WaitAsync(need, number, wait.Token);
        return null;
    }

    /// <summary>A view showed the ticks that Undo <paramref name="number"/> gave back to card <paramref name="need"/>
    /// (<see cref="AnswerBoxLoad"/>): no other view ticks them again (the Mac's restoredTicks(of:), once).</summary>
    public void TicksShown(long need, long number) =>
        Update(x => x.Undone.TryGetValue(need, out var undone) && undone.Number == number && undone.Ticks.Count > 0
            ? x with { Undone = x.Undone.SetItem(need, undone with { Ticks = ValueList<int>.Empty }) } : x);

    /// <summary>**Undo**: the answer that waits on this request goes nowhere, and the card opens as it was: his typed
    /// words back in the box (the draft kept them while the box was empty), the options that he had ticked
    /// (<see cref="StoreState.Undone"/>), and his files, which stayed in the box. True when an answer waited; after its
    /// wait ended, Undo does nothing.</summary>
    public bool Undo(long need)
    {
        HeldAnswer? taken = null;
        var number = Interlocked.Increment(ref undoNumbers);
        Update(x =>
        {
            if (x.HeldOn(need) is not { Leaving: false } held) return x;
            taken = held;
            var words = held.Answer.Kind == CardAnswerKind.Words ? held.Answer.Words : "";
            return x with
            {
                HeldAnswers = x.HeldAnswers.Remove(need),
                AnswerDrafts = words.Length > 0 && x.AnswerDrafts.GetValueOrDefault(need, "").Length == 0
                    ? x.AnswerDrafts.SetItem(need, words) : x.AnswerDrafts,
                Undone = x.Undone.SetItem(need, new UndoneAnswer(number, held.Answer.Ticks)),
            };
        });
        if (taken is null) return false;
        lock (answerWaits)
        {
            if (answerWaits.TryGetValue(need, out var wait) && wait.Number == taken.Number)
            {
                answerWaits.Remove(need);
                wait.Cancel.Cancel();
            }
        }
        if (taken.Answer.Kind == CardAnswerKind.Words) KeepDrafts();
        return true;
    }

    /// <summary>What the card shows while the answer waits, as an answer on its way shows; null for an answer that the
    /// card cannot send (an option that is not there, ticks of options that do not combine, no words and no file, more
    /// than the limit).</summary>
    private PendingRequest? Shown(StoreState s, Uri hub, string database, OwnerNeed item, CardAnswer answer)
    {
        switch (answer.Kind)
        {
            case CardAnswerKind.Option when answer.Choice >= 0 && answer.Choice < item.Choices.Count:
                return PendingRequest.New(hub, database, settings.ClientLabel, item.Choices[answer.Choice], needId: item.Id,
                                          choice: answer.Choice);
            case CardAnswerKind.Ticks when item.Combines && answer.Ticks.Count > 0 && answer.Ticks.All(c => c >= 0 && c < item.Choices.Count):
                // The Mac's words of ticked options (FleetStore.answer(choices:)), as TickAsync writes them.
                return PendingRequest.New(hub, database, settings.ClientLabel, string.Join("; ", answer.Ticks.Select(c => item.Choices[c])),
                                          needId: item.Id, choices: answer.Ticks.Select(c => (long)c));
            case CardAnswerKind.Reply when answer.Words.Length > 0:
            case CardAnswerKind.Words when (answer.Words.Length > 0 || s.ReadyFiles("need:" + item.Id).Count > 0) &&
                                           new StringInfo(answer.Words).LengthInTextElements <= StoreState.TextLimit:
                return PendingRequest.New(hub, database, settings.ClientLabel, answer.Words, needId: item.Id);
            default:
                return null;
        }
    }

    private async Task WaitAsync(long need, long number, CancellationToken cancel)
    {
        try
        {
            await clock.Delay(AnswerWait, cancel);
        }
        catch (OperationCanceledException)
        {
            return;
        }
        Release(need, number);
    }

    /// <summary>**The answer that waits on this request goes now**, once: at the end of its wait (<paramref name="number"/>,
    /// its hold's), or at the app's end (null). It is taken in one step with the check that it still waits, so the wait,
    /// the app's end and Undo never send it twice and never send one that he took back. It goes only to the hub and
    /// generation of the press; it stays on the card as on its way (<see cref="HeldAnswer.Leaving"/>) until its press
    /// went or was dropped, so the card does not open for a moment before the outbox has it.</summary>
    private void Release(long need, long? number)
    {
        HeldAnswer? taken = null;
        Update(x =>
        {
            if (!x.HeldAnswers.TryGetValue(need, out var held) || held.Leaving || number is { } n && held.Number != n) return x;
            taken = held;
            return x with { HeldAnswers = x.HeldAnswers.SetItem(need, held with { Leaving = true }) };
        });
        if (taken is null) return;
        lock (answerWaits)
        {
            if (answerWaits.TryGetValue(need, out var wait) && wait.Number == taken.Number) answerWaits.Remove(need);
        }
        var s = State;
        var going = s.Hub == taken.Hub && s.Fleet?.Db == taken.Database ? Go(need, taken.Answer, taken.Hub, taken.Database) : Task.CompletedTask;
        _ = LeftAsync(taken, going);
    }

    /// <summary>The press of a held answer ended: the hold goes. **An answer that did not go opens its card as it was**
    /// (the reviewer's round 1): where the request is still open on the hub and generation of the press, with no
    /// request of it on its way or taken, its card gets back its ticks and the box its words, as at an Undo (his typed
    /// words stayed in the draft; a quick reply's words are there now), so the box never shows other words than the
    /// draft that a Send would send.</summary>
    private async Task LeftAsync(HeldAnswer held, Task going)
    {
        try
        {
            await going;
        }
        finally
        {
            var number = Interlocked.Increment(ref undoNumbers);
            Update(x =>
            {
                if (!x.HeldAnswers.TryGetValue(held.Need, out var now) || now.Number != held.Number) return x;
                x = x with { HeldAnswers = x.HeldAnswers.Remove(held.Need) };
                var stays = !disposed && held.Answer.Kind != CardAnswerKind.Option && x.Hub == held.Hub &&
                            x.Fleet is { } fleet && fleet.Db == held.Database && fleet.Needs.Any(n => n.Id == held.Need && n.IsOpen) &&
                            x.Pending?.NeedId != held.Need && !x.AnswersTaken.ContainsKey(held.Need);
                return stays ? x with { Undone = x.Undone.SetItem(held.Need, new UndoneAnswer(number, held.Answer.Ticks)) } : x;
            });
        }
    }

    /// <summary>**At the app's end every answer that waits goes at once** (the Mac's releaseAll at a quit): each takes its
    /// path now, in this call, so one that the store can write now is in the outbox before the store ends, and the next
    /// start has it there. One that cannot go in this run (another write on its way, or a reading that is not current)
    /// goes nowhere, and its request stays open on the hub, as a press that waits for the store does at the app's end.</summary>
    private void ReleaseHeld()
    {
        foreach (var need in State.HeldAnswers.Keys.ToList()) Release(need, null);
    }

    /// <summary>The press of an answer, on the path that it took before the hold; the ticks and his typed words wait for
    /// the store as an option's press and a quick reply do (<see cref="WritableAsync"/>).</summary>
    private Task Go(long need, CardAnswer answer, Uri hub, string database) => answer.Kind switch
    {
        CardAnswerKind.Option => PressAsync(need, answer.Choice),
        CardAnswerKind.Ticks => WritableAsync(need, hub, database, () => TickAsync(need, answer.Ticks)),
        CardAnswerKind.Reply => ReplyGoes(need, answer.Words),
        _ => WritableAsync(need, hub, database, () => Answer(need, answer.Words, still: null)),
    };

    /// <summary>**Held ticks and typed words wait until the store can write, as an option's press does** (PressAsync; the
    /// reviewer's round 1, as the Mac's round 1, FleetStore.writable): when their wait ends the store can be unable to
    /// write for a cause that WriteAsync takes as lasting (a request that waits in the outbox, a reading that is not
    /// current), and then they went nowhere. They go once it can write, only to the hub and generation of the press,
    /// while the request is open, the outbox can be used and the card's own request does not wait unsent; no clock ends
    /// the wait. A write that another write took the turn from in the meantime tries again: one that the outbox saved is
    /// the card's own request then, and ends the wait.</summary>
    private async Task WritableAsync(long need, Uri hub, string database, Func<Task<string?>> write)
    {
        while (!disposed)
        {
            var s = State;
            if (s.Hub != hub || s.Fleet?.Db != database || s.StorageError is not null || s.WaitsUnsent(need) ||
                s.Fleet?.Needs.Any(n => n.Id == need && n.IsOpen) != true)
                return;
            if (s.CanWrite(clock.Now) && await write() is null) return;
            await clock.Delay(TimeSpan.FromMilliseconds(250), CancellationToken.None);
        }
    }
}
