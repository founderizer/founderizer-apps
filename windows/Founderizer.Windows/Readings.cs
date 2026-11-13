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
    private static readonly string? Log = Environment.GetEnvironmentVariable("FOUNDERIZER_TIMING_LOG");

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
        if (Environment.GetEnvironmentVariable("FOUNDERIZER_READING") != "block-ui") return;
        var timer = queue.CreateTimer();
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
