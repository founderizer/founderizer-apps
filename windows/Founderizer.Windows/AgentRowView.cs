using System.ComponentModel;
using System.Runtime.CompilerServices;
using Founderizer.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;
using Windows.UI;

namespace Founderizer.Windows;

/// <summary>One agent's row of the pane as the screen binds it, from the library's <see cref="AgentRow"/>. A new row
/// changes only the fields that changed, so only those parts of the row draw again.</summary>
public sealed class AgentRowView : INotifyPropertyChanged
{
    public AgentRowView(string name) => Name = name;

    public string Name { get; }

    private string label = "";
    public string Label { get => label; private set => Set(ref label, value); }

    private string line = "";
    public string Line { get => line; private set => Set(ref line, value); }

    private string time = "";
    public string Time { get => time; private set => Set(ref time, value); }

    private MarkLook? mark;
    public MarkLook? Mark { get => mark; private set => Set(ref mark, value); }

    private bool lineMoves;
    public bool LineMoves { get => lineMoves; private set => Set(ref lineMoves, value); }

    private bool selected;
    public bool Selected
    {
        get => selected;
        private set { if (Set(ref selected, value)) Changed(nameof(SelectedVisibility)); }
    }

    public Visibility SelectedVisibility => selected ? Visibility.Visible : Visibility.Collapsed;

    private string lineCount = "";
    /// <summary>The part of the line that stays whole when the pane is narrow (" · +N", picture 11).</summary>
    public string LineCount { get => lineCount; private set => Set(ref lineCount, value); }

    private Visibility dotVisibility = Visibility.Collapsed;
    /// <summary>The status dot on the mark's lower right corner (picture 15): only for a state that is a problem.</summary>
    public Visibility DotVisibility { get => dotVisibility; private set => Set(ref dotVisibility, value); }

    private Brush dotFill = Transparent;
    /// <summary>The dot's fill: its tone, or the rail's colour for a ring (an agent that takes no work).</summary>
    public Brush DotFill { get => dotFill; private set => Set(ref dotFill, value); }

    private Brush dotEdge = Transparent;
    /// <summary>The ring's colour, or none for a filled dot.</summary>
    public Brush DotEdge { get => dotEdge; private set => Set(ref dotEdge, value); }

    private string dotHover = "";
    /// <summary>The dot's words under the pointer ("Usage limit", "Not answering").</summary>
    public string DotHover { get => dotHover; private set => Set(ref dotHover, value); }

    private static readonly Brush Transparent = new SolidColorBrush(Color.FromArgb(0, 0, 0, 0));
    private static readonly Brush Rail = new SolidColorBrush(Color.FromArgb(255, 0x20, 0x20, 0x20));

    /// <summary>The colour of a state's tone.</summary>
    public static Brush ToneBrush(StateTone tone) => new SolidColorBrush(tone switch
    {
        StateTone.Online => Color.FromArgb(255, 0x30, 0xD1, 0x58),
        StateTone.Warning => Color.FromArgb(255, 0xFF, 0x9F, 0x0A),
        _ => Color.FromArgb(255, 0x99, 0x99, 0x99),
    });

    /// <summary>The row as the library's pane model gives it. Its unread dot is an element that no approved picture shows,
    /// so this row does not draw it.</summary>
    public void Show(AgentRow row)
    {
        Label = row.Label;
        // The line in two parts where the model cuts it: the words, cut with "…", and their count, whole.
        Line = row.LineText ?? row.Line ?? "";
        LineCount = row.LineText is null ? "" : row.LineCount ?? "";
        DotVisibility = row.ShowsDot ? Visibility.Visible : Visibility.Collapsed;
        DotFill = row.Status.IsRing ? Rail : ToneBrush(row.Status.DotTone);
        DotEdge = row.Status.IsRing ? ToneBrush(row.Status.DotTone) : Transparent;
        DotHover = row.Status.Words;
        Time = row.Time ?? "";
        Mark = row.Mark;
        LineMoves = row.LineMoves;
        Selected = row.Selected;
    }

    public event PropertyChangedEventHandler? PropertyChanged;

    private bool Set<T>(ref T field, T value, [CallerMemberName] string? name = null)
    {
        if (Equals(field, value)) return false;
        field = value;
        Changed(name!);
        return true;
    }

    private void Changed(string name) => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
}

/// <summary>An agent's line and its count (picture 11): the words take the room that the count leaves and are cut with
/// "…", and the count follows them, whole.</summary>
public sealed partial class CountLinePanel : Microsoft.UI.Xaml.Controls.Panel
{
    protected override global::Windows.Foundation.Size MeasureOverride(global::Windows.Foundation.Size available)
    {
        if (Children.Count < 2) return new global::Windows.Foundation.Size(0, 0);
        var count = Children[1];
        count.Measure(new global::Windows.Foundation.Size(double.PositiveInfinity, available.Height));
        var text = Children[0];
        text.Measure(new global::Windows.Foundation.Size(System.Math.Max(0, available.Width - count.DesiredSize.Width), available.Height));
        double width = text.DesiredSize.Width + count.DesiredSize.Width;
        return new global::Windows.Foundation.Size(double.IsInfinity(available.Width) ? width : System.Math.Min(width, available.Width),
            System.Math.Max(text.DesiredSize.Height, count.DesiredSize.Height));
    }

    protected override global::Windows.Foundation.Size ArrangeOverride(global::Windows.Foundation.Size final)
    {
        if (Children.Count < 2) return final;
        var text = Children[0];
        var count = Children[1];
        double width = System.Math.Min(text.DesiredSize.Width, System.Math.Max(0, final.Width - count.DesiredSize.Width));
        text.Arrange(new global::Windows.Foundation.Rect(0, 0, width, final.Height));
        count.Arrange(new global::Windows.Foundation.Rect(width, 0, count.DesiredSize.Width, final.Height));
        return final;
    }
}
