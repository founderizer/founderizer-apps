using System.Collections.Generic;
using System.Linq;
using Founderizer.Core;

namespace Founderizer.Windows.Pages;

/// <summary>The kinds of a thread's rows: a chat's stamp, his message, the agent's reply, a request card and the
/// "Thinking" line; a task's notes are replies, and its last row says who did the work. A task's thread has besides its
/// result's line, check and checked outputs (a file's row, a file opened), its folds (a run of steps, a permission), the
/// steps of an open run, a line (an error, the record's cut, a read that failed, offline), his guidance, the plan of the
/// work that runs, "Earlier activity", and the head of a child agent's thread.</summary>
internal enum RowKind
{
    Stamp, Own, Reply, Request, Waiting, Who, Earlier, Rule, Check, Detail, OutputFile, OutputBox, Fold, Step,
    Line, Guidance, Plan, EarlierActivity, ChildHead,
}

/// <summary>One row of a thread: its key, its kind, the room above it, and the model it draws. Equal by value, so a row
/// whose model did not change is not drawn again.</summary>
internal sealed record ThreadItem(string Key, RowKind Kind, double Gap, object Model);

/// <summary>The mark of a fold or of a step (the Mac's toolSymbol, and hand.raised for a permission): the views draw each
/// as its Fluent icon.</summary>
internal enum FoldMark { Steps, Read, Search, Edit, Execute, Fetch, Other, Hand, Thought, Child, Plan }

/// <summary>A fold of a task's thread (RuntimeActivity): a run of steps ("8 steps", "1 failed") or a permission that
/// waits ("Bash", "Waiting"). A permission opens on its command in code, and its reason; a run's steps are rows of
/// their own (<see cref="StepRow"/>), so a long run is virtualized as a chat is.</summary>
internal sealed record FoldRowModel(string Key, FoldMark Mark, string Title, string Status, bool Warn, bool Open,
                                    string? Code = null, string? Words = null);

/// <summary>One step (the Mac's RuntimeRow): the library's row, its mark, whether it opened (and its script's result),
/// and whether it stands on its run's box (<paramref name="Boxed"/>, the first and the last step closing the box) or
/// alone, as in a child agent's thread.</summary>
internal sealed record StepRow(StepRowModel Step, FoldMark Mark, bool First, bool Last, bool Open, bool ScriptOpen, bool Boxed = true)
{
    /// <summary>The step over it in its run is open: its room is 20 under that step's content, not the 14.5 under a
    /// closed step's face.</summary>
    public bool AfterOpen { get; init; }
}

/// <summary>How a line of a thread looks: an error (orange with its mark, the chat's size), a read of the record that
/// failed (orange with its mark, small), offline (orange, small), the record's cut (muted, small), or a child agent
/// that wrote nothing yet (muted, the chat's size).</summary>
internal enum LineLook { Error, ActivityError, Offline, Cut, Waiting }

/// <summary>A line of a task's thread.</summary>
internal sealed record ThreadLine(string Text, LineLook Look);

/// <summary>His guidance in the thread (the Mac's OwnerBubble and its line).</summary>
internal sealed record GuidanceRow(SteerRowModel Steer);

/// <summary>The plan of the work that runs, open under the thread (the Mac's LivePlan), or a plan step's list.</summary>
internal sealed record PlanRow(ValueList<PlanStep> Steps);

/// <summary>"Earlier activity" over the thread's first shown row.</summary>
internal sealed record EarlierActivity(string Words);

/// <summary>The head of a child agent's thread: Back, its name, its attempt.</summary>
internal sealed record ChildHeadRow(string BackWords, string Title, string AttemptWords);

/// <summary>A task's thread (the library's ThreadRowModel, RuntimeActivity.entries) as rows: a run of steps is one fold,
/// and while it is open each of its steps is a row of its own under it; a permission is a fold that opens on its
/// command; the agent's message and a note are replies; his guidance is his bubble; an error and the record's cut are
/// lines. 21 between two of them.</summary>
internal static class TaskThreadRows
{
    /// <summary>The key of a step's script result fold among the open keys.</summary>
    public static string ScriptKey(string step) => step + "#script";

