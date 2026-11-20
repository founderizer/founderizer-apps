using System;
using System.Collections.Generic;
using System.Linq;

namespace Founderizer.Core;

/// <summary><b>The heads of the ended tasks that a window read leaves out</b> (owner API 1.270, owner feature
/// `ended_blocks`), kept as the Mac keeps the blocks of older tasks (FleetCore's OlderTasks).
///
/// GET /ui/mobile/ended held the head of every ended task: 868,736 bytes for 1,669 heads on the first fleet on 20 November
/// 2026, about 0.13 MB more a day. The store asks for the window (the heads of the newest ids), reads the older heads in
/// blocks of 100 ids, each once and again only when its mark moves, keeps them (also in its folder), and joins them to
/// each window read: the Ended lane counts and opens every ended task, as before.
///
/// A head that leaves the window stays until its block comes. The heads of a block that the window just left are in no
/// answer that the store holds at that moment: <see cref="Join"/> keeps the heads that the lane showed for a block that
/// it does not hold, while the blocks are not the hub's own of that moment (<see cref="Current"/> is not the window's
/// mark). A block that it holds answers for its own ids, and when the blocks are the hub's own, a head that is in
/// neither the window nor a block is gone, and it leaves.
///
/// One read at a time uses it: the store's passes.</summary>
public sealed class EndedBlocks
{
    /// <summary>The reads of one block at one mark that fail before the read of the blocks rests.</summary>
    public const int Tries = 3;

    private readonly Dictionary<long, EndedBlock> blocks = new();
    private readonly Dictionary<long, (string Mark, int Times)> failed = new();

    /// <summary>The hub generation whose blocks these are.</summary>
    public string? Db { get; private set; }
    /// <summary>`older` of the newest window read, or null: the window held every head.</summary>
    public EndedOlder? Head { get; private set; }
    /// <summary>The mark of `older` at which every block here is the hub's own, or null: not known.</summary>
    public string? Current { get; private set; }
    /// <summary>The mark at which the read of the blocks rests although a block is not the hub's own: that block's answer
    /// could not be read <see cref="Tries"/> times at its mark. At a list with a new mark it is asked for once more.</summary>
    public string? Rested { get; private set; }
    /// <summary>The blocks, each once.</summary>
    public IReadOnlyCollection<EndedBlock> Held => blocks.Values;

    public EndedBlocks() { }

    /// <summary>The blocks that the store kept in its folder, for the generation of the reading kept with them. Whether
    /// they are the hub's own of now is not known: the first window read says its mark, and the list then says which of
    /// them to read again.</summary>
    public EndedBlocks(IEnumerable<EndedBlock> kept, string db)
    {
        Db = db;
        foreach (var block in kept) if (block.Db == db) blocks[block.From] = block;
    }

    /// <summary>Takes a window read, whose `older` the blocks are read for. A window with no `older` holds every head (a
    /// hub from before owner API 1.270, or one whose marks are not in place), and a window of another generation holds
    /// none of these blocks: then the blocks go. Gives the first ids of the blocks that went, for their files.</summary>
    public IReadOnlyList<long> See(EndedReading window)
    {
        var head = window.Older is { IsValid: true } older ? older : null;
        IReadOnlyList<long> gone = [];
        if (head is null || Db != window.Db)
        {
            gone = blocks.Keys.Order().ToList();
            blocks.Clear();
            failed.Clear();
            Current = Rested = null;
            Db = window.Db;
        }
        Head = head;
        return gone;
    }

    /// <summary>Whether the blocks must be read: the newest window leaves heads out, and its mark is neither the one that
    /// these blocks are current at nor the one that their read rests at.</summary>
    public bool IsBehind => Head is { } head && Current != head.Mark && Rested != head.Mark;

    /// <summary>The blocks of the list to read now: each one whose mark differs from the block held, the newest first. A
    /// block whose answer could not be read <see cref="Tries"/> times at its mark is left out while the read rests at
    /// this list's mark, and asked for once more at a list with a new mark.</summary>
    public IReadOnlyList<EndedBlockEntry> Wanted(EndedBlockList list)
    {
        if (list.Db != Db) return [];
        var again = Rested is not null && Rested != list.Mark;
        return list.Blocks.Where(b => (!blocks.TryGetValue(b.From, out var held) || held.Mark != b.Mark) && (again || !GaveUp(b)))
            .OrderByDescending(b => b.From).ToList();
    }

