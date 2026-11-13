using System.ComponentModel;
using System.Runtime.CompilerServices;
using Founderizer.Core;
using Microsoft.UI.Xaml;

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

    /// <summary>The row as the library's pane model gives it. Its status dot and its unread dot are elements that no
    /// approved picture shows yet, so this row does not draw them.</summary>
    public void Show(AgentRow row)
    {
        Label = row.Label;
        Line = row.Line ?? "";
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