    /// <summary>The rows, in order: their key, kind, room above, and model. <paramref name="open"/>: the keys of the folds
    /// and steps that he opened; <paramref name="above"/>: the row over the first one ("Earlier activity", a line, what
    /// the task asks); <paramref name="firstGap"/>: the first row's room when the row over it says it (a line over the
    /// thread).</summary>
    public static IEnumerable<(string Key, RowKind Kind, double Gap, object Model)> Of(IReadOnlyList<ThreadRowModel> thread,
                                                                                      IReadOnlySet<string> open, RowKind? above = null,
                                                                                      double? firstGap = null)
    {
        bool aboveOpen = false;
        foreach (var row in thread)
        {
            bool isOpen = open.Contains(row.Key);
            double gap = firstGap ?? Under(above, aboveOpen);
            firstGap = null;
            switch (row.Kind)
            {
                case ThreadRowKind.Steps when row.Steps is { } run:
                    yield return (row.Key, RowKind.Fold, gap, new FoldRowModel(row.Key, Mark(run.Symbol), run.Title, run.Status, run.Orange, isOpen));
                    (above, aboveOpen) = (RowKind.Fold, false);
                    if (!isOpen) break;
                    for (int i = 0; i < run.Rows.Count; i++)
                    {
                        var step = run.Rows[i];
                        yield return (step.Key, RowKind.Step, i == 0 ? MacLine + 8 - FoldFace : 0,
                                      new StepRow(step, Mark(step.Symbol), i == 0, i == run.Rows.Count - 1, open.Contains(step.Key),
                                                  open.Contains(ScriptKey(step.Key)))
                                      { AfterOpen = i > 0 && open.Contains(run.Rows[i - 1].Key) });
                    }
                    // Under the run's box: 20, the Mac's padding under StepsRow.
                    (above, aboveOpen) = (RowKind.Step, false);
                    break;
                case ThreadRowKind.Message or ThreadRowKind.Note when row.Words is { } words:
                    yield return (row.Key, RowKind.Reply, gap, words);
                    (above, aboveOpen) = (RowKind.Reply, false);
                    break;
                case ThreadRowKind.Permission when row.Permission is { } p:
                    // A permission's state is orange whatever it says: it stops the task (RuntimeActivity, statusColor .orange).
                    yield return (row.Key, RowKind.Fold, gap, new FoldRowModel(row.Key, FoldMark.Hand, p.Title, p.Status, true, isOpen,
                                                                               p.Input, p.Reason));
                    (above, aboveOpen) = (RowKind.Fold, isOpen);
                    break;
                case ThreadRowKind.Guidance when row.Guidance is { } steer:
                    yield return (row.Key, RowKind.Guidance, gap, new GuidanceRow(steer));
                    (above, aboveOpen) = (RowKind.Guidance, false);
                    break;
                case ThreadRowKind.Error:
                    yield return (row.Key, RowKind.Line, gap, new ThreadLine(row.Text ?? "", LineLook.Error));
                    (above, aboveOpen) = (RowKind.Line, false);
                    break;
                case ThreadRowKind.Truncated:
                    yield return (row.Key, RowKind.Line, gap, new ThreadLine(row.Text ?? "", LineLook.Cut));
                    (above, aboveOpen) = (RowKind.Line, false);
                    break;
            }
        }
    }

    /// <summary>The room over a row of a task's thread, by the row over it. The Mac has no space between rows and 20 pt
    /// under each one (RuntimeActivity.swift lines 142 to 148 and 345; Components.swift lines 118 to 131), and its
    /// activity rows stand 36.5 pt apart: so under a closed fold's face of 20 the next row has 16.5; under "Earlier
    /// activity", a 12 pt line of 16 here and of 15 on the Mac, it has 19 (35 apart); under an opened fold's content,
    /// 20. Under the agent's words, his guidance, a line or a run's box it has 21, as the Mac's footer of 20.</summary>
    public static double Under(RowKind? above, bool aboveOpen) => above switch
    {
        RowKind.Fold => aboveOpen ? 20 : MacLine + 20 - FoldFace,
        RowKind.EarlierActivity => 35 - EarlierLine,
        RowKind.Step => 20,
        _ => 21,
    };

    /// <summary>The height of a fold's face (FoldButton's line), of "Earlier activity" and of a line over the thread
    /// here; the Mac's fold line (FoldRow, Components.swift lines 631 to 665: 8 between its line and its content, 10
    /// around the content).</summary>
    public const double FoldFace = 20, EarlierLine = 16, OverLine = 16, MacLine = 16.5;

    /// <summary>The room under a line over the thread (a read that failed, offline): the Mac's 12 pt line of 15 and 20
    /// under it, 35 apart.</summary>
    public const double UnderOverLine = 35 - OverLine;

