using System;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using Microsoft.UI.Xaml.Media;

namespace Founderizer.Windows;

/// <summary>The app's part of the readings of rule 6 (app/windows/vm/README.md, "Readings"): with
/// FOUNDERIZER_TIMING_LOG set to a file, the app writes there when its first page is drawn (milliseconds from the
/// process's start) and, for each change of the pane's state, the milliseconds from the change's arrival to the frame
/// that shows it. Without that variable it writes nothing and does nothing.</summary>
public static class Readings
{
    private static readonly string? Log = Proofs.Variable("FOUNDERIZER_TIMING_LOG");

    /// <summary>The first frame after the window's first page is in place.</summary>
    public static void FirstFrame()
    {
        if (Log is null) return;
        void Rendered(object? sender, object e)
        {
            CompositionTarget.Rendering -= Rendered;
            var started = Process.GetCurrentProcess().StartTime.ToUniversalTime();
            Write($"first-page {(DateTime.UtcNow - started).TotalMilliseconds:F0}");
        }
        CompositionTarget.Rendering += Rendered;
    }

    /// <summary>With FOUNDERIZER_READING=block-ui, the UI thread sleeps 4 seconds, 5 seconds after the start: the
    /// proof that the compositor, not the UI thread, moves the glyphs and the lines (frames.ps1 takes the frames).</summary>
    public static void BlockTheUiThread(Microsoft.UI.Dispatching.DispatcherQueue queue)
    {
        if (Proofs.Variable("FOUNDERIZER_READING") != "block-ui") return;
        var timer = blockTimer = queue.CreateTimer();
        timer.Interval = TimeSpan.FromSeconds(5);
        timer.IsRepeating = false;
        timer.Tick += (_, _) =>
        {
            Write("ui-thread-blocked 4000");
            System.Threading.Thread.Sleep(4000);
        };
        timer.Start();
    }

    /// <summary>The frame after a change that arrived at <paramref name="arrived"/> (Stopwatch ticks), with what the
    /// pane shows differently.</summary>
    public static void ChangeShown(long arrived, Func<string> shown)
    {
        if (Log is null) return;
        void Rendered(object? sender, object e)
        {
            CompositionTarget.Rendering -= Rendered;
            Write($"change-to-frame {Stopwatch.GetElapsedTime(arrived).TotalMilliseconds:F1} {shown()}");
        }
        CompositionTarget.Rendering += Rendered;
    }

    private static bool scrolled;
    // The readings' timers, held here: a timer that nothing holds can be collected before it fires.
    private static Microsoft.UI.Dispatching.DispatcherQueueTimer? scrollTimer, blockTimer;

    /// <summary>With FOUNDERIZER_READING=long-chat (the sample's chat of 2,000 messages), 5 seconds after the chat opens:
    /// the window's own frame interval at rest (120 frames), then the chat goes from its end to its start, 64 pixels a
    /// frame, and the log gets each frame's interval (from CompositionTarget's rendering time), a summary, and each frame
    /// longer than twice the interval at rest, with the rows that came into view in it, the views made and the garbage
    /// collections.</summary>
    public static void ScrollWhenAsked(Microsoft.UI.Xaml.Controls.ScrollViewer scroll)
    {
        if (Log is null || scrolled || Proofs.Variable("FOUNDERIZER_READING") != "long-chat") return;
        scrolled = true;
        var timer = scrollTimer = Microsoft.UI.Dispatching.DispatcherQueue.GetForCurrentThread().CreateTimer();
        timer.Interval = TimeSpan.FromSeconds(5);
        timer.IsRepeating = false;
        timer.Tick += (_, _) =>
        {
            // First 120 frames at rest, for the window's own frame interval; then the scroll, frame by frame, with the
            // rows that came into view, the views made for them and the garbage collections of each frame.
            var rest = new System.Collections.Generic.List<double>();
            var intervals = new System.Collections.Generic.List<double>();
            var longFrames = new System.Collections.Generic.List<string>();
            TimeSpan? last = null;
            Stopwatch? clock = null;
            int realized = 0, made = 0, collections = 0;
            static double Median(System.Collections.Generic.List<double> values)
            {
                var sorted = values.ToArray();
                Array.Sort(sorted);
                return sorted.Length == 0 ? 0 : sorted[sorted.Length / 2];
            }
            void Rendered(object? sender, object e)
            {
                var at = ((RenderingEventArgs)e).RenderingTime;
                double? interval = last is { } before && at > before ? (at - before).TotalMilliseconds : null;
                last = at;
                if (clock is null)
                {
                    if (interval is { } r) rest.Add(r);
                    if (rest.Count < 120) return;
                    clock = Stopwatch.StartNew();
                    Write(string.Create(CultureInfo.InvariantCulture,
                        $"scroll-start offset {scroll.VerticalOffset:F0} extent {scroll.ExtentHeight:F0} viewport {scroll.ViewportHeight:F0}, frame interval at rest (median of 120) {Median(rest):F1} ms"));
                }
                else if (interval is { } i)
                {
                    intervals.Add(i);
                    int gc = GC.CollectionCount(0) + GC.CollectionCount(1) + GC.CollectionCount(2);
                    if (i > 2 * Median(rest))
                        longFrames.Add(string.Create(CultureInfo.InvariantCulture,
                            $"{i:F1} ms ({Pages.RowFactory.Realized - realized} rows came, {Pages.RowFactory.Made - made} views made, {gc - collections} collections)"));
                    realized = Pages.RowFactory.Realized;
                    made = Pages.RowFactory.Made;
                    collections = gc;
                }
                if (scroll.VerticalOffset > 0.5)
                {
                    scroll.ChangeView(null, Math.Max(0, scroll.VerticalOffset - 64), null, true);
                    return;
                }
                CompositionTarget.Rendering -= Rendered;
                var sorted = intervals.ToArray();
                Array.Sort(sorted);
                double display = Median(rest);
                double median = sorted.Length == 0 ? 0 : sorted[sorted.Length / 2];
                double p99 = sorted.Length == 0 ? 0 : sorted[(int)(sorted.Length * 0.99)];
                double max = sorted.Length == 0 ? 0 : sorted[^1];
                Write(string.Create(CultureInfo.InvariantCulture,
                    $"scroll-end {clock.Elapsed.TotalSeconds:F1} s, {sorted.Length} frames, median {median:F1} ms, p99 {p99:F1} ms, max {max:F1} ms, {longFrames.Count} longer than twice the interval at rest ({2 * display:F1} ms), {Pages.RowFactory.Realized} rows came into view, {Pages.RowFactory.Made} views made, extent {scroll.ExtentHeight:F0}"));
                foreach (var frame in longFrames) Write("scroll-long " + frame);
                Write("scroll-intervals " + string.Join(' ', intervals.ConvertAll(v => v.ToString("F1", CultureInfo.InvariantCulture))));
            }
            CompositionTarget.Rendering += Rendered;
        };
        timer.Start();
    }

    /// <summary>A line of the proofs (a write's answer whose line waits for its picture: a refused code, a refused
    /// address), in the timing log of the proofs' build; nothing in a release build.</summary>
    public static void Note(string line) => Write(line);

    private static void Write(string line)
    {
        if (Log is null) return;
        try
        {
            File.AppendAllText(Log!, line + Environment.NewLine);
        }
        catch (IOException)
        {
        }
    }
}
