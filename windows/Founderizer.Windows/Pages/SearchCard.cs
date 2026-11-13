using System;
using System.Collections.Generic;
using Founderizer.Core;
using Founderizer.Windows.Marks;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using Windows.System;
using Windows.UI;
using Page = Founderizer.Core.Page;

namespace Founderizer.Windows.Pages;

/// <summary>The search card (picture 1 of the second set, the Mac's SearchPalette in its fleetModal): the whole window
/// dimmed, black at 0.69, with Windows' caption buttons over it; a card of 460 by 370 on the canvas in the middle, with
/// its edge and shadow; the field with the magnifier; then the agents whose role or name holds the words, and the tasks
/// whose title holds them (Screens.Search). Up and Down move the row that Enter opens, Esc and a press beside the card
/// close it. No "In messages": a PC may not read the history.</summary>
internal sealed class SearchCard : Grid
{
    private readonly Func<StoreState> state;
    private readonly Action<Page> open;
    private readonly Action closed;
    private readonly TextBox field;
    private readonly StackPanel rows = new();
    private readonly Grid card;
    private SearchModel model = new();
    private int highlighted;
    private readonly List<Grid> rowFaces = new();

    public SearchCard(Func<StoreState> state, Action<Page> open, Action closed)
    {
        this.state = state;
        this.open = open;
        this.closed = closed;
        Visibility = Visibility.Collapsed;
        var smoke = new Rectangle { Fill = new SolidColorBrush(Color.FromArgb(176, 0, 0, 0)) };
        smoke.PointerPressed += (_, e) => { e.Handled = true; Close(); };
        Children.Add(smoke);

        field = new TextBox
        {
            FontFamily = Look.TextFont,
            FontSize = 14,
            Padding = new Thickness(0),
            MinHeight = 0,
            BorderThickness = new Thickness(0),
            Background = new SolidColorBrush(Color.FromArgb(0, 0, 0, 0)),
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(0, 4, 0, 0),
            PlaceholderText = model.Placeholder,
        };
        foreach (var part in new[] { "", "PointerOver", "Focused" })
        {
            field.Resources["TextControlBackground" + part] = new SolidColorBrush(Color.FromArgb(0, 0, 0, 0));
            field.Resources["TextControlBorderBrush" + part] = new SolidColorBrush(Color.FromArgb(0, 0, 0, 0));
            field.Resources["TextControlForeground" + part] = Look.Text;
            field.Resources["TextControlPlaceholderForeground" + part] = Look.Muted;
        }
        field.Resources["TextControlBorderThemeThickness"] = new Thickness(0);
        field.Resources["TextControlBorderThemeThicknessFocused"] = new Thickness(0);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(field, model.Placeholder);
        field.TextChanged += (_, _) =>
        {
            highlighted = 0;
            Draw();
        };
        field.KeyDown += Key;

        var magnifier = Icons.Of(Icons.Search, Look.Muted);
        magnifier.VerticalAlignment = VerticalAlignment.Center;
        var fieldRow = new Grid { Height = 44, Padding = new Thickness(22, 0, 22, 0), ColumnSpacing = 12 };
        fieldRow.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(22) });
        fieldRow.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        fieldRow.Children.Add(new Grid { Children = { magnifier } });
        SetColumn(field, 1);
        fieldRow.Children.Add(field);

        var list = new ScrollViewer
        {
            Content = rows,
            HorizontalScrollMode = ScrollMode.Disabled,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            IsTabStop = false,
        };
        var inner = new Grid { Padding = new Thickness(0, 8, 0, 0) };
        inner.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        inner.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        inner.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        inner.Children.Add(fieldRow);
        var rule = new Border { Height = 1, Background = Look.Line, Margin = new Thickness(0, 4, 0, 8) };
        SetRow(rule, 1);
        inner.Children.Add(rule);
        SetRow(list, 2);
        inner.Children.Add(list);

        card = new Grid
        {
            Width = 460,
            Height = 370,
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
            Background = Look.CanvasBrush,
            BorderBrush = Look.Brush(Look.White(0.1)),
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(8),
            Children = { inner },
        };
        Children.Add(Shadows.Under(card, Look.Canvas, 8, 24, 8, 0.45f));
        Children.Add(card);
    }

    public bool IsOpen => Visibility == Visibility.Visible;

    /// <summary>Opens with no words: the agents and the newest tasks; the keyboard in the field.</summary>
    public void Open()
    {
        Visibility = Visibility.Visible;
        field.Text = "";
        highlighted = 0;
        Draw();
        field.Focus(FocusState.Programmatic);
    }

    public void Close()
    {
        if (!IsOpen) return;
        Visibility = Visibility.Collapsed;
        closed();
    }

    /// <summary>A new state of the store while the card is open.</summary>
    public void Show()
    {
        if (IsOpen) Draw();
    }

    private void Draw()
    {
        model = Screens.Search(state(), field.Text, highlighted, DateTimeOffset.UtcNow);
        highlighted = model.Highlighted;
        rows.Children.Clear();
        rowFaces.Clear();
        int index = 0;
        if (model.Agents.Count > 0)
        {
            rows.Children.Add(Label(model.AgentsHeading, top: 4, bottom: 6));
            foreach (var agent in model.Agents) rows.Children.Add(AgentRow(agent, index++));
        }
        if (model.Tasks.Count > 0)
        {
            rows.Children.Add(Label(model.TasksHeading, top: model.Agents.Count > 0 ? 12 : 4, bottom: 4));
            foreach (var task in model.Tasks) rows.Children.Add(TaskRow(task, index++));
        }
        Highlight();
    }

    private void Highlight()
    {
        for (int i = 0; i < rowFaces.Count; i++)
            rowFaces[i].Background = i == highlighted ? Look.SelectBrush : new SolidColorBrush(Color.FromArgb(0, 0, 0, 0));
    }

    private static TextBlock Label(string words, double top, double bottom)
    {
        var label = Look.Words(words, 12, 16, Look.Muted, wrap: false);
        label.Padding = new Thickness(22, top, 22, bottom);
        return label;
    }

    private UIElement AgentRow(SearchAgentRow agent, int index)
    {
        var names = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        names.Children.Add(Look.Words(agent.Label, semibold: true, wrap: false));
        if (agent.Line is { } line) names.Children.Add(Look.Words(line, 12, 16, Look.Muted, wrap: false));
        var mark = new AgentGlyph { Side = 22, Mark = agent.Mark, VerticalAlignment = VerticalAlignment.Center };
        return Row(48, mark, names, index, agent.Label);
    }

    private UIElement TaskRow(SearchTaskRow task, int index)
    {
        var (icon, tone) = task.Mark.Symbol switch
        {
            TaskSymbol.Working => (Icons.Hint, Look.Brush(Look.Rgb(0x30, 0xD1, 0x58))),
            TaskSymbol.Paused => (Icons.PauseCircle, Look.Muted),
            TaskSymbol.Checked or TaskSymbol.Ended => (Icons.Check, Look.Muted),
            TaskSymbol.Failed => (Icons.Dismiss16, Look.Brush(Look.Rgb(0xFF, 0x45, 0x3A))),
            TaskSymbol.Alert or TaskSymbol.Limit or TaskSymbol.Question or TaskSymbol.SignIn => (Icons.Warning, Look.Orange),
            TaskSymbol.Reconnecting => (Icons.Refresh, Look.Muted),
            _ => (Icons.Hint, Look.Muted),
        };
        var mark = Icons.Of(icon, tone);
        mark.HorizontalAlignment = HorizontalAlignment.Center;
        mark.VerticalAlignment = VerticalAlignment.Center;
        ToolTipService.SetToolTip(mark, task.Mark.Words);
        var title = Look.Words(task.Title, wrap: false);
        title.VerticalAlignment = VerticalAlignment.Center;
        return Row(40, mark, title, index, task.Title);
    }

    private UIElement Row(double height, FrameworkElement mark, FrameworkElement words, int index, string name)
    {
        var face = new Grid { Height = height, Padding = new Thickness(14, 0, 14, 0), CornerRadius = new CornerRadius(4), ColumnSpacing = 12 };
        face.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(22) });
        face.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        face.Children.Add(new Grid { Children = { mark } });
        SetColumn(words, 1);
        face.Children.Add(words);
        rowFaces.Add(face);
        var button = new Button
        {
            Style = (Style)Application.Current.Resources["QuietButtonStyle"],
            HorizontalAlignment = HorizontalAlignment.Stretch,
            Margin = new Thickness(8, 0, 8, 0),
            Content = face,
            IsTabStop = false,
        };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(button, name);
        button.Click += (_, _) => Choose(index);
        return button;
    }

    private void Choose(int index)
    {
        if (model.Open(index) is not { } page) return;
        Close();
        open(page);
    }

    private void Key(object sender, KeyRoutedEventArgs e)
    {
        switch (e.Key)
        {
            case VirtualKey.Down:
                highlighted = SearchModel.Move(highlighted, 1, model.Count);
                Highlight();
                e.Handled = true;
                break;
            case VirtualKey.Up:
                highlighted = SearchModel.Move(highlighted, -1, model.Count);
                Highlight();
                e.Handled = true;
                break;
            case VirtualKey.Enter:
                Choose(highlighted);
                e.Handled = true;
                break;
            case VirtualKey.Escape:
                Close();
                e.Handled = true;
                break;
        }
    }
}