    /// <summary>The room over a step of an open run, inside the run's box: 10 over the first (and 4.5 over the box, so
    /// that the first step stands the Mac's line + 8 + 10 = 34.5 under its fold), 14.5 under a closed step's face of 22
    /// (36.5 apart, the Mac's), 20 under an opened step's content.</summary>
    public static double StepTop(StepRow row) => row.First ? 10 : row.AfterOpen ? 20 : 36.5 - StepFace;

    /// <summary>The room under the last step of an open run, inside the box: the Mac's 20 under the row and 10 of the
    /// box, under its line of 16.5 (24.5 under a closed face of 22, 30 under an opened step's content); then 20 under
    /// the box, so that the next row stands 66.5 under a closed last step.</summary>
    public static double StepBottom(StepRow row) => !row.Last ? 0 : row.Open ? 30 : MacLine + 30 - StepFace;

    /// <summary>A child agent's thread (RuntimeActivity.childThread, ChildActivity): its head, then its rows as a plain
    /// list (no runs, no box): steps, its own words, its errors; "Waiting for agent activity." while it has none.</summary>
    public static IEnumerable<(string Key, RowKind Kind, double Gap, object Model)> Child(ChildThreadModel child, IReadOnlySet<string> open)
    {
        yield return ("child-head", RowKind.ChildHead, 21, new ChildHeadRow(child.BackWords, child.Title, child.AttemptWords));
        if (child.WaitingWords is { } waiting) yield return ("child-waiting", RowKind.Line, 14, new ThreadLine(waiting, LineLook.Waiting));
        RowKind? before = null;
        bool beforeOpen = false;
        foreach (var step in child.Rows)
        {
            double gap = ChildGap(before, beforeOpen);
            before = step.Kind switch
            {
                ActivityRowKind.Message when step.Words is not null => RowKind.Reply,
                ActivityRowKind.Error or ActivityRowKind.Truncated => RowKind.Line,
                _ => RowKind.Step,
            };
            beforeOpen = open.Contains(step.Key);
            switch (step.Kind)
            {
                case ActivityRowKind.Message when step.Words is { } words:
                    yield return (step.Key, RowKind.Reply, gap, words);
                    break;
                case ActivityRowKind.Error:
                    yield return (step.Key, RowKind.Line, gap, new ThreadLine(step.Text ?? "", LineLook.Error));
                    break;
                case ActivityRowKind.Truncated:
                    yield return (step.Key, RowKind.Line, gap, new ThreadLine(step.Text ?? "", LineLook.Cut));
                    break;
                default:
                    yield return (step.Key, RowKind.Step, gap, new StepRow(step, Mark(step.Symbol), true, true, open.Contains(step.Key),
                                                                       open.Contains(ScriptKey(step.Key)), Boxed: false));
                    break;
            }
        }
    }

    /// <summary>The room over a row of a child's thread. The Mac's rows stand 36.5 pt apart (ChildActivity: no space
    /// between rows, and 20 pt under each row, whose fold line is about 16.5; RuntimeActivity.swift line 345,
    /// Components.swift lines 118 to 131): so under a closed step's face of 22 the next row has 14.5, and under an
    /// opened step's content 20. Under the agent's words or a line it has 21, as a message's footer of 20 gives on the
    /// Mac; the first row stands 14 under the head.</summary>
    public static double ChildGap(RowKind? before, bool beforeOpen = false) => before switch
    {
        null => 14,
        RowKind.Step => beforeOpen ? 20 : 36.5 - StepFace,
        _ => 21,
    };

    /// <summary>The height of a step's face in a thread (the fourth set's approved 2b).</summary>
    public const double StepFace = 22;

    /// <summary>A step's kind as its mark.</summary>
    public static FoldMark Mark(StepSymbol symbol) => symbol switch
    {
        StepSymbol.Read => FoldMark.Read,
        StepSymbol.Search => FoldMark.Search,
        StepSymbol.Edit => FoldMark.Edit,
        StepSymbol.Execute => FoldMark.Execute,
        StepSymbol.Fetch => FoldMark.Fetch,
        StepSymbol.Thought => FoldMark.Thought,
        StepSymbol.Subagent => FoldMark.Child,
        StepSymbol.Plan => FoldMark.Plan,
        StepSymbol.Steps => FoldMark.Steps,
        _ => FoldMark.Other,
    };
}