    private bool GaveUp(EndedBlockEntry entry) =>
        failed.TryGetValue(entry.From, out var failure) && failure.Mark == entry.Mark && failure.Times >= Tries;

    /// <summary>Takes one block that the hub gave; false for a block of another generation, which is none of these.</summary>
    public bool Take(EndedBlock block)
    {
        if (block.Db != Db) return false;
        blocks[block.From] = block;
        failed.Remove(block.From);
        return true;
    }

    /// <summary>The answer of one block could not be read (<see cref="BlockFailed"/>): the other blocks are still read, and
    /// this one is asked for again at the next reads, <see cref="Tries"/> times in all at its mark. A block with a new
    /// mark is a new answer, and counts from one.</summary>
    public void Fail(EndedBlockEntry entry)
    {
        var times = failed.TryGetValue(entry.From, out var failure) && failure.Mark == entry.Mark ? failure.Times + 1 : 1;
        failed[entry.From] = (entry.Mark, times);
    }

    /// <summary>Whether a failed read of a block is of that block's own answer: the hub gave one that this app cannot read,
    /// or could not make it (5xx). Then the other blocks are still read. Every other failure ends the read of the blocks,
    /// and the next pass starts it again: the hub did not answer, the generation moved (409), or the window came down
    /// over the block (404), which the next list no longer names.</summary>
    public static bool BlockFailed(HubException e) =>
        e.Kind == HubErrorKind.InvalidResponse || e is { Kind: HubErrorKind.Refusal, Status: >= 500 };

    /// <summary>After the blocks that the list asked for were read: the blocks that the list does not name go (the window
    /// came down over them), and when each block has the list's mark, the blocks are current at the list's own mark. A
    /// block that changed between the list and its read has a later mark: then the next list settles it. When the only
    /// blocks that differ are ones whose answer could not be read <see cref="Tries"/> times, the read rests at the list's
    /// mark. Gives the first ids of the blocks that went, for their files.</summary>
    public IReadOnlyList<long> Finish(EndedBlockList list)
    {
        if (list.Db != Db) return [];
        var named = list.Blocks.Select(b => b.From).ToHashSet();
        var gone = blocks.Keys.Where(from => !named.Contains(from)).Order().ToList();
        foreach (var from in gone) blocks.Remove(from);
        foreach (var from in failed.Keys.Where(from => !named.Contains(from)).ToList()) failed.Remove(from);
        var behind = list.Blocks.Where(b => !blocks.TryGetValue(b.From, out var held) || held.Mark != b.Mark).ToList();
        if (behind.Count == 0)
        {
            Current = list.Mark;
            Rested = null;
        }
        else if (behind.All(GaveUp))
        {
            Rested = list.Mark;
        }
        return gone;
    }

    /// <summary><b>The reading that the Ended lane draws for this window read</b>: its heads, and the heads of the blocks
    /// below `older.before`, each once, by id; a head of the window stands for a head of the same id in a block.
    /// <paramref name="shown"/> is the reading that the lane drew until now, from which the heads come of a block that
    /// has not come yet (see the type's own words). A window with no `older` is every head, and comes back as it is.</summary>
    public EndedReading Join(EndedReading window, EndedReading? shown)
    {
        if (window.Older is not { IsValid: true } head || window.Db != Db) return window with { Older = null };
        var heads = new Dictionary<long, MobileTaskHead>();
        foreach (var task in window.Tasks) heads[task.Id] = task;
        foreach (var block in blocks.Values.Where(b => b.From < head.Before))
            foreach (var task in block.Tasks) heads.TryAdd(task.Id, task);
        // A shown head stands only for a block that has not come yet: a held block answers for its own ids, so a task that
        // left the records leaves the lane with its block's next answer, also while another block waits.
        if (Current != head.Mark && shown is not null && shown.Db == window.Db)
            foreach (var task in shown.Tasks.Where(t => t.Id < head.Before && !blocks.ContainsKey(t.Id / head.Block * head.Block)))
                heads.TryAdd(task.Id, task);
        return new EndedReading(window.Db, window.Mark, heads.Values.OrderBy(t => t.Id).ToList());
    }
}
