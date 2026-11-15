namespace Founderizer.Core;

/// <summary>Whether a chat or a task's thread stands at its end (FleetCore's ChatEnd), which decides two things: whether
/// it follows its newest row, and whether "Latest" shows over it.
///
/// It keeps two facts. <c>follows</c> is what the scroll's own phases say: he took the view in hand, and where it came to
/// rest. <c>atEnd</c> is where the view stands now, from the scroll's own measure. The phases alone left "Latest" over a
/// chat that stood at its end (the owner, 14 November 2026: "it shows the Latest badge when there are actually no more
/// messages"). So a view at its end follows and shows no "Latest", whatever the phases said last, and a view that leaves
/// its end stops following, whatever moved it. Each view keeps one, from its first drawing.</summary>
public sealed class ChatEnd
{
    /// <summary>The most that stands under the view while it still counts as at its end, in points (device-independent
    /// pixels on Windows).</summary>
    public const double Near = 100.0;

    private bool follows = true;
    private bool atEnd = true;

    /// <summary>The view goes to its newest row when one comes. Set true by "Latest", which brings the view to its end,
    /// and false by a jump that takes it from there: a view that stands at its end follows all the same.</summary>
    public bool FollowsLatest
    {
        get => follows || atEnd;
        set => follows = value;
    }

    /// <summary>"Latest" shows: the view stands away from its end, and nothing brings it there.</summary>
    public bool ShowsLatest => !FollowsLatest;

    /// <summary>He took the view in hand (a drag, a wheel, a touch that starts to move it).</summary>
    public void Taken() => follows = false;

    /// <summary>The scroll came to rest with <paramref name="under"/> points of the view's content under it. After a
    /// scroll that the view made itself (<paramref name="jumped"/>: its own move to the newest row, or a jump) the rest can
    /// only start the following, never stop it: rows that came during that scroll stand under the view.</summary>
    public void Rested(double under, bool jumped)
    {
        var end = IsEnd(under);
        if (end || !jumped) follows = end;
    }

    /// <summary>The view stands with <paramref name="under"/> points of its content under it. A view that comes to its
    /// end follows again. A view that left its end stops following when the view itself <paramref name="moved"/> (the
    /// content as long and the room as high as they were); content that grew under the view, or a room that became
    /// smaller, keeps the following.</summary>
    public void Stands(double under, bool moved)
    {
        var end = IsEnd(under);
        if (end) follows = true;
        else if (atEnd && moved) follows = false;
        atEnd = end;
    }

    /// <summary>A view with <paramref name="under"/> points of content under it stands at its end.</summary>
    public static bool IsEnd(double under) => under < Near;
}
