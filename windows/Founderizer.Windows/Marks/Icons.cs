using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Markup;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;

namespace Founderizer.Windows.Marks;

/// <summary>An icon of the approved pictures: path data in a square of <see cref="Side"/> (20, or 12 for a chevron).</summary>
public sealed record Icon(double Side, string Data);

/// <summary>The icons of the approved pictures that Segoe Fluent Icons does not have, as the pictures draw them (their
/// source names each one). Back, Forward, Search and Settings come from Segoe Fluent Icons, which Windows has.
///
/// The paths are from Fluent System Icons, @fluentui/svg-icons 1.1.340, with each move after a "z" written as an
/// absolute "M": SVG starts a relative "m" after "z" from the figure's first point, XAML from the last point drawn.
/// Copyright (c) 2020 Microsoft Corporation. MIT License: permission is hereby granted, free of charge, to any person
/// obtaining a copy of this software, to deal in the software without restriction, provided that this copyright notice
/// and this permission notice are included in all copies or substantial portions of the software. THE SOFTWARE IS
/// PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND.
/// </summary>
public static class Icons
{
    /// <summary>chat_warning_20_regular, a square of 20.</summary>
    public static readonly Icon NeedsYou = new(20, "M10 2a8 8 0 1 1 -3.61 15.14l-0.12 -0.07l-3.65 0.92a0.5 0.5 0 0 1 -0.62 -0.45v-0.08l0.01 -0.08l0.92 -3.64l-0.07 -0.12a8 8 0 0 1 -0.83 -2.9l-0.02 -0.37L2 10a8 8 0 0 1 8 -8m0 1a7 7 0 0 0 -6.1 10.42a0.5 0.5 0 0 1 0.06 0.28l-0.02 0.1l-0.75 3.01l3.02 -0.75l0.19 -0.01l0.09 0.02l0.09 0.04A7 7 0 1 0 10 3m0 2.5c0.28 0 0.5 0.22 0.5 0.5v5.5a0.5 0.5 0 0 1 -1 0V6c0 -0.28 0.22 -0.5 0.5 -0.5m0 9a0.75 0.75 0 1 0 0 -1.5a0.75 0.75 0 0 0 0 1.5");
    /// <summary>board_20_regular, a square of 20.</summary>
    public static readonly Icon Tasks = new(20, "M3 6a3 3 0 0 1 3 -3h8a3 3 0 0 1 3 3v8a3 3 0 0 1 -3 3H6a3 3 0 0 1 -3 -3zM6 4a2 2 0 0 0 -2 2v1.06L9.5 7V4zM10.5 4v8H16V6a2 2 0 0 0 -2 -2zM16 13h-5.5v3H14a2 2 0 0 0 2 -2zM9.5 16V8L4 8.06V14c0 1.1 0.9 2 2 2z");
    /// <summary>add_20_regular, a square of 20.</summary>
    public static readonly Icon Add = new(20, "M10 2.5c0.28 0 0.5 0.22 0.5 0.5v6.5H17a0.5 0.5 0 0 1 0 1h-6.5V17a0.5 0.5 0 0 1 -1 0v-6.5H3a0.5 0.5 0 0 1 0 -1h6.5V3c0 -0.28 0.22 -0.5 0.5 -0.5");
    /// <summary>calendar_20_regular, a square of 20.</summary>
    public static readonly Icon Calendar = new(20, "M7 11a1 1 0 1 0 0 -2a1 1 0 0 0 0 2m1 2a1 1 0 1 1 -2 0a1 1 0 0 1 2 0m2 -2a1 1 0 1 0 0 -2a1 1 0 0 0 0 2m1 2a1 1 0 1 1 -2 0a1 1 0 0 1 2 0m2 -2a1 1 0 1 0 0 -2a1 1 0 0 0 0 2m4 -5.5A2.5 2.5 0 0 0 14.5 3h-9A2.5 2.5 0 0 0 3 5.5v9A2.5 2.5 0 0 0 5.5 17h9a2.5 2.5 0 0 0 2.5 -2.5zM4 7h12v7.5c0 0.83 -0.67 1.5 -1.5 1.5h-9A1.5 1.5 0 0 1 4 14.5zM5.5 4h9c0.83 0 1.5 0.67 1.5 1.5V6H4v-0.5C4 4.67 4.67 4 5.5 4");
    /// <summary>chat_multiple_20_regular, a square of 20.</summary>
    public static readonly Icon Discuss = new(20, "M8.54 2a6.5 6.5 0 0 0 -5.68 9.67l-0.8 2.08a1 1 0 0 0 1.21 1.32l2.49 -0.7q1.27 0.62 2.78 0.63a6.5 6.5 0 1 0 0 -13m-5.5 6.5a5.5 5.5 0 1 1 3 4.9l-0.18 -0.09l-2.86 0.8l0.97 -2.53l-0.13 -0.21a5.5 5.5 0 0 1 -0.8 -2.87M11.5 18a6.5 6.5 0 0 1 -4.93 -2.26a8 8 0 0 0 1.76 0.26a5.5 5.5 0 0 0 5.67 0.4l0.18 -0.09l2.86 0.8l-0.97 -2.53l0.13 -0.21a5.5 5.5 0 0 0 -0.16 -5.98q-0.02 -0.91 -0.24 -1.76a6.5 6.5 0 0 1 1.38 8.04l0.8 2.08a1 1 0 0 1 -1.21 1.32l-2.49 -0.7q-1.28 0.61 -2.78 0.63");
    /// <summary>chevron_down_12_regular, a square of 12.</summary>
    public static readonly Icon ChevronDown = new(12, "M2.15 4.65c0.2 -0.2 0.5 -0.2 0.7 0L6 7.79l3.15 -3.14a0.5 0.5 0 1 1 0.7 0.7l-3.5 3.5a0.5 0.5 0 0 1 -0.7 0l-3.5 -3.5a0.5 0.5 0 0 1 0 -0.7");
    /// <summary>chevron_right_12_regular, a square of 12.</summary>
    public static readonly Icon ChevronRight = new(12, "M4.65 2.15a0.5 0.5 0 0 0 0 0.7L7.79 6L4.65 9.15a0.5 0.5 0 1 0 0.7 0.7l3.5 -3.5a0.5 0.5 0 0 0 0 -0.7l-3.5 -3.5a0.5 0.5 0 0 0 -0.7 0");
    /// <summary>desktop_20_regular, a square of 20.</summary>
    public static readonly Icon Desktop = new(20, "M4 2a2 2 0 0 0 -2 2v9c0 1.1 0.9 2 2 2h3v2H5.5a0.5 0.5 0 0 0 0 1h9a0.5 0.5 0 0 0 0 -1H13v-2h3a2 2 0 0 0 2 -2V4a2 2 0 0 0 -2 -2zM12 15v2H8v-2zM3 4a1 1 0 0 1 1 -1h12a1 1 0 0 1 1 1v9a1 1 0 0 1 -1 1H4a1 1 0 0 1 -1 -1z");
    /// <summary>hourglass_half_20_regular, a square of 20.</summary>
    public static readonly Icon Hourglass = new(20, "M13.69 14.6q0.3 0.67 0.31 1.4H6a3.4 3.4 0 0 1 1.22 -2.56l1.82 -1.52a2.5 2.5 0 0 0 0.9 -1.92h0.12q0.02 0.56 0.29 1.06q0.23 0.5 0.65 0.85l1.78 1.53q0.59 0.47 0.91 1.16m-8.5 3.24q0.35 0.16 0.73 0.16h8.16a1.9 1.9 0 0 0 1.76 -1.2q0.15 -0.34 0.16 -0.72a5 5 0 0 0 -0.5 -2.31a5 5 0 0 0 -1.44 -1.87l-1.82 -1.52a0.5 0.5 0 0 1 0 -0.77l1.82 -1.52A5.3 5.3 0 0 0 16 3.92a1.9 1.9 0 0 0 -1.2 -1.76Q14.46 2 14.08 2H5.92a1.9 1.9 0 0 0 -1.76 1.2Q4 3.54 4 3.92q0 1.24 0.5 2.3q0.49 1.08 1.44 1.87l1.82 1.53q0.09 0.06 0.13 0.17a0.5 0.5 0 0 1 -0.13 0.6l-1.82 1.5a6 6 0 0 0 -1.44 1.88a5 5 0 0 0 -0.5 2.3a1.9 1.9 0 0 0 1.2 1.77m9.22 -0.91a1 1 0 0 1 -0.37 0.07H5.96q-0.2 0 -0.37 -0.08t-0.3 -0.2a1 1 0 0 1 -0.22 -0.3a1 1 0 0 1 -0.07 -0.38a4.5 4.5 0 0 1 1.58 -3.37l1.82 -1.52A1.5 1.5 0 0 0 8.94 10a1.5 1.5 0 0 0 -0.54 -1.16L6.58 7.33A4 4 0 0 1 5.4 5.82A4 4 0 0 1 5 3.96q0 -0.2 0.08 -0.37q0.06 -0.17 0.2 -0.3q0.14 -0.15 0.3 -0.22A1 1 0 0 1 5.97 3h8.08q0.2 0.02 0.37 0.08t0.3 0.2a1 1 0 0 1 0.29 0.68a4.4 4.4 0 0 1 -1.58 3.37L11.6 8.84q-0.25 0.21 -0.4 0.52a1.5 1.5 0 0 0 0.4 1.79l1.82 1.52A4.4 4.4 0 0 1 15 16.04q-0.02 0.2 -0.08 0.37t-0.2 0.3q-0.15 0.15 -0.31 0.22");
    /// <summary>pause_20_regular, a square of 20.</summary>
    public static readonly Icon Pause = new(20, "M5 2a2 2 0 0 0 -2 2v12c0 1.1 0.9 2 2 2h2a2 2 0 0 0 2 -2V4a2 2 0 0 0 -2 -2zM4 4a1 1 0 0 1 1 -1h2a1 1 0 0 1 1 1v12a1 1 0 0 1 -1 1H5a1 1 0 0 1 -1 -1zM13 2a2 2 0 0 0 -2 2v12c0 1.1 0.9 2 2 2h2a2 2 0 0 0 2 -2V4a2 2 0 0 0 -2 -2zM12 4a1 1 0 0 1 1 -1h2a1 1 0 0 1 1 1v12a1 1 0 0 1 -1 1h-2a1 1 0 0 1 -1 -1z");
    /// <summary>people_20_regular, a square of 20.</summary>
    public static readonly Icon People = new(20, "M4.5 6.75a2.25 2.25 0 1 1 4.5 0a2.25 2.25 0 0 1 -4.5 0M6.75 3.5a3.25 3.25 0 1 0 0 6.5a3.25 3.25 0 0 0 0 -6.5m5.69 11.65q0.79 0.33 2.06 0.35c1.88 0 2.92 -0.67 3.47 -1.43a3 3 0 0 0 0.53 -1.5v-0.07c0 -0.83 -0.67 -1.5 -1.5 -1.5h-4.63q0.36 0.44 0.53 1H17c0.28 0 0.5 0.22 0.5 0.5v0.1l-0.04 0.22q-0.05 0.29 -0.3 0.66c-0.33 0.46 -1.04 1.02 -2.66 1.02q-1.08 -0.01 -1.69 -0.28q-0.12 0.43 -0.37 0.93M1.5 13c0 -1.1 0.9 -2 2 -2H10a2 2 0 0 1 2 2v0.08l-0.01 0.18q-0.01 0.17 -0.08 0.45c-0.08 0.37 -0.25 0.86 -0.6 1.36c-0.7 1.01 -2.05 1.93 -4.56 1.93s-3.87 -0.92 -4.57 -1.93a4 4 0 0 1 -0.68 -1.99V13m1 0.06v0.1l0.06 0.33c0.07 0.27 0.2 0.64 0.45 1C3.49 15.2 4.5 16 6.75 16s3.26 -0.8 3.74 -1.5a3 3 0 0 0 0.5 -1.42l0.01 -0.02V13a1 1 0 0 0 -1 -1H3.5a1 1 0 0 0 -1 1zM13 7.5a1.5 1.5 0 1 1 3 0a1.5 1.5 0 0 1 -3 0M14.5 5a2.5 2.5 0 1 0 0 5a2.5 2.5 0 0 0 0 -5");
    /// <summary>stop_20_regular, a square of 20.</summary>
    public static readonly Icon Stop = new(20, "M15.5 4c0.28 0 0.5 0.22 0.5 0.5v11a0.5 0.5 0 0 1 -0.5 0.5h-11a0.5 0.5 0 0 1 -0.5 -0.5v-11c0 -0.28 0.22 -0.5 0.5 -0.5zM4.5 3C3.67 3 3 3.67 3 4.5v11c0 0.83 0.67 1.5 1.5 1.5h11c0.83 0 1.5 -0.67 1.5 -1.5v-11c0 -0.83 -0.67 -1.5 -1.5 -1.5z");

    /// <summary>An icon at <paramref name="size"/> pixels (16 for a 20-square icon, 12 for a chevron) in a brush.</summary>
    public static FrameworkElement Of(Icon icon, Brush brush, double size = 16)
    {
        var path = new Path
        {
            // The nonzero fill of SVG ("F1"): XAML's default even-odd fill cuts holes in these icons.
            Data = (Geometry)XamlBindingHelper.ConvertValue(typeof(Geometry), "F1 " + icon.Data),
            Fill = brush,
            Width = icon.Side,
            Height = icon.Side,
        };
        return new Viewbox
        {
            Width = size,
            Height = size,
            IsHitTestVisible = false,
            Child = new Canvas { Width = icon.Side, Height = icon.Side, Children = { path } },
        };
    }

    /// <summary>An icon in the text colour.</summary>
    public static FrameworkElement Of(Icon icon, double size = 16) =>
        Of(icon, (Brush)Application.Current.Resources["TextBrush"], size);
}
