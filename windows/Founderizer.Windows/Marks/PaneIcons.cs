using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Markup;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;

namespace Founderizer.Windows.Marks;

/// <summary>The icons of the pane that Segoe Fluent Icons does not have, as the approved pictures draw them: Needs you
/// (chat_warning) and Tasks (board), 20-point paths at 16. Back, Forward, Search and Settings come from Segoe Fluent
/// Icons, which Windows has.
///
/// The paths are from Fluent System Icons, @fluentui/svg-icons 1.1.340. Copyright (c) 2020 Microsoft Corporation.
/// MIT License: permission is hereby granted, free of charge, to any person obtaining a copy of this software, to deal
/// in the software without restriction, provided that this copyright notice and this permission notice are included
/// in all copies or substantial portions of the software. THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND.
/// </summary>
public static class PaneIcons
{
    public const string NeedsYou = "M10 2a8 8 0 1 1-3.61 15.14l-.12-.07-3.65.92a.5.5 0 0 1-.62-.45v-.08l.01-.08.92-3.64-.07-.12a8 8 0 0 1-.83-2.9l-.02-.37L2 10a8 8 0 0 1 8-8m0 1a7 7 0 0 0-6.1 10.42.5.5 0 0 1 .06.28l-.02.1-.75 3.01 3.02-.75.19-.01.09.02.09.04A7 7 0 1 0 10 3m0 2.5c.28 0 .5.22.5.5v5.5a.5.5 0 0 1-1 0V6c0-.28.22-.5.5-.5m0 9a.75.75 0 1 0 0-1.5 .75.75 0 0 0 0 1.5";
    // The same path as Fluent's board_20_regular, with each move after a "z" written as an absolute "M": in SVG a
    // relative "m" after "z" starts from the figure's first point, in XAML from the last point drawn.
    public const string Tasks = "M3 6a3 3 0 0 1 3-3h8a3 3 0 0 1 3 3v8a3 3 0 0 1-3 3H6a3 3 0 0 1-3-3z"
        + "M6 4a2 2 0 0 0-2 2v1.06L9.5 7V4z"
        + "M10.5 4v8H16V6a2 2 0 0 0-2-2z"
        + "M16 13h-5.5v3H14a2 2 0 0 0 2-2z"
        + "M9.5 16V8L4 8.06V14c0 1.1.9 2 2 2z";

    /// <summary>One of the paths above in a 16-pixel square, in the text colour.</summary>
    public static FrameworkElement Icon(string data)
    {
        var path = new Path
        {
            // The nonzero fill of SVG ("F1"): XAML's default even-odd fill cuts holes in these icons.
            Data = (Geometry)XamlBindingHelper.ConvertValue(typeof(Geometry), "F1 " + data),
            Fill = (Brush)Application.Current.Resources["TextBrush"],
            Width = 20,
            Height = 20,
        };
        return new Viewbox { Width = 16, Height = 16, Child = new Canvas { Width = 20, Height = 20, Children = { path } } };
    }
}
