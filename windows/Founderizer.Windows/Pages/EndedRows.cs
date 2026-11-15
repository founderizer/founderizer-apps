using System.Collections.Generic;
using System.Linq;
using Founderizer.Core;

namespace Founderizer.Windows.Pages;

/// <summary>One ended row (pictures 5 and 12): the agent's mark at 16, the title cut with "…", and a red word on a red
/// capsule for a result that did not succeed; a press opens the task or the request <see cref="Id"/>. It holds no
/// delegate, so a row that did not change is equal to the row before it and keeps its view.</summary>
internal sealed record EndedLine(string Key, MarkLook? Mark, string Title, string? Badge, long Id)
{
    /// <summary>The muted words at the row's end (the Mac's EndedRow note): "×N" on a row of several tasks, the state
    /// word of one task whose result is not checked ("Awaiting check", "Canceled"), a run's time.</summary>
    public string? Note { get; init; }

    /// <summary>A run under its row: no mark, its muted title where the row's title begins.</summary>
    public bool Indent { get; init; }

    /// <summary>The tasks of a row of several, newest first: a press opens them under it, each with its time, and a
    /// press on one opens that task (the Mac's restRows).</summary>
    public ValueList<EndedLine>? Runs { get; init; }

    /// <summary>A row of several whose runs show under it.</summary>
    public bool Opened { get; init; }
}

/// <summary>One line of the opened rest: a day's heading (<see cref="Line"/> null), or a row of that day.</summary>
internal sealed record EndedItem(string Key, string? Day, EndedLine? Line);

/// <summary>The lines of an Ended part (EndedView), from the library's models.</summary>
internal static class EndedRows
{
    /// <summary>The lines of the board's Ended lane: the results that he must see, and the rest's rows by day; a row of
    /// several tasks opens the newest of them.</summary>
    public static (IReadOnlyList<EndedLine> First, IReadOnlyList<(string Day, IReadOnlyList<EndedLine> Rows)> Days) Of(EndedModel end) =>
        (end.Failed.Select(r => new EndedLine(r.Key, r.Mark, r.Title, r.Badge, r.Id)).ToList(),
         end.Days.Select(day => (day.Day, (IReadOnlyList<EndedLine>)day.Groups.Select(Row).ToList())).ToList());

    /// <summary>A row of the rest: one task with its state word when its result is not checked, or several tasks as one
    /// row with their number, which opens them.</summary>
    private static EndedLine Row(EndedGroup g) => g.Tasks.Count == 1
        ? new EndedLine(g.Key, g.Mark, g.Title, null, g.Tasks[0].Id) { Note = g.Note }
        : new EndedLine(g.Key, g.Mark, g.Title, null, g.Tasks[0].Id)
        {
            Note = g.Note,
            Runs = ValueList.Of(g.Tasks.Select(t => new EndedLine("run-" + t.Id, null, t.Title, null, t.Id) { Note = t.Time, Indent = true })),
        };

    /// <summary>The opened rest as one list: each day's heading, then its rows, and under each row of several that he
    /// opened (<paramref name="opened"/>, by key) its runs.</summary>
    public static List<EndedItem> Items(IReadOnlyList<(string Day, IReadOnlyList<EndedLine> Rows)> days, IReadOnlySet<string>? opened = null)
    {
        var items = new List<EndedItem>();
        foreach (var (day, rows) in days)
        {
            items.Add(new EndedItem("day-" + day, day, null));
            foreach (var line in rows)
            {
                var open = line.Runs is not null && opened is not null && opened.Contains(line.Key);
                items.Add(new EndedItem(line.Key, null, open ? line with { Opened = true } : line));
                if (open) foreach (var run in line.Runs!) items.Add(new EndedItem(run.Key, null, run));
            }
        }
        return items;
    }
}
